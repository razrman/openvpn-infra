#!/bin/bash
# Install the tunnel forward policy. Replacing the chain is one
# iptables-restore transaction, and established flows are accepted
# first, so a re-run does not cut a connection that is already open.
set -euo pipefail

clients="${1:?client address map}"
rules="${OPENVPN_ACCESS_RULES:-/etc/openvpn/access.yaml}"
peer="${OPENVPN_GONETLOGO_CIDR:-10.20.0.0/16}"
renderer="${OPENVPN_RENDER_ACCESS:-/usr/local/lib/render-access.py}"

sysctl -w net.ipv4.ip_forward=1 >/dev/null
install -d /etc/sysctl.d
printf '%s\n' 'net.ipv4.ip_forward = 1' 'net.ipv4.conf.all.rp_filter = 2' 'net.ipv4.conf.default.rp_filter = 2' \
  >/etc/sysctl.d/99-openvpn-forward.conf
sysctl -w net.ipv4.conf.all.rp_filter=2 >/dev/null
sysctl -w net.ipv4.conf.default.rp_filter=2 >/dev/null

fragment="$(python3 "$renderer" "$rules" "$clients" "$peer" 10.8.0 199)"
printf '%s\n' "$fragment" | iptables-restore --noflush

if ! iptables -C FORWARD -i tun+ -j OPENVPN_FWD 2>/dev/null; then
  iptables -A FORWARD -i tun+ -j OPENVPN_FWD
fi
if ! iptables -C FORWARD -o tun+ ! -i tun+ -j OPENVPN_FWD 2>/dev/null; then
  iptables -A FORWARD -o tun+ ! -i tun+ -j OPENVPN_FWD
fi

echo "openvpn-access: forward policy installed" >&2
