# OCI Block Volume Setup for OKE Nodes

## Overview
This script automates the creation, attachment, and mounting of an OCI Block Volume to Oracle Kubernetes Engine (OKE) nodes during node pool scale-up. It supports formating the partition with either XFS or EXT4 based on your specification. The initialization script can be sourced from this public repository or downloaded and applied as part of the node pool specification in your init script.

## Prerequisites
- Run on an OCI instance with instance principal authentication enabled.
- Create a dynamic group for the instances using matching rules.
  - If using default tags from Oracle (e.g., Tag Namespace: `Oracle-Tags` & Key: `CreatedBy`), use a matching rule like:
    ```
    Any {resource.type = 'instance', tag.Oracle-Tags.CreatedBy.value = 'ocid1.nodepool.oc1.region.aaaaaaa…'}
    ```
  - If not using the default `Oracle-Tags` namespace, create a specific tag to apply to nodes created by the targeted node pool.

- Required permissions to manage Block Volumes and attachments in the specified compartment:
```
Allow dynamic-group <Group_Name> to manage volume-attachments in compartment <Compartment_Name>
```
```
Allow dynamic-group <Group_Name> to manage volumes in compartment <Compartment_Name>
```
```
Allow dynamic-group <Group_Name> to use instances in compartment <Compartment_Name>
```

- If using a separate init script that calls the Block Volume Attachment Script from Object Storage, add this policy:
```
Allow dynamic-group <Group_Name> to read object-family in compartment <Compartment_Name>
```

## How to incoporate in your workflow (Options):
- Curl the BV_OKE_Init script & execute as part of your current init script. Or
- Append the BV_OKE_Init script code block to your current init script. Or 
- Append the Fetch_OS_init code block into your current init script, put the BV_OKE_Init script into an Object Storage bucket. BV_OKE_Init is fetched and upon your init script running & completing successfully.


## Customization:
Override default configuration by setting environment variables before running the script:

- `VOL_SIZE_GB`: Volume size in GB (default: 100)
- `VPUS_PER_GB`: Performance units per GB (default: 10)
- `MOUNT_POINT`: Directory to mount the volume (default: `/data`)
- `FS_TYPE`: Filesystem type (`xfs` or `ext4`, default: `xfs`)
- `VOLUME_COMPARTMENT_OCID`: OCID of the compartment for the volume (default: instance compartment)
- `ATTACH_TYPE`: Attachment type (`paravirtualized` or `iscsi`, default: `paravirtualized`)
- `MOUNT_OWNER`: Owner of mount point (default: root)
- `MOUNT_GROUP`: Group for the mount point (default: root) 
- `MOUNT_PERMS`: Permissions for the mount point (default: 755)

## Functionality:
- Installs necessary tools (OCI CLI, filesystem utilities).
- Creates a Block Volume in the specified availability domain and compartment.
- Attaches the volume to the instance and waits for the attachment to complete.
- Identifies the new device, formats it (if needed), and mounts it to the specified directory.
- Updates `/etc/fstab` for persistent mounting.
- Runs the OKE initialization script from instance metadata (if available and not previously executed).
- Exits early if the mount point is already in use.
- Logs errors with detailed messages and exit codes.

## Check Logs:
Logs are written to the following locations for troubleshooting:
- `/var/log/volume-init.log`
- `/var/log/cloud-init-output.log`
