#!/bin/bash
# Masquerade tunnel clients toward one peered CIDR. The other VPC then
# routes the default VPC CIDR back to this instance. Nothing else is
# rewritten, and this is not a default-route NAT.
set -euo pipefail

vpn_cidr="${1:?vpn cidr required}"
peer_cidr="${2:?peer cidr required}"

sysctl -w net.ipv4.ip_forward=1
install -d /etc/sysctl.d
printf 'net.ipv4.ip_forward = 1\n' >/etc/sysctl.d/99-openvpn-forward.conf

iface="$(ip -4 route show default | awk '{print $5; exit}')"
if [ -z "$iface" ]; then
  echo "openvpn-nat: no default route" >&2
  exit 1
fi

if ! iptables -t nat -C POSTROUTING -s "$vpn_cidr" -d "$peer_cidr" -o "$iface" -j MASQUERADE 2>/dev/null; then
  iptables -t nat -A POSTROUTING -s "$vpn_cidr" -d "$peer_cidr" -o "$iface" -j MASQUERADE
fi

if ! iptables -C FORWARD -s "$vpn_cidr" -d "$peer_cidr" -j ACCEPT 2>/dev/null; then
  iptables -A FORWARD -s "$vpn_cidr" -d "$peer_cidr" -j ACCEPT
fi

if ! iptables -C FORWARD -s "$peer_cidr" -d "$vpn_cidr" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; then
  iptables -A FORWARD -s "$peer_cidr" -d "$vpn_cidr" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
fi

echo "openvpn-nat: $vpn_cidr -> $peer_cidr via $iface" >&2
