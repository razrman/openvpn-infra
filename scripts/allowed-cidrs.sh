#!/usr/bin/env bash
# Print a one-line JSON list for TF_VAR_allowed_cidrs.
# VPN_ALLOWED_CIDRS may be unset, comma-separated, or a JSON list.
# Unset or blank means 0.0.0.0/0. Invalid input exits 1.
set -euo pipefail

exec python3 -c '
import ipaddress
import json
import sys

raw = sys.argv[1].strip()
if raw == "":
    items = ["0.0.0.0/0"]
elif raw.startswith("["):
    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError as exc:
        sys.stderr.write("VPN_ALLOWED_CIDRS is not valid JSON: %s\n" % exc)
        sys.exit(1)
    if not isinstance(parsed, list):
        sys.stderr.write("VPN_ALLOWED_CIDRS JSON must be a list of CIDR strings.\n")
        sys.exit(1)
    items = parsed
else:
    items = [part.strip() for part in raw.split(",") if part.strip()]

if not items:
    sys.stderr.write("VPN_ALLOWED_CIDRS must contain at least one IPv4 CIDR.\n")
    sys.exit(1)

out = []
for item in items:
    if not isinstance(item, str):
        sys.stderr.write("VPN_ALLOWED_CIDRS entries must be strings, got %r.\n" % (item,))
        sys.exit(1)
    text = item.strip()
    if ":" in text:
        sys.stderr.write("VPN_ALLOWED_CIDRS rejects IPv6 (%s). The security group is IPv4 only.\n" % text)
        sys.exit(1)
    if "/" not in text:
        try:
            text = str(ipaddress.IPv4Address(text)) + "/32"
        except ValueError as exc:
            sys.stderr.write("VPN_ALLOWED_CIDRS has an invalid CIDR %r: %s\n" % (item.strip(), exc))
            sys.exit(1)
    try:
        network = ipaddress.ip_network(text, strict=True)
    except ValueError as exc:
        sys.stderr.write("VPN_ALLOWED_CIDRS has an invalid CIDR %r: %s\n" % (text, exc))
        sys.exit(1)
    if not isinstance(network, ipaddress.IPv4Network):
        sys.stderr.write("VPN_ALLOWED_CIDRS rejects non-IPv4 CIDR %s.\n" % text)
        sys.exit(1)
    out.append(str(network))

sys.stdout.write(json.dumps(out))
sys.stdout.write("\n")
' "${VPN_ALLOWED_CIDRS:-}"
