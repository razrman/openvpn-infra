# openvpn-infra

Private OpenVPN server for John's AWS account. A Windows 11 PC at home runs [Jan.ai](https://jan.ai) with the Local API Server on (OpenAI-compatible, port 1337). A remote Linux machine, not on that LAN, needs to call it. Both machines connect to this server as clients and can reach each other on the tunnel, so the Linux machine calls `http://<PC VPN IP>:1337`.

The tunnel is split. Clients route only the VPN subnet here. Home and office internet traffic does not go through AWS.

Account `457504029722`, region `us-west-2`. OpenTofu `1.13.9` (the pin is `infra/.opentofu-version`). The provider refuses any other account.

This repository is public. Client profiles and `infra/bootstrap/terraform.tfstate` are secret. Both are gitignored. Do not paste a profile into an Actions log, a pull request, or a chat.

## Certificates and trust

Each client has its own private key and its own certificate, signed by one CA. There is no shared client certificate and no username or password.

- The server sets `remote-cert-tls client` and `verify-client-cert require`, so a client certificate must carry the clientAuth extended key usage.
- `duplicate-cn` is not set. A second connection that presents the same certificate is rejected.
- Clients set `remote-cert-tls server` and `verify-x509-name openvpn-server name`, so they accept only a server certificate with the serverAuth extended key usage and common name `openvpn-server`.
- Control-channel packets are wrapped with `tls-crypt`. Data ciphers are `AES-256-GCM` and `CHACHA20-POLY1305`. The TLS floor is 1.2 (1.3 is allowed when both sides negotiate it). The HMAC is SHA256. There is no `comp-lzo` and no `auth-user-pass`.
- A CRL is published in SSM and installed on the server. Revoking one client puts only that certificate on the CRL. The other clients keep working. The revoked name keeps its static address reserved.
- `tls-crypt-v2` per client is not used. The certificate already identifies the client, and the CRL already revokes it. A second per-client key would be another secret in every profile and would not replace the CRL. The shared `tls-crypt` key only hides the handshake. A leaked profile is stopped by revoking that client's certificate.

The CA lasts 10 years. Server and client certificates last 5 years. There is no rotation workflow. `init` refuses to run again once a CA exists, so a later apply cannot replace the keys under existing profiles.

## Layout

| Stack | State | Survives teardown |
| --- | --- | --- |
| `infra/bootstrap` | Local file on the machine that applied it | Yes. State bucket, deploy role, Elastic IP, monthly budget |
| `infra/vpn` | S3 bucket from bootstrap, locked with an S3 lockfile (`use_lockfile`, no DynamoDB) | No. VPC, subnet, security group, instance, Elastic IP association, log group |

The PKI is not in either state. `scripts/openvpn-client.sh` stores it in SSM Parameter Store as Standard SecureString parameters (the free tier). Secrets Manager would be about $0.40 per secret per month, and a client needs several secrets. Standard parameters are limited to 4096 bytes, which covers these EC certificates, the tls-crypt key, and a CRL for a small number of clients.

| Parameter | Who can read it |
| --- | --- |
| `/openvpn/pki/*` (CA certificate, server certificate and key, tls-crypt key, CRL) | Deploy role and the instance |
| `/openvpn/clients/<name>/ip` and `status` | Deploy role and the instance |
| `/openvpn/secrets/*` (CA key, CA database, client certificate, client key) | Deploy role only |

The instance never receives a client private key or the CA key. It writes a `client-config-dir` file per active client (`ifconfig-push`) and re-reads SSM about once a minute. A new client is usable on the next sync without replacing the instance. A changed CRL restarts OpenVPN so a client that is already connected is dropped and cannot reconnect.

Client-to-client traffic is routed inside OpenVPN (`client-to-client`). The instance does not turn on IP forwarding and does not NAT. There is no NAT gateway.

## Address plan

| Address | Use |
| --- | --- |
| `10.8.0.0/24` | Tunnel. Pushed to clients. Not a default route |
| `10.8.0.1` | The server |
| `10.8.0.10`–`10.8.0.199` | Static clients (`ifconfig-push`). Suggested: `windows-pc` = `.10`, `linux-box` = `.11` |
| `10.8.0.200`–`10.8.0.249` | Dynamic fallback only, if a certificate connects before its CCD file exists |
| `10.64.0.0/16` | The VPC. One public subnet, an internet gateway, no NAT |

The home LAN must not be `10.8.0.0/24`. If it is, change `vpn_cidr` in `infra/vpn/variables.tf` and `VPN_PREFIX` in `scripts/openvpn-client.sh` together, and do that before you add a client. The script is the piece that picks static addresses.

`allowed_cidrs` in `infra/vpn/variables.tf` controls who can send UDP 1194. The default is `0.0.0.0/0`. TLS plus tls-crypt is the real gate. Set a `/32` and run Infra up to narrow it. The VPC is IPv4 only.

## Cost

List-price sketch for `us-west-2`, 730 hours in a month. Not a bill.

**Torn down** (bootstrap only, PKI sitting in SSM): about **$3.70 a month**.

| Piece | About |
| --- | --- |
| Elastic IP, attached or not. Every public IPv4 is $0.005 per hour | $3.65 |
| S3 state, SSM standard parameters, IAM, the budget if it is one of the account's first two | cents |

The Elastic IP is the stable `remote` in every `.ovpn`. Replacing it would mean rewriting every profile. A DNS name would be about $0.50 a month and would need a domain you own. The IP does not. It is the whole idle bill, and it is intentional.

**Running** (`t4g.nano`, the default): about **$8 a month**.

| Piece | About |
| --- | --- |
| `t4g.nano` | $3.07 |
| The same public IPv4 | $3.65 |
| 8 GB gp3 root volume | $0.64 |
| CloudWatch logs at this size, data transfer for API calls | well under $1 |

`t4g.micro` adds about $3 and can cross the $10 budget while the server is up. Data transfer out to the internet is extra if the API responses are large. The free-tier allowance, if the account still has it, covers the small calls. Split tunnel keeps ordinary browsing off this path.

The first two AWS Budgets in an account are free. GoNetLogo already has one (`gonetlogo-monthly`). This stack adds `openvpn-monthly` at $10 of usage, credits ignored, so the mail still arrives while credits pay the bill. A third budget in the account is about $0.10 a day. AWS sends a confirmation link to `budget_email` before any alert. Open that link.

## One-time bootstrap

From a shell whose AWS credentials are an administrator in account `457504029722`:

```bash
cd infra/bootstrap
tofu init
tofu apply
```

Keep `terraform.tfstate` from that directory somewhere private. It is gitignored. It is the record of the bucket, the role, the Elastic IP, and the budget. Do not delete it.

```bash
tofu output -raw deploy_role_arn
tofu output -raw eip_public_ip
```

Bootstrap does not create a GitHub OIDC provider. The account already has `arn:aws:iam::457504029722:oidc-provider/token.actions.githubusercontent.com` from GoNetLogo. This stack reads it with a data source. It does not modify `gonetlogo-*` or `sapienexmachina-*` resources.

Accept the budget confirmation mail (`jphelps@iaip.com` unless you changed `budget_email` in `infra/bootstrap/variables.tf` before the apply).

### GitHub

Repository **variable** (Settings → Secrets and variables → Actions → Variables), not a secret:

| Name | Value |
| --- | --- |
| `AWS_DEPLOY_ROLE_ARN` | `deploy_role_arn` from the bootstrap output |

Environment name: `production`. The role trusts only these subjects:

- `repo:razrman/openvpn-infra:environment:production`
- `repo:razrman@1226040/openvpn-infra@1473411194:environment:production`

This repository was created on 2026-11-26. Repositories created after 2026-07-15 put the owner id and the repository id in the OIDC subject, which is what GoNetLogo already ran into. The legacy string is what a workflow would have sent before that change, and it does not match tokens this repository issues. Both strings are this repository and this environment only. `github_subjects` in `infra/bootstrap/variables.tf` is the list to edit if a failed assume-role shows a different subject. Re-apply bootstrap after changing it.

On the environment:

- Add a required reviewer.
- Allow deployment from the branches you open pull requests from and from `main`. "All branches" plus the required reviewer lets pull-request plans, Infra up, Infra down, and VPN client all assume the role. The reviewer is the gate. A run that fails immediately with an environment protection error is missing the branch on that list, or nobody approved it.

No other repository variables or secrets are required. Workflows assume the role with GitHub's OIDC token. There is no long-lived AWS key in the repository.

## PKI, then the first client profiles

Still on the administrator shell (Linux or macOS, with `bash`, `openssl`, `python3`, and AWS CLI v2). This is not run on the Windows PC. The script refuses `bash -x`.

```bash
./scripts/openvpn-client.sh init
./scripts/openvpn-client.sh add windows-pc --ip 10.8.0.10
./scripts/openvpn-client.sh add linux-box --ip 10.8.0.11
./scripts/openvpn-client.sh show windows-pc
./scripts/openvpn-client.sh show linux-box
./scripts/openvpn-client.sh list
```

`show` writes `clients/<name>.ovpn` mode `600` and prints the path, the VPN address, and the Elastic IP. It does not print the file. Copy `clients/windows-pc.ovpn` onto the Windows PC and `clients/linux-box.ovpn` onto the Linux machine (a USB drive, or a machine you already control). Do not commit them.

`init` runs only from that shell, so the CA key is generated there and uploaded. `add` and `revoke` can also be run from Actions → **VPN client**, which uses the deploy role and does not print or upload a profile. Download is always `show` on the admin shell.

Names match `^[a-z][a-z0-9-]{0,31}$`. Examples for later: `mac-mini`, `linux-desk`. Each name gets a new key and a new certificate. Revoke puts that certificate on the CRL, deletes the private key, and keeps the static address reserved for the name. `add` of a revoked name issues a new certificate and reuses the address unless you pass `--ip`.

A run holds `/openvpn/secrets/lock` and releases it on exit. A lock older than 15 minutes is treated as abandoned.

## Bring the server up

After the CA exists (clients can be added before or after the instance):

Actions → **Infra up** → Run workflow.

Or, with the deploy role or an administrator:

```bash
cd infra/vpn
tofu init
tofu apply
```

That creates the VPC, the security group, a `t4g.nano` Amazon Linux 2023 instance, the Elastic IP association, and the log group `/openvpn/server`. User-data installs OpenVPN, pulls the PKI from SSM, and starts it. UDP 1194 is open to `allowed_cidrs`. Port 22 is not open.

The instance gets a temporary public address so user-data can reach the package mirrors, then the Elastic IP replaces it. Clients already have the Elastic IP in their profiles.

While the server is up, a later apply does not replace it just because Amazon published a new AMI. Changing user-data does replace it. The Elastic IP moves to the new instance. Adding a client does not.

If `t4g.nano` runs out of memory during `dnf`, set `instance_type` to `t4g.micro` and apply again. User-data also creates a 1 GB swap file.

### Session Manager

There is no SSH key and no security-group rule for port 22. From the admin shell, after Infra up:

```bash
cd infra/vpn
aws ssm start-session --target "$(tofu output -raw instance_id)"
```

On the instance, `sudo journalctl -u openvpn-server@server` and `sudo tail -n 200 /var/log/cloud-init-output.log`. If user-data failed because `init` had not been run, run `init`, then either replace the instance or start `/usr/local/sbin/openvpn-sync` and `openvpn-server@server` from that session.

## Windows 11

The PC is native Windows 11. Copy `windows-pc.ovpn` onto it and import that file. Do not reuse another machine's profile.

**OpenVPN Connect:** Import Profile → File, then connect. The profile asks Connect to check the server name and to route only what the server pushes.

**OpenVPN GUI** (community edition, from openvpn.net): put the file in `C:\Users\<you>\OpenVPN\config\` or `C:\Program Files\OpenVPN\config\`. The GUI may need to be run as administrator the first time so it can install the route to `10.8.0.0/24`.

The VPN address is the static one from `add` (`10.8.0.10` if you followed the example). Confirm in PowerShell:

```powershell
Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -like '10.8.0.*' } | Select-Object IPAddress, InterfaceAlias
```

Split tunnel check. The first hop should be the VPN adapter. The second should be the home adapter, not the VPN:

```powershell
Find-NetRoute -RemoteIPAddress 10.8.0.1 | Select-Object -First 1 IPAddress, InterfaceAlias
Find-NetRoute -RemoteIPAddress 1.1.1.1 | Select-Object -First 1 IPAddress, InterfaceAlias
```

### Jan, and the firewall

Jan's Local API Server has to accept connections on the VPN adapter. A bind address of `127.0.0.1` is invisible to the Linux client. Set the server to listen on `0.0.0.0` (every interface, including the home LAN) or on the VPN address only (`10.8.0.10`), port 1337.

The VPN adapter is often classified as a public network. Allow inbound TCP 1337 from the tunnel on every profile. In an elevated PowerShell:

```powershell
New-NetFirewallRule -DisplayName "Jan API from VPN" -Direction Inbound -Action Allow -Protocol TCP -LocalPort 1337 -RemoteAddress 10.8.0.0/24 -Profile Any
```

Check what is actually listening:

```powershell
Get-NetTCPConnection -LocalPort 1337 -State Listen | Select-Object LocalAddress, LocalPort
```

`LocalAddress` should be `0.0.0.0` or `10.8.0.10`. If the only row is `127.0.0.1`, the Linux client cannot connect. Outbound UDP 1194 from the PC is allowed by default. The rule above is the inbound one that matters.

## Linux client

On the remote Linux machine:

```bash
sudo apt-get install -y openvpn
sudo openvpn --config linux-box.ovpn
```

Leave that process running. In another shell, with both this machine and the Windows PC connected:

```bash
ip -4 addr show tun0
ping -c 3 10.8.0.10
curl -sS --max-time 10 http://10.8.0.10:1337/v1/models
```

Use the Windows PC's VPN address, not the Linux machine's own. A JSON model list means Jan answered. `Connection refused` means the PC was reached and nothing is listening on that address. A timeout means the firewall dropped it, the PC's tunnel is down, or Jan is still bound to localhost.

`ping` can fail when Windows firewall blocks ICMP even though TCP 1337 is allowed. Trust the curl result.

## Later clients

A Mac mini and other Linux machines join the same way. Each one gets its own name, certificate, and address:

```bash
./scripts/openvpn-client.sh add mac-mini --ip 10.8.0.12
./scripts/openvpn-client.sh show mac-mini
```

On the Mac, import the profile with OpenVPN Connect. On another Linux machine, use the same `openvpn --config` command as above. Do not copy `windows-pc.ovpn` or `linux-box.ovpn` onto them. The server rejects a second session that presents a certificate already in use, and you would have to revoke the original to cut off a copy.

## Tear the server down

Actions → **Infra down** → type `destroy` in the confirm box.

Or:

```bash
cd infra/vpn
tofu destroy
```

One destroy removes the VPC, subnet, route table, internet gateway, security group, instance, root volume, Elastic IP association, and the log group. The instance has no deletion protection. The subnet waits up to 20 minutes for the network interface to release.

Left in place: the state bucket and the vpn state file, the deploy role, the Elastic IP, the budget, and every SSM parameter under `/openvpn`. Client profiles do not change. The next Infra up builds a new instance, attaches the same Elastic IP, and pulls the same PKI.

## Full teardown

Destroy the vpn stack first. Bootstrap owns the Elastic IP; releasing it while the instance still holds it fails, and the vpn state lives in the bucket bootstrap owns.

```bash
cd infra/vpn
tofu destroy

aws ssm get-parameters-by-path --path /openvpn --recursive --region us-west-2 \
  --query 'Parameters[].Name' --output text \
  | tr '\t' '\n' \
  | while IFS= read -r name; do
      [ -n "$name" ] || continue
      aws ssm delete-parameter --region us-west-2 --name "$name"
    done

BUCKET=openvpn-tfstate-457504029722
aws s3api list-object-versions --bucket "$BUCKET" --output json \
  | jq -r '.Versions[]?, .DeleteMarkers[]? | [.Key, .VersionId] | @tsv' \
  | while IFS="$(printf '\t')" read -r key version; do
      aws s3api delete-object --bucket "$BUCKET" --key "$key" --version-id "$version"
    done

cd ../bootstrap
tofu destroy
```

The `get-parameters-by-path` query asks for names only. Delete the local `clients/*.ovpn` files as well. They will not work after the CA is gone, and they still contain private keys. This does not delete the GitHub OIDC provider. GoNetLogo still uses it.

## Pull requests

A pull request that touches `infra/`, `scripts/`, or these workflows runs `tofu fmt -check` and `tofu validate` on both stacks. `tofu plan` for the vpn stack runs only when the pull request is from this repository and `AWS_DEPLOY_ROLE_ARN` is set. Forks, and this repository before the variable exists, skip the plan instead of failing. The plan job uses the production environment, so a required reviewer approves it before AWS is called. If you mark checks as required, require fmt and validate. The plan job is skipped until the variable exists, and a skipped required check can block a merge.

Bootstrap is not planned in GitHub. An empty local state on the runner would ask to create the bucket again. The plan needs the Elastic IP from bootstrap; run bootstrap before expecting a green plan.

`scripts/test-pki.sh` runs the client script and the instance sync script against a fake AWS CLI. It checks that two clients get different keys, that the server config and the profile carry the TLS settings above, and that a revoke lands on the CRL.

## What the role can do

The deploy role's trust policy is `sts:AssumeRoleWithWebIdentity` for the two subjects above and audience `sts.amazonaws.com`. Its policies cover the state bucket, the `openvpn-instance` role and instance profile (not its own trust policy), passing that role only to `ec2.amazonaws.com`, VPC and instance APIs in us-west-2, associating the existing Elastic IP (not allocating or releasing one), the `/openvpn/server` log group, the public Amazon Linux AMI parameter, and SSM parameters under `/openvpn` (including `/openvpn/secrets`, because the client workflow writes keys). KMS is limited to calls that SSM makes in this account, for the default SSM key. A deny blocks IAM, S3, SSM, ECR, ECS, and log resources whose names start with `gonetlogo` or `sapienexmachina`, and blocks mutating EC2 calls against resources tagged with those projects.

The instance role is `AmazonSSMManagedInstanceCore` plus read of `/openvpn/pki/*` and `/openvpn/clients/*`, decrypt via SSM, and write to the one log group. It cannot read `/openvpn/secrets`.

## Troubleshooting

- **AssumeRole failed.** The workflow job must set `environment: production`. Compare the subject in the error to `github_subjects`. The id form is the one this repository issues.
- **Plan failed on the Elastic IP.** Bootstrap has not been applied, or the address is missing the tags `Name=openvpn` and `Project=openvpn`.
- **Infra up user-data failed.** Session Manager, then `/var/log/cloud-init-output.log`. The usual cause is `init` not run yet, so `/openvpn/pki/ca.crt` is missing. `dnf` dying on `t4g.nano` is the other one. Use `t4g.micro`.
- **Client cannot connect.** The profile's `remote` must be the Elastic IP from bootstrap, not an old launch address. The server must be up. A revoked certificate stays revoked.
- **Connected, but curl times out.** Windows firewall, or the PC's tunnel is down. `Connection refused` means the packet arrived and Jan is not listening on `0.0.0.0` or the VPN address.
- **Home internet died after connecting.** The profile or the server is pushing `redirect-gateway`. Neither file in this repo does. Disconnect and check the imported profile.
- **Revoke did not drop a live session.** The sync timer restarts OpenVPN within about a minute of the CRL change. `sudo systemctl restart openvpn-server@server` from Session Manager does it immediately.
- **PKI lock is held.** Another add, revoke, or init is running, or a runner was killed. Wait 15 minutes, or delete the SSM parameter `/openvpn/secrets/lock` if you are sure nothing else is writing the CA.
- **Budget mail never arrives.** Open the confirmation link AWS sent to `budget_email`.
