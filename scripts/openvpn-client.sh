#!/usr/bin/env bash
# Issue and revoke per-client OpenVPN certificates.
#
# Every client gets its own key and a certificate signed by the CA in SSM.
# Nothing here creates a shared client certificate, a username, or a
# password. Profiles are written to disk and are not printed.
#
# Address plan is 10.8.0.0/24. Keep it in sync with infra/vpn/variables.tf
# (vpn_cidr). Static addresses are 10.8.0.10 through 10.8.0.199.
#
# Requires bash, openssl, python3, and AWS CLI v2, with administrator
# credentials in account 457504029722, region us-west-2. Do not run under
# bash -x. Secrets would land in the trace.

set -euo pipefail
umask 077

case $- in
  *x*)
    echo "openvpn-client: refusing to run under xtrace" >&2
    exit 1
    ;;
esac

export AWS_PAGER=""

# Fixed to the stack's region. A stray AWS_REGION in the shell must not
# write the CA into another region. OPENVPN_AWS_REGION overrides it.
if [ -n "${OPENVPN_AWS_REGION:-}" ]; then
  AWS_REGION="$OPENVPN_AWS_REGION"
else
  AWS_REGION="us-west-2"
fi
export AWS_REGION
export AWS_DEFAULT_REGION="$AWS_REGION"

EXPECTED_ACCOUNT="457504029722"
SERVER_CN="openvpn-server"
VPN_PREFIX="10.8.0"
REMOTE_HOST="vpn.app.sapienexmachina.si"
CERT_DAYS="1825"
CA_DAYS="3650"

P_CA_KEY="/openvpn/secrets/ca.key"
P_CA_CRT="/openvpn/pki/ca.crt"
P_SERVER_CRT="/openvpn/pki/server.crt"
P_SERVER_KEY="/openvpn/pki/server.key"
P_TLS_CRYPT="/openvpn/pki/tls-crypt.key"
P_CRL="/openvpn/pki/crl.pem"
P_INDEX="/openvpn/secrets/db/index.txt"
P_SERIAL="/openvpn/secrets/db/serial"
P_CRLNUM="/openvpn/secrets/db/crlnumber"
P_ATTR="/openvpn/secrets/db/index.txt.attr"
P_LOCK="/openvpn/secrets/lock"

WORKDIR=""
LOCK_HELD=0
LOCK_TOKEN=""

usage() {
  cat <<'EOF'
Usage:
  openvpn-client.sh init
  openvpn-client.sh add <name> [--ip <vpn-ip>]
  openvpn-client.sh revoke <name>
  openvpn-client.sh show <name> [--output <file>]
  openvpn-client.sh list

Each client gets its own CA-signed certificate and key. There is no
shared client certificate and no username or password. init, add, and
revoke write to SSM Parameter Store. show writes a .ovpn and does not
print it. Run this from the same administrator shell used for
infra/bootstrap, not on the Windows PC.
EOF
}

die() {
  echo "openvpn-client: $*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

cleanup() {
  local status=$?
  if [ "$LOCK_HELD" = "1" ]; then
    release_lock || true
  fi
  if [ -n "$WORKDIR" ] && [ -d "$WORKDIR" ]; then
    find "$WORKDIR" -type f -exec shred -u {} + 2>/dev/null || true
    rm -rf "$WORKDIR"
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 1' INT TERM

release_lock() {
  local existing=""
  [ "$LOCK_HELD" = "1" ] || return 0
  existing="$(aws ssm get-parameter --name "$P_LOCK" --query Parameter.Value --output text --region "$AWS_REGION" 2>/dev/null || true)"
  case "$existing" in
    *:"$LOCK_TOKEN")
      aws ssm delete-parameter --name "$P_LOCK" --region "$AWS_REGION" >/dev/null 2>&1 || true
      ;;
  esac
  LOCK_HELD=0
}

acquire_lock() {
  local now token value err existing ts
  now="$(date +%s)"
  token="$(openssl rand -hex 16)"
  value="${now}:${token}"
  if err="$(aws ssm put-parameter --name "$P_LOCK" --type String --value "$value" --no-overwrite --region "$AWS_REGION" 2>&1)"; then
    LOCK_TOKEN="$token"
    LOCK_HELD=1
    return 0
  fi
  case "$err" in
    *ParameterAlreadyExists*) ;;
    *) die "cannot create PKI lock: $err" ;;
  esac
  existing="$(aws ssm get-parameter --name "$P_LOCK" --query Parameter.Value --output text --region "$AWS_REGION")"
  ts="${existing%%:*}"
  case "$ts" in
    ''|*[!0-9]*) die "PKI lock at $P_LOCK is unreadable. Delete it if no other run is active." ;;
  esac
  if [ "$ts" -lt $((now - 900)) ]; then
    aws ssm delete-parameter --name "$P_LOCK" --region "$AWS_REGION" >/dev/null
    if ! aws ssm put-parameter --name "$P_LOCK" --type String --value "$value" --no-overwrite --region "$AWS_REGION" >/dev/null 2>&1; then
      die "PKI lock is held. Wait, or delete $P_LOCK if the other run died."
    fi
    LOCK_TOKEN="$token"
    LOCK_HELD=1
    return 0
  fi
  die "PKI lock is held. Wait, or delete $P_LOCK if the other run died."
}

require_account() {
  local account
  account="$(aws sts get-caller-identity --query Account --output text)"
  if [ "$account" != "$EXPECTED_ACCOUNT" ]; then
    die "this script only runs in account ${EXPECTED_ACCOUNT} (caller is ${account})"
  fi
}

ssm_exists() {
  local out
  if out="$(aws ssm get-parameter --name "$1" --query Parameter.Name --output text --region "$AWS_REGION" 2>&1)"; then
    return 0
  fi
  case "$out" in
    *ParameterNotFound*) return 1 ;;
  esac
  die "cannot read $1: $out"
}

ssm_put_file() {
  local name="$1"
  local type="$2"
  local file="$3"
  local src="$file"
  local size
  if [ ! -s "$file" ]; then
    src="$WORKDIR/empty-sentinel"
    printf '%s' '__EMPTY__' >"$src"
  fi
  size="$(wc -c <"$src")"
  if [ "$size" -gt 4096 ]; then
    die "$name is ${size} bytes. A standard SSM parameter holds 4096 bytes."
  fi
  aws ssm put-parameter --name "$name" --type "$type" --value "file://${src}" --overwrite --region "$AWS_REGION" >/dev/null
}

ssm_put_text() {
  aws ssm put-parameter --name "$1" --type String --value "$2" --overwrite --region "$AWS_REGION" >/dev/null
}

ssm_get_text() {
  aws ssm get-parameter --name "$1" --query Parameter.Value --output text --region "$AWS_REGION"
}

ssm_get_file() {
  local name="$1"
  local dest="$2"
  aws ssm get-parameter --name "$name" --with-decryption --output json --region "$AWS_REGION" \
    | python3 -c 'import json,sys; value=json.load(sys.stdin)["Parameter"]["Value"]; open(sys.argv[1],"w",encoding="utf-8").write("" if value=="__EMPTY__" else value)' "$dest"
}

ssm_delete() {
  aws ssm delete-parameter --name "$1" --region "$AWS_REGION" >/dev/null
}

client_cert_param() { printf '%s\n' "/openvpn/secrets/clients/$1/cert"; }
client_key_param() { printf '%s\n' "/openvpn/secrets/clients/$1/key"; }
client_ip_param() { printf '%s\n' "/openvpn/clients/$1/ip"; }
client_status_param() { printf '%s\n' "/openvpn/clients/$1/status"; }

validate_name() {
  local name="$1"
  if [[ ! "$name" =~ ^[a-z][a-z0-9-]{0,31}$ ]]; then
    die "name must match ^[a-z][a-z0-9-]{0,31}\$ (example: windows-pc)"
  fi
  case "$name" in
    openvpn-server|server|ca)
      die "$name is reserved"
      ;;
  esac
}

validate_ip() {
  local ip="$1"
  local oct oct_num
  case "$ip" in
    "${VPN_PREFIX}."*) ;;
    *) die "ip must be inside ${VPN_PREFIX}.0/24, from ${VPN_PREFIX}.10 through ${VPN_PREFIX}.199" ;;
  esac
  oct="${ip##*.}"
  case "$oct" in
    ''|*[!0-9]*) die "ip must be inside ${VPN_PREFIX}.0/24" ;;
  esac
  oct_num=$((10#$oct))
  if [ "$oct" != "$oct_num" ]; then
    die "do not zero-pad the address"
  fi
  if [ "$oct_num" -lt 10 ] || [ "$oct_num" -gt 199 ]; then
    die "static ip must be ${VPN_PREFIX}.10 through ${VPN_PREFIX}.199 (.1 is the server, .200-.249 is the dynamic pool)"
  fi
}

prepare_work() {
  WORKDIR="$(mktemp -d)"
  chmod 700 "$WORKDIR"
}

write_cnf() {
  cat >"$WORKDIR/openssl.cnf" <<EOF
[ ca ]
default_ca = CA_default

[ CA_default ]
dir              = ${WORKDIR}
database         = ${WORKDIR}/index.txt
new_certs_dir    = ${WORKDIR}/newcerts
certificate      = ${WORKDIR}/ca.crt
serial           = ${WORKDIR}/serial
crlnumber        = ${WORKDIR}/crlnumber
crl              = ${WORKDIR}/crl.pem
private_key      = ${WORKDIR}/ca.key
default_days     = ${CERT_DAYS}
default_crl_days = 3650
default_md       = sha256
preserve         = no
policy           = policy_match
unique_subject   = no
copy_extensions  = none

[ policy_match ]
commonName = supplied

[ server_ext ]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = serverAuth
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer

[ client_ext ]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = clientAuth
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer

[ crl_ext ]
authorityKeyIdentifier = keyid:always
EOF
}

openssl_ca() {
  if ! openssl ca -batch -config "$WORKDIR/openssl.cnf" -notext -days "$CERT_DAYS" "$@" >"$WORKDIR/openssl.log" 2>&1; then
    echo "openvpn-client: openssl ca failed:" >&2
    cat "$WORKDIR/openssl.log" >&2
    exit 1
  fi
}

openssl_gencrl() {
  if ! openssl ca -batch -config "$WORKDIR/openssl.cnf" -gencrl -crlexts crl_ext -out "$WORKDIR/crl.pem" >"$WORKDIR/openssl.log" 2>&1; then
    echo "openvpn-client: openssl gencrl failed:" >&2
    cat "$WORKDIR/openssl.log" >&2
    exit 1
  fi
}

openssl_revoke() {
  if ! openssl ca -batch -config "$WORKDIR/openssl.cnf" -revoke "$1" >"$WORKDIR/openssl.log" 2>&1; then
    echo "openvpn-client: openssl revoke failed:" >&2
    cat "$WORKDIR/openssl.log" >&2
    exit 1
  fi
}

assert_cn() {
  local file="$1"
  local expected="$2"
  local subj
  subj="$(openssl x509 -in "$file" -noout -subject -nameopt RFC2253)"
  if [ "$subj" != "subject=CN=${expected}" ]; then
    die "$file subject is '$subj', expected CN=${expected}"
  fi
}

assert_eku() {
  local file="$1"
  local expected="$2"
  local text
  text="$(openssl x509 -in "$file" -noout -ext extendedKeyUsage)"
  case "$text" in
    *"$expected"*) ;;
    *) die "$file is missing extendedKeyUsage $expected" ;;
  esac
}

upload_db() {
  ssm_put_file "$P_INDEX" SecureString "$WORKDIR/index.txt"
  ssm_put_file "$P_SERIAL" SecureString "$WORKDIR/serial"
  ssm_put_file "$P_CRLNUM" SecureString "$WORKDIR/crlnumber"
  if [ -f "$WORKDIR/index.txt.attr" ]; then
    ssm_put_file "$P_ATTR" SecureString "$WORKDIR/index.txt.attr"
  fi
}

download_db() {
  ssm_get_file "$P_CA_KEY" "$WORKDIR/ca.key"
  ssm_get_file "$P_CA_CRT" "$WORKDIR/ca.crt"
  ssm_get_file "$P_INDEX" "$WORKDIR/index.txt"
  ssm_get_file "$P_SERIAL" "$WORKDIR/serial"
  ssm_get_file "$P_CRLNUM" "$WORKDIR/crlnumber"
  chmod 600 "$WORKDIR/ca.key"
  if ssm_exists "$P_ATTR"; then
    ssm_get_file "$P_ATTR" "$WORKDIR/index.txt.attr"
  fi
  mkdir -p "$WORKDIR/newcerts"
  write_cnf
}

fetch_clients() {
  aws ssm get-parameters-by-path --path /openvpn/clients --recursive --output json --region "$AWS_REGION" >"$WORKDIR/clients.json"
}

pick_ip() {
  python3 - "$WORKDIR/clients.json" "$1" "$2" "$VPN_PREFIX" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)
name = sys.argv[2]
requested = sys.argv[3]
prefix = sys.argv[4]
used = {}
for item in data.get("Parameters", []):
    parts = item["Name"].strip("/").split("/")
    if len(parts) == 4 and parts[3] == "ip":
        used[parts[2]] = item["Value"].strip()
if requested:
    for other, ip in used.items():
        if ip == requested and other != name:
            sys.stderr.write("ip %s is reserved for %s\n" % (requested, other))
            sys.exit(1)
    print(requested)
    sys.exit(0)
if name in used and used[name]:
    print(used[name])
    sys.exit(0)
taken = set(used.values())
for number in range(10, 200):
    ip = "%s.%d" % (prefix, number)
    if ip not in taken:
        print(ip)
        sys.exit(0)
sys.stderr.write("no free static addresses in %s.10-199\n" % prefix)
sys.exit(1)
PY
}

write_tls_crypt() {
  python3 - "$WORKDIR/tls-crypt.key" <<'PY'
import pathlib
import secrets
import sys

lines = [secrets.token_hex(16) for _ in range(16)]
pathlib.Path(sys.argv[1]).write_text(
    "-----BEGIN OpenVPN Static key V1-----\n"
    + "\n".join(lines)
    + "\n-----END OpenVPN Static key V1-----\n",
    encoding="utf-8",
)
PY
  chmod 600 "$WORKDIR/tls-crypt.key"
}

render_ovpn() {
  python3 - "$WORKDIR" "$1" "$2" "$3" "$4" "$5" <<'PY'
import pathlib
import sys

work = pathlib.Path(sys.argv[1])
name, vpn_ip, remote_ip, server_cn, dest = sys.argv[2:]

def read(path):
    return path.read_text(encoding="utf-8").strip() + "\n"

parts = [
    "# Dedicated certificate for %s. Do not share this file.\n" % name,
    "# vpn-ip: %s\n" % vpn_ip,
    "# Split tunnel: no redirect-gateway. The server pushes the VPN subnet\n",
    "# and the GoNetLogo CIDR when the server is set to push it.\n",
    "# No username or password. Authentication is this certificate.\n",
    "client\n",
    "dev tun\n",
    "proto udp\n",
    "remote %s 1194 udp\n" % remote_ip,
    "resolv-retry infinite\n",
    "nobind\n",
    "persist-key\n",
    "persist-tun\n",
    "remote-cert-tls server\n",
    "verify-x509-name %s name\n" % server_cn,
    "tls-version-min 1.2\n",
    "auth SHA256\n",
    "data-ciphers AES-256-GCM:CHACHA20-POLY1305\n",
    "verb 3\n",
    "auth-nocache\n",
    "<ca>\n",
    read(work / "ca.crt"),
    "</ca>\n",
    "<cert>\n",
    read(work / "client.crt"),
    "</cert>\n",
    "<key>\n",
    read(work / "client.key"),
    "</key>\n",
    "<tls-crypt>\n",
    read(work / "tls-crypt.key"),
    "</tls-crypt>\n",
]
path = pathlib.Path(dest)
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text("".join(parts), encoding="utf-8")
path.chmod(0o600)
PY
}

cmd_init() {
  [ $# -eq 0 ] || die "init takes no arguments"
  require_account
  if ssm_exists "$P_CA_KEY"; then
    die "CA already exists at $P_CA_KEY. Refusing to overwrite."
  fi
  acquire_lock
  if ssm_exists "$P_CA_KEY"; then
    die "CA already exists at $P_CA_KEY. Refusing to overwrite."
  fi
  prepare_work
  write_cnf
  : >"$WORKDIR/index.txt"
  printf '1000\n' >"$WORKDIR/serial"
  printf '1000\n' >"$WORKDIR/crlnumber"
  mkdir -p "$WORKDIR/newcerts"

  openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$WORKDIR/ca.key"
  chmod 600 "$WORKDIR/ca.key"
  openssl req -new -x509 -key "$WORKDIR/ca.key" -sha256 -days "$CA_DAYS" \
    -subj "/CN=OpenVPN CA" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -addext "subjectKeyIdentifier=hash" \
    -out "$WORKDIR/ca.crt"
  openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$WORKDIR/server.key"
  chmod 600 "$WORKDIR/server.key"
  openssl req -new -key "$WORKDIR/server.key" -subj "/CN=${SERVER_CN}" -out "$WORKDIR/server.csr"
  openssl_ca -extensions server_ext -in "$WORKDIR/server.csr" -out "$WORKDIR/server.crt"
  assert_cn "$WORKDIR/server.crt" "$SERVER_CN"
  assert_eku "$WORKDIR/server.crt" "TLS Web Server Authentication"
  openssl verify -CAfile "$WORKDIR/ca.crt" "$WORKDIR/server.crt" >/dev/null
  openssl_gencrl
  write_tls_crypt

  ssm_put_file "$P_CA_KEY" SecureString "$WORKDIR/ca.key"
  ssm_put_file "$P_CA_CRT" SecureString "$WORKDIR/ca.crt"
  ssm_put_file "$P_SERVER_KEY" SecureString "$WORKDIR/server.key"
  ssm_put_file "$P_SERVER_CRT" SecureString "$WORKDIR/server.crt"
  ssm_put_file "$P_TLS_CRYPT" SecureString "$WORKDIR/tls-crypt.key"
  ssm_put_file "$P_CRL" SecureString "$WORKDIR/crl.pem"
  upload_db
  printf 'ca: stored\nserver_cn: %s\ntls: one certificate per client, tls-crypt, CRL\nnext: scripts/openvpn-client.sh add windows-pc --ip 10.8.0.10\n' "$SERVER_CN"
}

cmd_add() {
  local name ip="" status="" vpn_ip serial
  name="${1:-}"
  [ -n "$name" ] || die "usage: openvpn-client.sh add <name> [--ip <vpn-ip>]"
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --ip)
        [ $# -ge 2 ] || die "--ip needs an address"
        ip="$2"
        shift 2
        ;;
      *)
        die "unknown argument: $1"
        ;;
    esac
  done
  validate_name "$name"
  if [ -n "$ip" ]; then
    validate_ip "$ip"
  fi
  require_account
  if ! ssm_exists "$P_CA_KEY"; then
    die "no CA at $P_CA_KEY. Run init first."
  fi
  acquire_lock
  prepare_work
  download_db
  fetch_clients
  if ssm_exists "$(client_status_param "$name")"; then
    status="$(ssm_get_text "$(client_status_param "$name")")"
  fi
  if [ "$status" = "active" ]; then
    die "client $name is already active. Revoke it before issuing another certificate."
  fi
  vpn_ip="$(pick_ip "$name" "$ip")"
  openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$WORKDIR/client.key"
  chmod 600 "$WORKDIR/client.key"
  openssl req -new -key "$WORKDIR/client.key" -subj "/CN=${name}" -out "$WORKDIR/client.csr"
  openssl_ca -extensions client_ext -in "$WORKDIR/client.csr" -out "$WORKDIR/client.crt"
  assert_cn "$WORKDIR/client.crt" "$name"
  assert_eku "$WORKDIR/client.crt" "TLS Web Client Authentication"
  openssl verify -CAfile "$WORKDIR/ca.crt" "$WORKDIR/client.crt" >/dev/null
  upload_db
  ssm_put_file "$(client_cert_param "$name")" SecureString "$WORKDIR/client.crt"
  ssm_put_file "$(client_key_param "$name")" SecureString "$WORKDIR/client.key"
  ssm_put_text "$(client_ip_param "$name")" "$vpn_ip"
  ssm_put_text "$(client_status_param "$name")" "active"
  serial="$(openssl x509 -in "$WORKDIR/client.crt" -noout -serial)"
  serial="${serial#serial=}"
  printf 'client: %s\nvpn_ip: %s\nserial: %s\nstatus: active\ndownload: scripts/openvpn-client.sh show %s\n' \
    "$name" "$vpn_ip" "$serial" "$name"
}

cmd_revoke() {
  local name status vpn_ip
  name="${1:-}"
  [ -n "$name" ] || die "usage: openvpn-client.sh revoke <name>"
  shift
  [ $# -eq 0 ] || die "revoke takes only the client name"
  validate_name "$name"
  require_account
  if ! ssm_exists "$(client_status_param "$name")"; then
    die "no client named $name"
  fi
  status="$(ssm_get_text "$(client_status_param "$name")")"
  if [ "$status" != "active" ]; then
    die "client $name is ${status}, not active"
  fi
  vpn_ip="$(ssm_get_text "$(client_ip_param "$name")")"
  acquire_lock
  prepare_work
  download_db
  ssm_get_file "$(client_cert_param "$name")" "$WORKDIR/client.crt"
  openssl_revoke "$WORKDIR/client.crt"
  openssl_gencrl
  upload_db
  ssm_put_file "$P_CRL" SecureString "$WORKDIR/crl.pem"
  ssm_put_text "$(client_status_param "$name")" "revoked"
  ssm_delete "$(client_key_param "$name")"
  printf 'client: %s\nstatus: revoked\nvpn_ip: %s\n' "$name" "$vpn_ip"
}

cmd_show() {
  local name="" output="" status vpn_ip server_cn dest parent
  name="${1:-}"
  [ -n "$name" ] || die "usage: openvpn-client.sh show <name> [--output <file>]"
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --output)
        [ $# -ge 2 ] || die "--output needs a path"
        output="$2"
        shift 2
        ;;
      *)
        die "unknown argument: $1"
        ;;
    esac
  done
  validate_name "$name"
  require_account
  if ! ssm_exists "$(client_status_param "$name")"; then
    die "no client named $name"
  fi
  status="$(ssm_get_text "$(client_status_param "$name")")"
  if [ "$status" != "active" ]; then
    die "client $name is ${status}. Its key has been deleted. Run add to issue a new certificate."
  fi
  vpn_ip="$(ssm_get_text "$(client_ip_param "$name")")"
  prepare_work
  ssm_get_file "$P_CA_CRT" "$WORKDIR/ca.crt"
  ssm_get_file "$P_SERVER_CRT" "$WORKDIR/server.crt"
  ssm_get_file "$(client_cert_param "$name")" "$WORKDIR/client.crt"
  ssm_get_file "$(client_key_param "$name")" "$WORKDIR/client.key"
  ssm_get_file "$P_TLS_CRYPT" "$WORKDIR/tls-crypt.key"
  chmod 600 "$WORKDIR/client.key"
  assert_cn "$WORKDIR/client.crt" "$name"
  assert_eku "$WORKDIR/client.crt" "TLS Web Client Authentication"
  assert_cn "$WORKDIR/server.crt" "$SERVER_CN"
  server_cn="$SERVER_CN"
  if [ -n "$output" ]; then
    dest="$output"
  else
    dest="${PWD}/clients/${name}.ovpn"
  fi
  render_ovpn "$name" "$vpn_ip" "$REMOTE_HOST" "$server_cn" "$dest"
  chmod 600 "$dest"
  parent="$(dirname "$dest")"
  if [ "$(basename "$parent")" = "clients" ]; then
    chmod 700 "$parent"
  fi
  printf 'wrote: %s\nclient: %s\nvpn_ip: %s\nremote: %s\n' "$dest" "$name" "$vpn_ip" "$REMOTE_HOST"
}

cmd_list() {
  require_account
  prepare_work
  fetch_clients
  python3 - "$WORKDIR/clients.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)
ips = {}
status = {}
for item in data.get("Parameters", []):
    parts = item["Name"].strip("/").split("/")
    if len(parts) != 4:
        continue
    client, leaf = parts[2], parts[3]
    if leaf == "ip":
        ips[client] = item["Value"].strip()
    elif leaf == "status":
        status[client] = item["Value"].strip()
names = sorted(set(ips) | set(status))
if not names:
    print("no clients")
    sys.exit(0)
for name in names:
    print("%s %s %s" % (name, ips.get(name, "-"), status.get(name, "-")))
PY
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    ""|-h|--help|help)
      usage
      exit 0
      ;;
  esac
  need_cmd aws
  need_cmd openssl
  need_cmd python3
  shift
  case "$cmd" in
    init) cmd_init "$@" ;;
    add) cmd_add "$@" ;;
    revoke) cmd_revoke "$@" ;;
    show) cmd_show "$@" ;;
    list) cmd_list "$@" ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
}

main "$@"
