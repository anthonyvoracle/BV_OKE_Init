#!/bin/bash -ex
# Minimal, robust script to create, attach, and mount an OCI Block Volume for OKE nodes upon launch.
set -euo pipefail

# --- Config (override via user-data vars) ---
VOL_SIZE_GB="${VOL_SIZE_GB:-100}"          # e.g., 100
VPUS_PER_GB="${VPUS_PER_GB:-10}"           # 0,10,20,30
MOUNT_POINT="${MOUNT_POINT:-/data}"        # e.g., /data
FS_TYPE="${FS_TYPE:-xfs}"                  # xfs or ext4
VOLUME_COMPARTMENT_OCID="${VOLUME_COMPARTMENT_OCID:-}"  # defaults to instance compartment
ATTACH_TYPE="${ATTACH_TYPE:-paravirtualized}"           # paravirtualized or iscsi

# --- Logging ---
LOG_FILE="/var/log/volume-init.log"
log() { echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] $*" | tee -a "$LOG_FILE"; }
trap 'rc=$?; log "ERROR at line $LINENO (exit $rc)"; exit $rc' ERR

# Fast exit if already mounted
if mountpoint -q "$MOUNT_POINT"; then log "Mounted: $MOUNT_POINT"; exit 0; fi

# --- Install tools (OCI CLI, FS utils) ---
install_pkg() { if command -v dnf >/dev/null 2>&1; then dnf -y install "$@" >/dev/null; else yum -y install "$@" >/dev/null; fi; }
if ! command -v oci >/dev/null 2>&1; then
  log "Installing OCI CLI..."
  if command -v dnf >/dev/null 2>&1; then
    dnf install -y "oraclelinux-developer-release-el$(rpm -E %rhel)" >/dev/null || true
    dnf install -y python3-oci-cli >/dev/null || dnf install -y oci-cli >/dev/null
  else
    yum install -y oraclelinux-developer-release-el7 >/dev/null || true
    yum install -y python36-oci-cli >/dev/null || yum install -y oci-cli >/dev/null
  fi
fi
case "$FS_TYPE" in
  xfs) command -v mkfs.xfs >/dev/null 2>&1 || install_pkg xfsprogs ;;
  ext4) command -v mkfs.ext4 >/dev/null 2>&1 || install_pkg e2fsprogs ;;
  *) log "Unsupported FS_TYPE=$FS_TYPE"; exit 1 ;;
esac

# --- Instance metadata & auth ---
MD="http://169.254.169.254/opc/v2"; H="Authorization: Bearer Oracle"
INSTANCE_ID=$(curl -sS -H "$H" "$MD/instance/id")
AD=$(curl -sS -H "$H" "$MD/instance/availabilityDomain")
COMP_OCID="${VOLUME_COMPARTMENT_OCID:-$(curl -sS -H "$H" "$MD/instance/compartmentId")}"
REGION=$(curl -sS -H "$H" "$MD/instance/regionInfo/regionIdentifier" 2>/dev/null || curl -sS -H "$H" "$MD/instance/region" 2>/dev/null || true)
[[ "$REGION" =~ ^[A-Z]{3}$ ]] && case "${REGION^^}" in
  IAD) REGION="us-ashburn-1" ;; PHX) REGION="us-phoenix-1" ;; FRA) REGION="eu-frankfurt-1" ;;
  LHR) REGION="uk-london-1" ;; AMS) REGION="eu-amsterdam-1" ;; *) REGION="${REGION,,}" ;;
esac
export OCI_CLI_AUTH=instance_principal
export OCI_CLI_REGION="${REGION:-us-ashburn-1}"
export OCI_CLI_CONNECTION_TIMEOUT=20
export OCI_CLI_READ_TIMEOUT=60
log "Instance: $INSTANCE_ID"; log "AD: $AD"; log "Region: $OCI_CLI_REGION"

# --- Create volume ---
VOL_NAME="auto-${HOSTNAME}-$(date +%Y%m%d-%H%M%S)"
args=(bv volume create --availability-domain "$AD" --compartment-id "$COMP_OCID" --display-name "$VOL_NAME" --size-in-gbs "$VOL_SIZE_GB")
[ -n "${VPUS_PER_GB:-}" ] && args+=(--vpus-per-gb "$VPUS_PER_GB")
log "Creating volume $VOL_NAME ($VOL_SIZE_GB GB, vpus/GB=${VPUS_PER_GB:-""})..."
VOL_OCID=$(oci "${args[@]}" --query 'data.id' --raw-output)
log "Volume: $VOL_OCID"

# --- Wait AVAILABLE (bounded to ~3 min) ---
log "Waiting for AVAILABLE..."
MAX=180; T=0
while :; do
  STATE=$(oci bv volume get --volume-id "$VOL_OCID" --query 'data."lifecycle-state"' --raw-output 2>/dev/null || true)
  [ -n "$STATE" ] && log "State: $STATE"
  [ "$STATE" = "AVAILABLE" ] && break
  [[ "$STATE" =~ ^(FAULTY|TERMINATED)$ ]] && { log "Volume in $STATE"; exit 1; }
  [ $T -ge $MAX ] && { log "Timeout waiting for AVAILABLE"; exit 1; }
  sleep 5; T=$((T+5))
done

# --- Attach (check existing, then create, then wait up to ~3 min) ---
BEFORE=$(lsblk -dn -o NAME | sed 's#^#/dev/#' | sort)
ATTACH_OCID=$(oci compute volume-attachment list --all --instance-id "$INSTANCE_ID" \
  --query "data[?\"volume-id\"=='$VOL_OCID'] | [0].id" --raw-output 2>/dev/null || true)
[ "$ATTACH_OCID" = "null" ] && ATTACH_OCID=""
if [ -n "$ATTACH_OCID" ]; then
  log "Using existing attachment: $ATTACH_OCID"
else
  log "Attaching ($ATTACH_TYPE)..."
  ATTACH_OCID=$(oci compute volume-attachment attach --type "$ATTACH_TYPE" \
    --instance-id "$INSTANCE_ID" --volume-id "$VOL_OCID" \
    --is-shareable false --is-read-only false \
    --query 'data.id' --raw-output 2>/tmp/attach.err) || { log "Attach failed"; cat /tmp/attach.err | tee -a "$LOG_FILE"; exit 1; }
fi
# Wait for ATTACHED
log "Waiting for ATTACHED..."
MAX=180; T=0
while :; do
  STATE=$(oci compute volume-attachment get --volume-attachment-id "$ATTACH_OCID" \
    --query 'data."lifecycle-state"' --raw-output 2>/dev/null || true)
  [ "$STATE" = "ATTACHED" ] && break
  [ -n "$STATE" ] && log "State: $STATE"
  [ $T -ge $MAX ] && { log "Timeout waiting for ATTACHED"; exit 1; }
  sleep 3; T=$((T+3))
done
log "Attached: $ATTACH_OCID"

# --- Encourage device creation & find device (bounded retries) ---
for host in /sys/class/scsi_host/host*; do echo "- - -" > "$host/scan" 2>/dev/null || true; done
command -v udevadm >/dev/null 2>&1 && { udevadm trigger --action=change >/dev/null 2>&1 || true; udevadm settle --timeout=30 >/dev/null 2>&1 || true; }
NEW_DEV=""
for i in 1 2 3 4; do
  # by-id with OCID
  if [ -z "$NEW_DEV" ] && [ -d /dev/disk/by-id ]; then
    id=$(ls -1 /dev/disk/by-id 2>/dev/null | grep -i "$VOL_OCID" | head -n1 || true)
    [ -n "$id" ] && NEW_DEV=$(readlink -f "/dev/disk/by-id/$id" || true)
  fi
  # diff before/after
  if [ -z "$NEW_DEV" ]; then
    after=$(lsblk -dn -o NAME | sed 's#^#/dev/#' | sort)
    NEW_DEV=$(comm -13 <(echo "$BEFORE") <(echo "$after") || true | tail -n1)
  fi
  # oracleoci symlink
  if [ -z "$NEW_DEV" ] && [ -d /dev/oracleoci ]; then
    cand=$(ls -1 /dev/oracleoci/oraclevd* 2>/dev/null | sort | tail -n1)
    [ -n "$cand" ] && NEW_DEV=$(readlink -f "$cand" || true)
  fi
  [ -n "$NEW_DEV" ] && [ -b "$NEW_DEV" ] && break
  sleep 2
done
[ -n "$NEW_DEV" ] || { log "Cannot identify device"; dmesg | tail -n 50 | sed 's/^/[dmesg] /' | tee -a "$LOG_FILE"; exit 1; }
# Normalize to whole disk & sanity check
[ "$(lsblk -dn -o TYPE "$NEW_DEV" 2>/dev/null || echo "")" = "part" ] && NEW_DEV="/dev/$(lsblk -no PKNAME "$NEW_DEV")"
lsblk -n -o MOUNTPOINT "$NEW_DEV" | grep -qE '\S' && { log "Device $NEW_DEV already mounted"; exit 1; }
ROOT_PK=$(lsblk -no PKNAME "$(readlink -f "$(findmnt -no SOURCE / || echo)")" 2>/dev/null || true)
[ -n "$ROOT_PK" ] && [ "/dev/$ROOT_PK" = "$NEW_DEV" ] && { log "Refusing root disk $NEW_DEV"; exit 1; }
log "Device: $NEW_DEV"

# --- Filesystem partition creation & mounting ---
if blkid "$NEW_DEV" >/dev/null 2>&1; then log "FS exists on $NEW_DEV"
else
  log "mkfs $FS_TYPE on $NEW_DEV"
  [ "$FS_TYPE" = "xfs" ] && mkfs.xfs -f "$NEW_DEV" || mkfs.ext4 -F "$NEW_DEV"
fi
mkdir -p "$MOUNT_POINT"
UUID=$(blkid -s UUID -o value "$NEW_DEV" || true)
[ -n "$UUID" ] || { log "No UUID for $NEW_DEV"; exit 1; }
grep -qE "[[:space:]]$MOUNT_POINT[[:space:]]" /etc/fstab && { cp /etc/fstab /etc/fstab.bak.$(date +%s); sed -i "\|[[:space:]]$MOUNT_POINT[[:space:]]|d" /etc/fstab; }
[ "$FS_TYPE" = "xfs" ] && echo "UUID=$UUID  $MOUNT_POINT  xfs  defaults,noatime  0 2" >> /etc/fstab || echo "UUID=$UUID  $MOUNT_POINT  ext4 defaults,noatime  0 2" >> /etc/fstab
mount -a
mountpoint -q "$MOUNT_POINT" || { log "Mount failed"; exit 1; }
log "Mounted at $MOUNT_POINT"
log "Success."

# --- Ensure OKE init runs (critical for cluster join) ---
if [ -f /var/run/oke-init.done ]; then
  log "OKE init script has already been executed. Skipping re-run."
else
  if curl --fail -H "Authorization: Bearer Oracle" -sL http://169.254.169.254/opc/v2/instance/metadata/oke_init_script >/dev/null 2>&1; then
    curl --fail -H "Authorization: Bearer Oracle" -sL http://169.254.169.254/opc/v2/instance/metadata/oke_init_script | base64 --decode >/var/run/oke-init.sh 2>/dev/null || true
    if [ -s /var/run/oke-init.sh ]; then
      log "Running OKE init script..."
      bash /var/run/oke-init.sh || log "OKE init completed with status $?"
      # Create a flag file to indicate OKE init script has been run
      touch /var/run/oke-init.done
    else
      log "No OKE init script found."
    fi
  else
    log "No OKE init script in metadata; skipping."
  fi
fi
