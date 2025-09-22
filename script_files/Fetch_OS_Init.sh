#!/bin/bash -ex
log() { echo "[$(date -u)] $*" >> /var/log/volume-init.log; }

# Install OCI CLI if not present (minimal, required for Object Storage access)
if ! command -v oci >/dev/null 2>&1; then
  log "Installing OCI CLI..."
  if command -v dnf >/dev/null 2>&1; then
    dnf install -y "oraclelinux-developer-release-el$(rpm -E %rhel)" >/dev/null 2>&1 || true
    dnf install -y python3-oci-cli >/dev/null 2>&1 || dnf install -y oci-cli >/dev/null 2>&1
  else
    yum install -y oraclelinux-developer-release-el7 >/dev/null 2>&1 || true
    yum install -y python36-oci-cli >/dev/null 2>&1 || yum install -y oci-cli >/dev/null 2>&1
  fi
  if ! command -v oci >/dev/null 2>&1; then
    log "Failed to install OCI CLI. Aborting."
    exit 1
  fi
fi

# Define modular variables for Object Storage
BUCKET_NAME="${BUCKET_NAME:-<bucket_name>}" #Bucket where Block volume attachment script is stored
OBJECT_PATH="${OBJECT_PATH:-<object_path>}" #Path to block volume attachment script object
NAMESPACE="${NAMESPACE:-<object_storage_namespace>}" #tenancy Object Storage Namespace
REGION="${REGION:-Ex.<us-ashburn-1>}" #Region where bucket is located
SCRIPT_LOCAL_PATH="/tmp/BV_OKE_Init.sh" #path to install script to 

# Fetch script from Object Storage
log "Fetching init script from Object Storage..."
mkdir -p "$(dirname "$SCRIPT_LOCAL_PATH")"
oci os object get --auth instance_principal --bucket-name "$BUCKET_NAME" --name "$OBJECT_PATH" --namespace-name "$NAMESPACE" --region "$REGION" --file "$SCRIPT_LOCAL_PATH" 2>/tmp/fetch.err || {
  log "Failed to fetch script"; cat /tmp/fetch.err >> /var/log/volume-init.log; exit 1;
}
chmod +x "$SCRIPT_LOCAL_PATH"

# Execute the script (block until complete, fail if it errors)
log "Running init script..."
"$SCRIPT_LOCAL_PATH" 2>&1 | tee -a /var/log/volume-init.log || {
  log "Init script failed with exit code $?"; exit 1;
}
log "Init complete."

# Check if OKE init has already been run by the Object Storage script
log "Checking for OKE cluster initialization..."
if [ -f /var/run/oke-init.done ]; then
  log "OKE init script has already been executed. Skipping re-run."
else
  if curl --fail -H "Authorization: Bearer Oracle" -sL http://169.254.169.254/opc/v2/instance/metadata/oke_init_script >/dev/null 2>&1; then
    log "Fetching OKE init script from metadata..."
    curl --fail -H "Authorization: Bearer Oracle" -sL http://169.254.169.254/opc/v2/instance/metadata/oke_init_script | base64 --decode >/var/run/oke-init.sh 2>/tmp/oke-fetch.err || {
      log "Failed to fetch OKE init script"; cat /tmp/oke-fetch.err >> /var/log/volume-init.log; exit 1;
    }
    if [ -s /var/run/oke-init.sh ]; then
      log "Running OKE init script for cluster join..."
      bash /var/run/oke-init.sh 2>&1 | tee -a /var/log/oke-init.log || log "OKE init completed with status $?"
      # Create a flag file to indicate OKE init script has been run
      touch /var/run/oke-init.done
      log "OKE cluster join complete."
    else
      log "OKE init script is empty or not found; skipping."
    fi
  else
    log "No OKE init script in metadata; skipping cluster join step."
  fi
fi
log "All initialization steps complete."
