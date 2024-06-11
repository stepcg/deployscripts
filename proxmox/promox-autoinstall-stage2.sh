#!/bin/bash
#┌──────────────────────────────────────────────────────────────────────────────────────────────┐
#│                                 Proxmox Autoinstall Stage 2                                  │
#├──────────────────────────────────────────────────────────────────────────────────────────────┤
#│ Sets up the base proxmox host with some users and sane defaults. Runs updates and configrues │
#│ for free tier. Can be reconfigured to chainload further stages as well.                      │
#└──────────────────────────────────────────────────────────────────────────────────────────────┘

# Script variables
# The password as encrypted in /etc/shadow
PASSWORD='$y$j9T$h..kRJ8t1N.BvqSVwFbCz.$oQPkVsHO5dtXQlqN3IMKGYeg1o4.wIaT8husYlOs76B:19884:0:99999:7:::'
# Fix some binary path issues from crontab's lack of env vars
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Wait for system to be ready
until systemd-analyze | grep -q "Startup finished in"; do
	echo "Waiting for system to finish booting..."
	sleep 1
done

# Create the stepcg user in linux PAM and then add it to the proxmox gui administrators
useradd -m -s /bin/bash stepcg
usermod -aG sudo stepcg
pveum useradd stepcg@pam -comment "StepCG User"
pveum aclmod / -user stepcg@pam -role Administrator

# Set the passwords for both root and stepcg
sed -i "s/^stepcg:.*/stepcg:$PASSWORD/" /etc/shadow
sed -i "s/^root:.*/root:$PASSWORD/" /etc/shadow

# Disable the enterprise repos
sed -i "s/^/#/" /etc/apt/sources.list.d/pve-enterprise.list
sed -i "s/^/#/" /etc/apt/sources.list.d/ceph.list
echo "deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription" > /etc/apt/sources.list.d/pve-no-subscription.list
echo "deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription" >> /etc/apt/sources.list

# Remove nag message
wget -qO- https://raw.githubusercontent.com/foundObjects/pve-nag-buster/master/install.sh | bash

# Run updates
apt-get update
apt-get upgrade -y
pveam update

# Install sudo
apt-get install sudo

# Grab the latest Ubuntu 24.04 container template
pveam download local $(pveam available | grep ubuntu-24.04-standard | awk '/^system/ {print $2}')

# Set some sysctls for better networking
cat << 'EOF' > /etc/sysctl.d/net.conf
net.core.default_qdisc = fq
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.default_qdisc = cake

net.ipv4.ip_forward = 1
net.ipv4.ip_local_port_range = 30000 65535
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.udp_rmem_min = 32768
net.ipv4.udp_wmem_min = 32768

net.ipv6.conf.all.forwarding = 1
net.ipv6.ip_local_port_range = 30000 65535
net.ipv6.tcp_congestion_control = bbr
net.ipv6.tcp_fastopen = 3
net.ipv6.udp_rmem_min = 32768
net.ipv6.udp_wmem_min = 32768
net.ipv6.conf.all.accept_ra = 2
net.ipv6.conf.default.accept_ra = 2
net.ipv6.conf.vmbr0.accept_ra = 2
EOF
# Apply
sysctl -p

# Clear out the boot time script
rm -f /root/proxmox-autoinstall-stage1.sh /etc/cron.d/proxmox-autoinstall-stage1

# Reboot
reboot
