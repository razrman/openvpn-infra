#!/bin/bash
# Packages and a swap file only. Do not write certificates, keys, client
# material, or SSH authorized_keys. User-data does that on the real server.
set -euo pipefail
umask 022

echo "openvpn ami: swap"
if ! swapon --show | grep -q /swapfile; then
  if ! fallocate -l 1G /swapfile; then
    dd if=/dev/zero of=/swapfile bs=1M count=1024
  fi
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  if ! grep -q /swapfile /etc/fstab; then
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
  fi
fi

echo "openvpn ami: packages"
installed=0
attempt=1
while [ "$attempt" -le 6 ]; do
  if dnf install -y python3 openvpn iptables-nft amazon-cloudwatch-agent; then
    installed=1
    break
  fi
  echo "openvpn ami: dnf failed, retry $attempt" >&2
  attempt=$((attempt + 1))
  sleep 10
done
if [ "$installed" -ne 1 ]; then
  echo "openvpn ami: package install failed" >&2
  exit 1
fi

rpm -q python3 openvpn iptables-nft amazon-cloudwatch-agent >/dev/null
command -v iptables >/dev/null
getent group openvpn >/dev/null
systemctl cat openvpn-server@.service >/dev/null

# The package is installed. The service starts only after user-data
# writes a config and enables it. Nothing here may pull SSM parameters.
systemctl disable openvpn-server@server >/dev/null 2>&1 || true
systemctl disable amazon-cloudwatch-agent >/dev/null 2>&1 || true

dnf clean all
rm -rf /var/cache/dnf

cloud-init clean --logs --seed
rm -rf /var/lib/cloud/instances /var/lib/cloud/instance
truncate -s 0 /etc/machine-id
rm -f /var/lib/systemd/random-seed
rm -f /home/ec2-user/.bash_history /root/.bash_history

# Packer's temporary key is the only key cloud-init installed. Drop it.
rm -f /home/ec2-user/.ssh/authorized_keys /root/.ssh/authorized_keys
rmdir /home/ec2-user/.ssh 2>/dev/null || true

# Host keys are per-instance private keys. Remove them so each server
# generates its own at first boot (cloud-init / sshd-keygen on AL2023).
rm -f /etc/ssh/ssh_host_*

if [ -s /home/ec2-user/.ssh/authorized_keys ] || [ -s /root/.ssh/authorized_keys ]; then
  echo "openvpn ami: refusing to bake an authorized_keys file" >&2
  exit 1
fi
if find /home /root /etc/ssh /etc/openvpn /var/lib/cloud -type f -size -2M -print0 2>/dev/null \
  | xargs -0 -r grep -l -E 'BEGIN (OPENSSH |RSA )?PRIVATE KEY' >/dev/null; then
  echo "openvpn ami: refusing to bake a private key" >&2
  exit 1
fi

echo "openvpn ami: done"
