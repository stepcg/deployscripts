#!/bin/bash

#┌──────────────────────────────────────────────────────────┐
#│             Convert Disk Image to Proxmox VM             │
#├──────────────────────────────────────────────────────────┤
#│ Quick script to convert a disk image to a Proxmox VM. If │
#│ possible you should use the ESXi import tool instead.    │
#└──────────────────────────────────────────────────────────┘


## Prepare and run checks
# Script variables
CORES="4"
IMPORT="/var/lib/vz/images/import.vmdk"
MEMORY="4096" # MB
POOL="local-zfs"
VMBR="vmbr0"
VMID=$(pvesh get /cluster/nextid)
VMNAME="imported-disk-vm"

# Check that the source IMPORT exists
if [ ! -e "${IMPORT}" ]; then
	echo "Error: ${IMPORT} not found." >&2
	exit 1
fi

# Check the default storage pool is available
if [ -z "$(pvesm status | grep ${POOL})" ]; then
	echo "Error: Storage pool ${POOL} not found." >&2
	exit 2
fi

# Check the vmbr exists
if [ -z "$(ip link | grep ${VMBR})" ]; then
	echo "Error: Network bridge ${VMBR} not found." >&2
	exit 3
fi


## Create the VM
qm create "${VMID}" --name "${VMNAME}" --memory "${MEMORY}" --sockets 1 --cores "${CORES}" --net0 "virtio,bridge=${VMBR}" 
qm importdisk "${VMID}" "${IMPORT}" "${POOL}"
qm set "${VMID}" --scsihw virtio-scsi-pci --virtio0 "${POOL}:vm-${VMID}-disk-0" --boot c --bootdisk virtio0

# Validate it
echo -e "\nVM imported - Config validation:\n"
qm config "${VMID}"
echo ""
