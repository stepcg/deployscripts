#!/bin/bash

#┌──────────────────────────────────────────────────────────────────────────────────────────────────┐
#│                                  Proxmox Autoinstall ISO Creator                                 │
#├──────────────────────────────────────────────────────────────────────────────────────────────────┤
#│ Creates a prebuilt and automated "/tmp/stepcg-proxmox.iso".                                      │
#│ On boot the host will attempt to load a stage 2 script from:                                     │
#│ https://raw.githubusercontent.com/stepcg/deployscripts/main/proxmox/promox-autoinstall-stage2.sh │
#└──────────────────────────────────────────────────────────────────────────────────────────────────┘

## Pre install automation
# Check we are running on a proxmox host
if [ $(uname -a | grep "\-pve " | wc -l) -ne 1 ]; then
	echo "This script is designed to be run on a proxmox host and this host was not detected as running a -pve kernel" >&2
	exit 1
fi

# Set some variables for the script
BASEDIR="/tmp"

ANSWER="${BASEDIR}/answer.toml"
INTERMEDIATEISO="${BASEDIR}/stepcg-proxmox-intermediate.iso"
OUTPUTISO="${BASEDIR}/stepcg-proxmox.iso"
ROOTFS="${BASEDIR}/pve-base"
STAGE1="/root/proxmox-autoinstall-stage1.sh"
CRON="${ROOTFS}/etc/cron.d/proxmox-autoinstall-stage1"

# Find the proxmox ISO
INPUTISO=$(find /var/lib/vz/template/iso/proxmox* -type f)
# and make sure exactly one ISO was found
if [ $(echo "${INPUTISO}" | wc -l) -ne 1 ]; then
	echo "Error: Multiple proxmox ISOs found in /var/lib/vz/template/iso/ when only the latest should exist." >&2
	exit 2
fi

# Make sure these packages are installed on the host and that the old entry is cleaned
rm "${OUTPUTISO}"
apt install proxmox-auto-install-assistant xorriso

# Create answer file
cat << 'EOF' > "${ANSWER}"
[global]
keyboard = "en-us"
country = "us"
fqdn = "stepcg-hv-base.stepcg.com"
mailto = "no@email.4u"
timezone = "UTC"
root_password = "initialsetup"
root_ssh_keys = [
    "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDLSfKZz7TU4ASPXLdoBLp68xKy3EMNF2zUXaCQ0zNe3yMirRLL6lcPTPhUaO0T4IkpgvvG3KtKyz4HLFGGx6y0cyuqb74qVGi2mhVGmHVhEdUWNOHYsZQ5appN5QXOSl+CPoKucZDzgafslDIKlX1qhPwAjBS4IW9dSWrg5oQebcljzIot9sIhqv62JzuFviaeVjRTLf3yyiC0Zff2oVAjkNQgZzG5ovTORstOmE7eWNdSr+MC8gbYYie0I6WntA+YeIl8cPSxXuIdJS3BzyCT4VcYi0Fm3IwuzzcJJ3Klb/eobSsYWHIPW7QUrWqrCmGcJ4DsJr+TKlD2drstZRdXWE6X8Ud9p3JMgSxQTgBuyzr/7CuznX0Z09nCEt8vfzfqzyKLDySq3UV1bg3Dc5udo6g7hQywNv1VG8EhSDCwqhEbrPZzJ4efxWBc1to+3fRiy+rKmjlB3K701/wa28L3bMenNO27ExjazvHcNfuIiWTksu1wcOdYLJIkvalf/byLFUPlj+QlZKdcGH7OacGaBMk7KjjyTsBjS4mbyFgzjBF6iCiNn2c/53bxlbax0ALh69OGqPoCdUIA16o/+rB1hhHwxWVLdY7IxSuHCW3qNBQ8FqwBoUu0Grt/x7z/MA5A5er1pQZj3mLNZII69GDt/ZP/66wjLDzLHEO2H8tA3Q== root@ds"
]

[network]
source = "from-dhcp"

[disk-setup]
filesystem = "zfs"
zfs.raid = "raid0"
filter.DEVNAME = "/dev/nvme*"
EOF

# Embed the answer file
proxmox-auto-install-assistant prepare-iso "${INPUTISO}" --fetch-from iso --answer-file "${ANSWER}" --tmp ${BASEDIR} --output "${INTERMEDIATEISO}" > /dev/null
# We don't need these files it creates
rm "${BASEDIR}/answer.toml" "${BASEDIR}/auto-installer-mode.toml"


## Post install automation
# Extract just pve-base.squashfs, add our script, then recreate it and add it back to the iso
xorriso -osirrox on -indev "${INTERMEDIATEISO}" -extract /pve-base.squashfs "${BASEDIR}/pve-base.squashfs"
unsquashfs -d "${ROOTFS}" /tmp/pve-base.squashfs
rm "${BASEDIR}/pve-base.squashfs"

# Create the stage 1 script itself
cat << 'EOF' > "${ROOTFS}/${STAGE1}"
#!/bin/bash

# Reconfigure the network to bond all interfaces as active/passive and DHCP
# Find all wired interfaces
INTERFACES=($(ip link | grep -E '^[0-9]+: (eth|en|em|p|eno|ens|enp|eno|enx)' | awk '{print substr($2, 1, length($2)-1)}'))

# Start the config with the loopback info
NETCONFIG="auto lo\niface lo inet loopback\n\n"

# "iface eth0 inet manual" type entries for each interface
for INTERFACE in "${INTERFACES[@]}"; do
	NETCONFIG+="iface ${INTERFACE} inet manaul\n"
done

# Add the bond and vmbr0
NETCONFIG+="\nauto bond0\niface bond0 inet manual\n\tbond-slaves"
for INTERFACE in "${INTERFACES[@]}"; do
	NETCONFIG+=" ${INTERFACE}"
done
NETCONFIG+="\n\tbond-mimon 100\n\tbond-mode active-backup\n\tpost-up echo 100 > /sys/class/net/bond0/bonding/miimon\n\nauto vmbr0\niface vmbr0 inet dhcp\n\tbridge-ports bond0\n\tbridge-stp off\n\tbridge-fd 0\n"

echo -e "${NETCONFIG}" > /etc/network/interfaces
systemctl restart networking

echo "Waiting for default route..."
while [ $(ip route | grep default | wc -l) -eq 0 ]; do
	sleep 1
done

# Execute stage 2
echo "Pulling and launching stage 2 script from GitHub..."
curl https://raw.githubusercontent.com/stepcg/deployscripts/main/proxmox/promox-autoinstall-stage2.sh | bash

# Note: it's up to stage 2 to decide when the stage 1 script should be removed!
EOF
chmod +x "${ROOTFS}/${STAGE1}"

# Create the crontab at boot entry
echo "@reboot root ${STAGE1}" > "${CRON}"

# Recreate squashfs and delete the temp rootfs
mksquashfs "${ROOTFS}" "${BASEDIR}/pve-base.squashfs"
rm -R "${ROOTFS}"

# Now put the squashfs back in the output iso
xorriso -indev "${INTERMEDIATEISO}" -outdev "${OUTPUTISO}" -map "${BASEDIR}/pve-base.squashfs" /pve-base.squashfs -boot_image any keep
rm "${INTERMEDIATEISO}" "${BASEDIR}/pve-base.squashfs"
