# Infra

OpenTofu for a small private OpenVPN server. The runbook, including bootstrap commands, GitHub settings, client profiles, and the Windows and Linux setup, is the repository [README](../README.md).

| Stack | State | Survives teardown |
| --- | --- | --- |
| `infra/bootstrap` | Local file on the machine that applied it | Yes. State bucket, deploy role, budget. The DNS zone is GoNetLogo's |
| `infra/vpn` | S3 bucket from bootstrap, locked with an S3 lockfile (`use_lockfile`, no DynamoDB) | No. Security group, instance in the default VPC, A record `vpn.app.sapienexmachina.si`, optional peering, log group |

The CA, server certificate, tls-crypt key, CRL, and per-client keys are in SSM Parameter Store. They are not in either state file. `scripts/openvpn-client.sh` writes them. Destroying `infra/vpn` leaves them. Profiles use `vpn.app.sapienexmachina.si`, so they keep working when the instance address changes.
