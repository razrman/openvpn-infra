#!/usr/bin/env bash
# CIDR parsing for VPN_ALLOWED_CIDRS, and iptables rendering for access.yaml.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "test-access: $*" >&2
  exit 1
}

cidrs() {
  VPN_ALLOWED_CIDRS="${1-}" bash "$root/scripts/allowed-cidrs.sh"
}

expect_cidrs() {
  local raw="$1"
  local want="$2"
  local got
  got="$(cidrs "$raw")"
  [ "$got" = "$want" ] || fail "CIDRs $(printf %q "$raw") rendered as $got, want $want"
}

expect_cidr_fail() {
  local raw="$1"
  local needle="$2"
  if VPN_ALLOWED_CIDRS="$raw" bash "$root/scripts/allowed-cidrs.sh" >"$tmp/out" 2>"$tmp/err"; then
    fail "expected CIDR failure for $(printf %q "$raw")"
  fi
  if ! grep -q "$needle" "$tmp/err"; then
    cat "$tmp/err" >&2
    fail "CIDR error for $(printf %q "$raw") did not mention $needle"
  fi
}

[ "$(cidrs "")" = '["0.0.0.0/0"]' ] || fail "blank allowlist should be the open default"
expect_cidrs "1.2.3.4/32, 203.0.113.0/24" '["1.2.3.4/32", "203.0.113.0/24"]'
expect_cidrs "1.2.3.4" '["1.2.3.4/32"]'
expect_cidrs '["10.1.2.0/24","10.9.0.8/32"]' '["10.1.2.0/24", "10.9.0.8/32"]'
expect_cidr_fail "1.2.3.5/24" "invalid CIDR"
expect_cidr_fail "999.1.1.1/32" "invalid CIDR"
expect_cidr_fail "::/0" "IPv6"
expect_cidr_fail "[]" "at least one"
expect_cidr_fail "[1, 2]" "strings"

cat >"$tmp/clients.json" <<'EOF'
{"linux-box":"10.8.0.11","windows-pc":"10.8.0.10","desktop-crnncuc":"10.8.0.13"}
EOF

python3 "$root/scripts/render-access.py" \
  "$root/infra/vpn/access.yaml" "$tmp/clients.json" 10.20.0.0/16 10.8.0 199 \
  >"$tmp/rules" 2>"$tmp/warn"
grep -q "client mac-mini is not active" "$tmp/warn" || fail "missing mac-mini should warn"
grep -q -- '-m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT' "$tmp/rules" || fail "established"
grep -q -- '-d 10.8.0.10 -s 10.8.0.11 -p tcp --dport 1337' "$tmp/rules" || fail "jan rule"
grep -q -- '-s 10.8.0.11 -d 10.8.0.10 -p icmp --icmp-type echo-request' "$tmp/rules" || fail "echo"
grep -q -- '-d 10.20.0.0/16 -s 10.8.0.11 -p tcp --dport 8080' "$tmp/rules" || fail "gonetlogo from linux-box"
grep -q -- '-d 10.20.0.0/16 -s 10.8.0.10 -p tcp --dport 8080' "$tmp/rules" || fail "gonetlogo from windows-pc"
if grep -q -- '-s 10.8.0.10 -d 10.8.0.11 -p tcp' "$tmp/rules"; then
  fail "windows-pc must not open tcp to linux-box"
fi
if grep -q '10.8.0.12' "$tmp/rules"; then
  fail "inactive mac-mini was rendered"
fi
if grep -E -q '10\.8\.0\.2[0-4][0-9]' "$tmp/rules"; then
  fail "dynamic pool was rendered"
fi
grep -q 'openvpn-drop:' "$tmp/rules" || fail "drop log"
grep -q -- '-j DROP' "$tmp/rules" || fail "drop"
grep -q -- '-A OPENVPN_IN -i tun+ -d 10.8.0.1 -s 10.8.0.13 -p tcp --dport 22' "$tmp/rules" || fail "ssh from desktop"
grep -q -- '-A OPENVPN_IN -i tun+ -d 10.8.0.1 -s 10.8.0.11 -p tcp --dport 22' "$tmp/rules" || fail "ssh from linux-box"
if grep -q -- '-s 10.8.0.10 -p tcp --dport 22' "$tmp/rules"; then
  fail "windows-pc must not have ssh"
fi
if grep -E -q 'from_port[[:space:]]*=[[:space:]]*22' "$root/infra/vpn/network.tf"; then
  fail "security group must not open port 22"
fi

empty_keys="$(VPN_SSH_AUTHORIZED_KEYS='' bash "$root/scripts/ssh-authorized-keys.sh")"
[ -z "$empty_keys" ] || fail "empty SSH variable should produce no keys"
fake='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeKeyForUnitTests unit-test'
got="$(VPN_SSH_AUTHORIZED_KEYS="$fake" bash "$root/scripts/ssh-authorized-keys.sh")"
[ "$got" = "$fake" ] || fail "public key was not kept"
if VPN_SSH_AUTHORIZED_KEYS='-----BEGIN OPENSSH PRIVATE KEY-----' bash "$root/scripts/ssh-authorized-keys.sh" >"$tmp/ssh.out" 2>"$tmp/ssh.err"; then
  fail "private key should be rejected"
fi
grep -q "private key" "$tmp/ssh.err" || fail "private key error text"

cat >"$tmp/pool.json" <<'EOF'
{"linux-box":"10.8.0.201"}
EOF
if python3 "$root/scripts/render-access.py" \
  "$root/infra/vpn/access.yaml" "$tmp/pool.json" 10.20.0.0/16 10.8.0 199 \
  >"$tmp/pool.out" 2>"$tmp/pool.err"; then
  fail "dynamic pool address should be rejected"
fi
grep -q "dynamic pool" "$tmp/pool.err" || fail "pool error text"

cat >"$tmp/bad.yaml" <<'EOF'
rules:
  - from: linux-box
    to: windows-pc
    proto: icmp
    port: 1337
EOF
if python3 "$root/scripts/render-access.py" \
  "$tmp/bad.yaml" "$tmp/clients.json" 10.20.0.0/16 10.8.0 199 \
  >"$tmp/bad.out" 2>"$tmp/bad.err"; then
  fail "bad proto should fail"
fi
grep -q "proto must be tcp or udp" "$tmp/bad.err" || fail "proto error text"

echo "test-access: ok"
