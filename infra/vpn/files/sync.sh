#!/bin/bash
# Pull server PKI and per-client static addresses from SSM and install
# them for OpenVPN. Safe to re-run. Does not print parameter values.
# The instance role can read /openvpn/pki and /openvpn/clients only.
set -euo pipefail
umask 077

# systemd's PATH already includes /usr/bin, where AL2023 puts the AWS CLI.
# Keep an existing aws (tests prepend a fake one) and only fill the gap.
if ! command -v aws >/dev/null 2>&1; then
  PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
fi
export PATH
export AWS_PAGER=""

dest="${OPENVPN_SYNC_DEST:-/etc/openvpn/server}"
work=""

cleanup() {
  if [ -n "$work" ] && [ -d "$work" ]; then
    rm -rf "$work"
  fi
}
trap cleanup EXIT

if [ -n "${OPENVPN_SYNC_REGION:-}" ]; then
  region="$OPENVPN_SYNC_REGION"
else
  token="$(curl -fsS -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 60")"
  region="$(curl -fsS -H "X-aws-ec2-metadata-token: $token" "http://169.254.169.254/latest/meta-data/placement/region")"
fi
export AWS_DEFAULT_REGION="$region"

work="$(mktemp -d)"

# OpenVPN drops to group openvpn and then re-reads the CRL and the
# client-config directory on every connection. /etc/openvpn/server is
# 0750 root:openvpn, so that group can enter it and nobody cannot.
# Private keys stay 0600 root and are read only before the drop
# (persist-key). Re-apply these modes on every run.
own() {
  local owner="$1"
  local mode="$2"
  local path="$3"
  chmod "$mode" "$path"
  if [ -n "${OPENVPN_SYNC_SKIP_CHOWN:-}" ]; then
    return 0
  fi
  if [ "$owner" = "root:openvpn" ] && ! getent group openvpn >/dev/null 2>&1; then
    echo "openvpn-sync: group openvpn is missing" >&2
    exit 1
  fi
  chown "$owner" "$path"
}

# The log directory is created by user-data. Sync only needs the config tree,
# so a test can point OPENVPN_SYNC_DEST at a writable directory.
install -d -m 0750 "$dest/ccd"
own root:openvpn 0750 "$dest"
own root:openvpn 0750 "$dest/ccd"

fetch() {
  local path="$1"
  local out="$2"
  aws ssm get-parameters-by-path \
    --path "$path" \
    --recursive \
    --with-decryption \
    --output json \
    --region "$region" >"$out"
}

fetch /openvpn/pki "$work/pki.json"
fetch /openvpn/clients "$work/clients.json"

python3 - "$work" <<'PY'
import json
import os
import sys

work = sys.argv[1]

def load(name):
    with open(os.path.join(work, name), encoding="utf-8") as handle:
        data = json.load(handle)
    return {item["Name"]: item["Value"] for item in data.get("Parameters", [])}

pki = load("pki.json")
clients = load("clients.json")
need = [
    "/openvpn/pki/ca.crt",
    "/openvpn/pki/server.crt",
    "/openvpn/pki/server.key",
    "/openvpn/pki/tls-crypt.key",
    "/openvpn/pki/crl.pem",
]
missing = [name for name in need if name not in pki or pki[name] in ("", "__EMPTY__")]
if missing:
    sys.stderr.write("openvpn-sync: missing SSM parameters: %s\n" % ", ".join(missing))
    sys.stderr.write("openvpn-sync: run scripts/openvpn-client.sh init from an admin shell first.\n")
    sys.exit(1)

out = os.path.join(work, "out")
os.makedirs(os.path.join(out, "ccd"), exist_ok=True)
mapping = {
    "/openvpn/pki/ca.crt": "ca.crt",
    "/openvpn/pki/server.crt": "server.crt",
    "/openvpn/pki/server.key": "server.key",
    "/openvpn/pki/tls-crypt.key": "tls-crypt.key",
    "/openvpn/pki/crl.pem": "crl.pem",
}
for name, filename in mapping.items():
    path = os.path.join(out, filename)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(pki[name])
    os.chmod(path, 0o600)

ips = {}
status = {}
for name, value in clients.items():
    parts = name.strip("/").split("/")
    if len(parts) != 4 or parts[0] != "openvpn" or parts[1] != "clients":
        continue
    client, leaf = parts[2], parts[3]
    if client in (".", "..") or not client:
        continue
    if leaf == "ip":
        ips[client] = value.strip()
    elif leaf == "status":
        status[client] = value.strip()

# 255.255.255.0 matches vpn_cidr 10.8.0.0/24 in infra/vpn/variables.tf.
for client, ip in sorted(ips.items()):
    if status.get(client) != "active" or not ip:
        continue
    path = os.path.join(out, "ccd", client)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write("ifconfig-push %s 255.255.255.0\n" % ip)
    os.chmod(path, 0o644)
PY

out="$work/out"
need_restart=0
for file in ca.crt server.crt server.key tls-crypt.key crl.pem; do
  if [ ! -f "$dest/$file" ] || ! cmp -s "$out/$file" "$dest/$file"; then
    need_restart=1
  fi
done

install -m 0640 "$out/ca.crt" "$dest/ca.crt"
install -m 0640 "$out/server.crt" "$dest/server.crt"
install -m 0600 "$out/server.key" "$dest/server.key"
install -m 0600 "$out/tls-crypt.key" "$dest/tls-crypt.key"
install -m 0640 "$out/crl.pem" "$dest/crl.pem"
own root:openvpn 0640 "$dest/ca.crt"
own root:openvpn 0640 "$dest/server.crt"
own root:root 0600 "$dest/server.key"
own root:root 0600 "$dest/tls-crypt.key"
own root:openvpn 0640 "$dest/crl.pem"

shopt -s nullglob
for file in "$out/ccd"/*; do
  installed="$dest/ccd/$(basename "$file")"
  install -m 0640 "$file" "$installed"
  own root:openvpn 0640 "$installed"
done
for existing in "$dest/ccd"/*; do
  base="$(basename "$existing")"
  if [ ! -f "$out/ccd/$base" ]; then
    rm -f "$existing"
  fi
done
shopt -u nullglob

count=0
shopt -s nullglob
for file in "$dest/ccd"/*; do
  count=$((count + 1))
done
shopt -u nullglob
echo "openvpn-sync: installed $count client address(es)" >&2

if [ "$need_restart" -eq 1 ] && [ -z "${OPENVPN_SYNC_NO_SYSTEMCTL:-}" ]; then
  if systemctl is-active --quiet openvpn-server@server; then
    echo "openvpn-sync: restarting OpenVPN to load server material or the CRL" >&2
    systemctl restart openvpn-server@server
  fi
fi
