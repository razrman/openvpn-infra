#!/usr/bin/env bash
# Normalize VPN_SSH_AUTHORIZED_KEYS onto stdout, one public key per line.
# Empty input is success and prints nothing. Private keys are rejected.
set -euo pipefail

exec python3 -c '
import sys

raw = sys.argv[1].replace("\r\n", "\n").replace("\r", "\n")
prefixes = (
    "ssh-ed25519 ",
    "ssh-rsa ",
    "ssh-dss ",
    "ecdsa-sha2-nistp256 ",
    "ecdsa-sha2-nistp384 ",
    "ecdsa-sha2-nistp521 ",
    "sk-ssh-ed25519@openssh.com ",
    "sk-ecdsa-sha2-nistp256@openssh.com ",
)
kept = []
for lineno, line in enumerate(raw.split("\n"), 1):
    text = line.strip()
    if text == "" or text.startswith("#"):
        continue
    if "PRIVATE KEY" in text or text.startswith("-----"):
        sys.stderr.write("VPN_SSH_AUTHORIZED_KEYS line %d looks like a private key. Paste the public key only.\n" % lineno)
        sys.exit(1)
    if not text.startswith(prefixes):
        sys.stderr.write("VPN_SSH_AUTHORIZED_KEYS line %d is not an OpenSSH public key.\n" % lineno)
        sys.exit(1)
    parts = text.split()
    if len(parts) < 2 or len(parts[1]) < 20:
        sys.stderr.write("VPN_SSH_AUTHORIZED_KEYS line %d is missing key material.\n" % lineno)
        sys.exit(1)
    kept.append(" ".join(parts))

if kept:
    sys.stdout.write("\n".join(kept) + "\n")
' "${VPN_SSH_AUTHORIZED_KEYS-}"
