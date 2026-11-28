#!/usr/bin/env bash
# Deregister old openvpn-base images and delete their snapshots.
# Keeps the newest 3. Only images owned by this account, named
# openvpn-base-*, and tagged project=openvpn are eligible. Prints ids, not
# image descriptions.
set -euo pipefail

export AWS_PAGER=""
export AWS_REGION="${AWS_REGION:-us-west-2}"
export AWS_DEFAULT_REGION="$AWS_REGION"

keep=3

python3 - "$keep" <<'PY'
import json
import subprocess
import sys

keep = int(sys.argv[1])
region = "us-west-2"

def aws(*args):
    return subprocess.check_output(["aws", *args, "--region", region, "--output", "json"])

raw = aws(
    "ec2", "describe-images",
    "--owners", "self",
    "--filters",
    "Name=tag:project,Values=openvpn",
    "Name=name,Values=openvpn-base-*",
    "Name=state,Values=available",
)
images = json.loads(raw).get("Images", [])
for image in images:
    name = image.get("Name", "")
    if not name.startswith("openvpn-base-"):
        sys.stderr.write("refusing unexpected image name on %s\n" % image["ImageId"])
        sys.exit(1)
    tags = {tag["Key"]: tag["Value"] for tag in image.get("Tags", [])}
    if tags.get("project") != "openvpn":
        sys.stderr.write("refusing untagged image %s\n" % image["ImageId"])
        sys.exit(1)

images.sort(key=lambda image: image.get("CreationDate", ""), reverse=True)
kept = images[:keep]
drop = images[keep:]

kept_snaps = set()
for image in kept:
    for mapping in image.get("BlockDeviceMappings", []):
        snap = mapping.get("Ebs", {}).get("SnapshotId")
        if snap:
            kept_snaps.add(snap)

print("kept %d image(s)" % len(kept))
for image in drop:
    ami = image["ImageId"]
    snaps = []
    for mapping in image.get("BlockDeviceMappings", []):
        snap = mapping.get("Ebs", {}).get("SnapshotId")
        if snap and snap not in kept_snaps:
            snaps.append(snap)
    print("deregister %s" % ami)
    subprocess.check_call([
        "aws", "ec2", "deregister-image",
        "--image-id", ami,
        "--region", region,
    ])
    for snap in snaps:
        print("delete snapshot %s" % snap)
        subprocess.check_call([
            "aws", "ec2", "delete-snapshot",
            "--snapshot-id", snap,
            "--region", region,
        ])
PY
