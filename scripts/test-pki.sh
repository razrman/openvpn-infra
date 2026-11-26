#!/usr/bin/env bash
# Exercise the client script and the server sync against a fake AWS CLI.
# No network and no real credentials.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cat >"$tmp/aws" <<'PY'
#!/usr/bin/env python3
import json
import os
import sys

db_path = os.environ["FAKE_SSM_DB"]
eip = os.environ.get("FAKE_EIP", "203.0.113.10")
account = os.environ.get("FAKE_ACCOUNT", "457504029722")

def load():
    if not os.path.exists(db_path):
        return {}
    with open(db_path, encoding="utf-8") as handle:
        return json.load(handle)

def save(db):
    with open(db_path, "w", encoding="utf-8") as handle:
        json.dump(db, handle)

def flag(args, name):
    if name not in args:
        return None
    return args[args.index(name) + 1]

def has(args, name):
    return name in args

args = sys.argv[1:]
if not args:
    sys.stderr.write("fake aws: missing args\n")
    sys.exit(2)

if args[0] == "sts" and args[1] == "get-caller-identity":
    sys.stdout.write(account + "\n")
    sys.exit(0)

if args[0] == "ec2" and args[1] == "describe-addresses":
    sys.stdout.write(eip + "\n")
    sys.exit(0)

if args[0] != "ssm":
    sys.stderr.write("fake aws: unknown command %s\n" % " ".join(args))
    sys.exit(2)

action = args[1]
if action == "put-parameter":
    name = flag(args, "--name")
    typ = flag(args, "--type")
    value = flag(args, "--value")
    if value.startswith("file://"):
        with open(value[len("file://"):], encoding="utf-8") as handle:
            value = handle.read()
    db = load()
    if has(args, "--no-overwrite") and name in db:
        sys.stderr.write("An error occurred (ParameterAlreadyExists) when calling the PutParameter operation\n")
        sys.exit(254)
    db[name] = {"Type": typ, "Value": value}
    save(db)
    sys.exit(0)

if action == "delete-parameter":
    name = flag(args, "--name")
    db = load()
    db.pop(name, None)
    save(db)
    sys.exit(0)

if action == "get-parameter":
    name = flag(args, "--name")
    db = load()
    if name not in db:
        sys.stderr.write("An error occurred (ParameterNotFound) when calling the GetParameter operation\n")
        sys.exit(254)
    param = {"Name": name, "Type": db[name]["Type"], "Value": db[name]["Value"]}
    query = flag(args, "--query")
    if flag(args, "--output") == "json" or query is None:
        json.dump({"Parameter": param}, sys.stdout)
        sys.stdout.write("\n")
        sys.exit(0)
    if query == "Parameter.Name":
        sys.stdout.write(name + "\n")
        sys.exit(0)
    if query == "Parameter.Value":
        sys.stdout.write(param["Value"])
        if not param["Value"].endswith("\n"):
            sys.stdout.write("\n")
        sys.exit(0)
    sys.stderr.write("fake aws: unknown query %s\n" % query)
    sys.exit(2)

if action == "get-parameters-by-path":
    path = flag(args, "--path").rstrip("/") + "/"
    db = load()
    params = []
    for name in sorted(db):
        if name.startswith(path):
            params.append({"Name": name, "Type": db[name]["Type"], "Value": db[name]["Value"]})
    json.dump({"Parameters": params}, sys.stdout)
    sys.stdout.write("\n")
    sys.exit(0)

sys.stderr.write("fake aws: unknown ssm action %s\n" % action)
sys.exit(2)
PY
chmod 755 "$tmp/aws"

export PATH="$tmp:$PATH"
export FAKE_SSM_DB="$tmp/ssm.json"
export FAKE_EIP="203.0.113.10"
export FAKE_ACCOUNT="457504029722"
echo '{}' >"$FAKE_SSM_DB"

fail() {
  echo "test-pki: $*" >&2
  exit 1
}

expect_fail() {
  local needle="$1"
  shift
  if "$@" >"$tmp/out" 2>"$tmp/err"; then
    fail "expected failure: $*"
  fi
  if ! grep -q "$needle" "$tmp/err"; then
    cat "$tmp/err" >&2
    fail "stderr did not contain: $needle"
  fi
}

script="$root/scripts/openvpn-client.sh"
sync="$root/infra/vpn/files/sync.sh"

grep -q 'default     = "10.8.0.0/24"' "$root/infra/vpn/variables.tf" || fail "vpn_cidr default drifted"
grep -q 'VPN_PREFIX="10.8.0"' "$script" || fail "client script prefix drifted"
grep -q 'openvpn-tfstate-457504029722' "$root/infra/bootstrap/variables.tf" || fail "state bucket name drifted"
grep -q 'openvpn-tfstate-457504029722' "$root/infra/vpn/versions.tf" || fail "backend bucket name drifted"
grep -q 'use_lockfile = true' "$root/infra/vpn/versions.tf" || fail "lockfile not enabled"
grep -q 'vpc-02297ce9cfb0e105d' "$root/infra/vpn/variables.tf" || fail "default vpc id drifted"
grep -q 'app.sapienexmachina.si' "$root/infra/bootstrap/variables.tf" || fail "zone name drifted"
grep -q 'vpn.app.sapienexmachina.si' "$root/infra/vpn/variables.tf" || fail "record name drifted"
grep -q 'ChangeResourceRecordSetsNormalizedRecordNames' "$root/infra/bootstrap/iam_infra.tf" || fail "dns condition missing"
if grep -R --exclude-dir=.terraform 'resource "aws_route53_zone"' "$root/infra"; then
  fail "this repo must not create a hosted zone"
fi
grep -q '10.20.0.0/16' "$root/infra/vpn/variables.tf" || fail "gonetlogo cidr drifted"
if grep -R --exclude-dir=.terraform '^resource "aws_vpc"' "$root/infra/vpn"; then
  fail "vpn stack must not create a VPC"
fi
if grep -R --exclude-dir=.terraform 'aws_eip' "$root/infra"; then
  fail "Elastic IP should not be in this repo"
fi
grep -q 'MASQUERADE' "$root/infra/vpn/files/nat.sh" || fail "nat script missing masquerade"
if grep -q '0.0.0.0/0' "$root/infra/vpn/files/nat.sh"; then
  fail "nat script must not masquerade every destination"
fi

conf="$root/infra/vpn/templates/server.conf.tftpl"
if grep -E '^[[:space:]]*(duplicate-cn|auth-user-pass|redirect-gateway)([[:space:]]|$)' "$conf"; then
  fail "server config enables duplicate-cn, a password, or a full tunnel"
fi
grep -q '^remote-cert-tls client$' "$conf" || fail "server missing remote-cert-tls client"
grep -q '^verify-client-cert require$' "$conf" || fail "server missing verify-client-cert"
grep -q '^crl-verify /etc/openvpn/server/crl.pem$' "$conf" || fail "server missing CRL"
grep -q '^tls-crypt /etc/openvpn/server/tls-crypt.key$' "$conf" || fail "server missing tls-crypt"
if grep -q '^client-to-client$' "$conf"; then
  fail "client-to-client bypasses the forward allowlist"
fi
grep -q '^tls-version-min 1.2$' "$conf" || fail "server missing TLS 1.2 floor"
grep -q '^data-ciphers AES-256-GCM:CHACHA20-POLY1305$' "$conf" || fail "server ciphers drifted"
grep -q '^auth SHA256$' "$conf" || fail "server auth drifted"
grep -q '^group openvpn$' "$conf" || fail "server must drop to group openvpn"
if grep -q '^group nobody$' "$conf"; then
  fail "group nobody cannot enter /etc/openvpn/server"
fi
grep -q 'getent passwd openvpn' "$root/infra/vpn/templates/user-data.sh.tftpl" || fail "user-data should prefer the openvpn user"
grep -q 'root:openvpn' "$sync" || fail "sync must restore root:openvpn ownership"

if grep -RIn --exclude-dir=.git --exclude-dir=.terraform --exclude=test-pki.sh -E 'WSL|wsl' "$root"; then
  fail "WSL should not be mentioned"
fi

expect_fail "refusing to run under xtrace" bash -x "$script" list

bash "$script" init >"$tmp/init.out"
grep -q 'server_cn: openvpn-server' "$tmp/init.out" || fail "init did not report the server CN"
bash "$script" list | grep -qx 'no clients' || fail "list after init"

bash "$script" add windows-pc --ip 10.8.0.10 >"$tmp/add-win.out"
grep -q 'vpn_ip: 10.8.0.10' "$tmp/add-win.out" || fail "windows ip"
win_serial="$(awk -F': ' '/^serial: /{print $2}' "$tmp/add-win.out")"
[ -n "$win_serial" ] || fail "missing windows serial"

bash "$script" add linux-box >"$tmp/add-lin.out"
grep -q 'vpn_ip: 10.8.0.11' "$tmp/add-lin.out" || fail "linux ip was not the next free address"
lin_serial="$(awk -F': ' '/^serial: /{print $2}' "$tmp/add-lin.out")"
[ "$win_serial" != "$lin_serial" ] || fail "clients share a serial"

expect_fail "already active" bash "$script" add windows-pc
expect_fail "reserved" bash "$script" add other --ip 10.8.0.10
expect_fail "name must match" bash "$script" add Windows-PC
expect_fail "static ip" bash "$script" add other --ip 10.8.0.1
expect_fail "static ip" bash "$script" add other --ip 10.8.0.200
expect_fail "Refusing to overwrite" bash "$script" init

list_out="$(bash "$script" list)"
printf '%s\n' "$list_out" | grep -qx 'linux-box 10.8.0.11 active'
printf '%s\n' "$list_out" | grep -qx 'windows-pc 10.8.0.10 active'

bash "$script" show windows-pc --output "$tmp/windows-pc.ovpn" >"$tmp/show-win.out"
bash "$script" show linux-box --output "$tmp/linux-box.ovpn" >/dev/null
[ "$(stat -c %a "$tmp/windows-pc.ovpn")" = "600" ] || fail "ovpn mode"
grep -q 'remote: vpn.app.sapienexmachina.si' "$tmp/show-win.out" || fail "show remote"

assert_profile() {
  local file="$1"
  local cn="$2"
  grep -q "^remote vpn.app.sapienexmachina.si 1194 udp$" "$file" || fail "$file remote"
  grep -q '^resolv-retry infinite$' "$file" || fail "$file resolv-retry"
  grep -q '^remote-cert-tls server$' "$file" || fail "$file remote-cert-tls"
  grep -q '^verify-x509-name openvpn-server name$' "$file" || fail "$file verify-x509-name"
  grep -q '^tls-version-min 1.2$' "$file" || fail "$file tls version"
  grep -q '^data-ciphers AES-256-GCM:CHACHA20-POLY1305$' "$file" || fail "$file ciphers"
  grep -q '^auth SHA256$' "$file" || fail "$file auth"
  grep -q '<tls-crypt>' "$file" || fail "$file tls-crypt"
  if grep -E '^(duplicate-cn|auth-user-pass|redirect-gateway)([[:space:]]|$)' "$file"; then
    fail "$file has a forbidden directive"
  fi
  awk 'BEGIN{p=0} /<cert>/{p=1;next} /<\/cert>/{p=0} p' "$file" >"$tmp/one.crt"
  got="$(openssl x509 -in "$tmp/one.crt" -noout -subject -nameopt RFC2253)"
  [ "$got" = "subject=CN=${cn}" ] || fail "$file cert CN is $got"
  openssl x509 -in "$tmp/one.crt" -noout -ext extendedKeyUsage | grep -q "TLS Web Client Authentication" || fail "$file EKU"
}

assert_profile "$tmp/windows-pc.ovpn" windows-pc
assert_profile "$tmp/linux-box.ovpn" linux-box

awk 'BEGIN{p=0} /<cert>/{p=1;next} /<\/cert>/{p=0} p' "$tmp/windows-pc.ovpn" >"$tmp/win.crt"
awk 'BEGIN{p=0} /<cert>/{p=1;next} /<\/cert>/{p=0} p' "$tmp/linux-box.ovpn" >"$tmp/lin.crt"
awk 'BEGIN{p=0} /<ca>/{p=1;next} /<\/ca>/{p=0} p' "$tmp/windows-pc.ovpn" >"$tmp/ca.crt"
openssl x509 -in "$tmp/win.crt" -noout -pubkey >"$tmp/win.pub"
openssl x509 -in "$tmp/lin.crt" -noout -pubkey >"$tmp/lin.pub"
if cmp -s "$tmp/win.pub" "$tmp/lin.pub"; then
  fail "clients share a public key"
fi
openssl verify -CAfile "$tmp/ca.crt" "$tmp/win.crt" >/dev/null
openssl verify -CAfile "$tmp/ca.crt" "$tmp/lin.crt" >/dev/null

# The CA private key must not be the key embedded in a profile.
python3 - "$FAKE_SSM_DB" "$tmp/windows-pc.ovpn" <<'PY'
import json, pathlib, sys
db = json.load(open(sys.argv[1], encoding="utf-8"))
ovpn = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")
ca_key = db["/openvpn/secrets/ca.key"]["Value"]
server_key = db["/openvpn/pki/server.key"]["Value"]
other = db["/openvpn/secrets/clients/linux-box/key"]["Value"]
if ca_key.strip() in ovpn or server_key.strip() in ovpn or other.strip() in ovpn:
    sys.stderr.write("profile contains a key it must not\n")
    sys.exit(1)
if db["/openvpn/secrets/clients/windows-pc/key"]["Value"].strip() not in ovpn:
    sys.stderr.write("profile is missing its own key\n")
    sys.exit(1)
PY

export OPENVPN_SYNC_REGION="us-west-2"
export OPENVPN_SYNC_DEST="$tmp/server"
export OPENVPN_SYNC_NO_SYSTEMCTL="1"
export OPENVPN_SYNC_SKIP_CHOWN="1"
export OPENVPN_SYNC_SKIP_FIREWALL="1"
bash "$sync"
grep -q '^ifconfig-push 10.8.0.10 255.255.255.0$' "$tmp/server/ccd/windows-pc" || fail "windows CCD"
grep -q '^ifconfig-push 10.8.0.11 255.255.255.0$' "$tmp/server/ccd/linux-box" || fail "linux CCD"
[ "$(stat -c %a "$tmp/server")" = "750" ] || fail "server dir mode"
[ "$(stat -c %a "$tmp/server/ccd")" = "750" ] || fail "ccd dir mode"
[ "$(stat -c %a "$tmp/server/ccd/windows-pc")" = "640" ] || fail "ccd file mode"
[ "$(stat -c %a "$tmp/server/server.key")" = "600" ] || fail "server key mode"
[ "$(stat -c %a "$tmp/server/tls-crypt.key")" = "600" ] || fail "tls-crypt mode"
[ "$(stat -c %a "$tmp/server/ca.crt")" = "640" ] || fail "ca cert mode"
[ "$(stat -c %a "$tmp/server/crl.pem")" = "640" ] || fail "crl mode"

bash "$script" revoke windows-pc >"$tmp/revoke.out"
grep -q 'status: revoked' "$tmp/revoke.out" || fail "revoke status"
expect_fail "revoked" bash "$script" show windows-pc --output "$tmp/ignored.ovpn"
list_out="$(bash "$script" list)"
printf '%s\n' "$list_out" | grep -qx 'windows-pc 10.8.0.10 revoked'
printf '%s\n' "$list_out" | grep -qx 'linux-box 10.8.0.11 active'

bash "$sync"
[ ! -e "$tmp/server/ccd/windows-pc" ] || fail "revoked client still has a CCD file"
grep -q '^ifconfig-push 10.8.0.11 255.255.255.0$' "$tmp/server/ccd/linux-box" || fail "linux CCD disappeared"
openssl crl -in "$tmp/server/crl.pem" -noout -text | grep -q "Serial Number: $win_serial" || fail "CRL missing revoked serial"
openssl verify -crl_check -CAfile "$tmp/ca.crt" -CRLfile "$tmp/server/crl.pem" "$tmp/win.crt" >"$tmp/verify.out" 2>&1 && fail "revoked cert still verifies"
grep -q revoked "$tmp/verify.out" || fail "verify did not say revoked"
openssl verify -crl_check -CAfile "$tmp/ca.crt" -CRLfile "$tmp/server/crl.pem" "$tmp/lin.crt" >/dev/null

bash "$script" add other >"$tmp/add-other.out"
grep -q 'vpn_ip: 10.8.0.12' "$tmp/add-other.out" || fail "revoked address was reused for a new name"

bash "$script" add windows-pc >"$tmp/readd.out"
grep -q 'vpn_ip: 10.8.0.10' "$tmp/readd.out" || fail "reissue did not keep the reserved address"
new_serial="$(awk -F': ' '/^serial: /{print $2}' "$tmp/readd.out")"
[ "$new_serial" != "$win_serial" ] || fail "reissue reused the revoked serial"
bash "$script" show windows-pc --output "$tmp/windows-pc-new.ovpn" >/dev/null
awk 'BEGIN{p=0} /<cert>/{p=1;next} /<\/cert>/{p=0} p' "$tmp/windows-pc-new.ovpn" >"$tmp/win-new.crt"
openssl verify -CAfile "$tmp/ca.crt" "$tmp/win-new.crt" >/dev/null
# The CRL in SSM was not regenerated on reissue. The old serial stays revoked.
openssl verify -crl_check -CAfile "$tmp/ca.crt" -CRLfile "$tmp/server/crl.pem" "$tmp/win.crt" >"$tmp/verify.out" 2>&1 && fail "old cert left the CRL"
openssl verify -crl_check -CAfile "$tmp/ca.crt" -CRLfile "$tmp/server/crl.pem" "$tmp/win-new.crt" >/dev/null

echo "test-pki: ok"
