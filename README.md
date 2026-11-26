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
| `infra/bootstrap` | Local file on the machine that applied it | Yes. State bucket, deploy role, monthly budget. It looks up GoNetLogo's existing DNS zone and does not create one |
| `infra/vpn` | S3 bucket from bootstrap, locked with an S3 lockfile (`use_lockfile`, no DynamoDB) | No. Security group, instance in the default VPC, A record, optional peering and its routes, log group |

The PKI is not in either state. `scripts/openvpn-client.sh` stores it in SSM Parameter Store as Standard SecureString parameters (the free tier). Secrets Manager would be about $0.40 per secret per month, and a client needs several secrets. Standard parameters are limited to 4096 bytes, which covers these EC certificates, the tls-crypt key, and a CRL for a small number of clients.

| Parameter | Who can read it |
| --- | --- |
| `/openvpn/pki/*` (CA certificate, server certificate and key, tls-crypt key, CRL) | Deploy role and the instance |
| `/openvpn/clients/<name>/ip` and `status` | Deploy role and the instance |
| `/openvpn/secrets/*` (CA key, CA database, client certificate, client key) | Deploy role only |

The instance never receives a client private key or the CA key. It writes a `client-config-dir` file per active client (`ifconfig-push`) and re-reads SSM about once a minute. A new client is usable on the next sync without replacing the instance. A changed CRL restarts OpenVPN so a client that is already connected is dropped and cannot reconnect.

Traffic between VPN clients, and from clients into the peered VPC, is forwarded by the kernel. `infra/vpn/access.yaml` is the allowlist. There is no `client-to-client` directive, so OpenVPN does not bypass that firewall. Allowed traffic into `10.20.0.0/16` is masqueraded to the instance's address in the default VPC. Nothing else is masqueraded, and there is no NAT gateway. The server does not push a default route.

## Address plan

| Address | Use |
| --- | --- |
| `10.8.0.0/24` | Tunnel. Pushed to clients. Not a default route |
| `10.8.0.1` | The server |
| `10.8.0.10`–`10.8.0.199` | Static clients (`ifconfig-push`). Suggested: `windows-pc` = `.10`, `linux-box` = `.11` |
| `10.8.0.200`–`10.8.0.249` | Dynamic fallback only, if a certificate connects before its CCD file exists |
| `172.31.0.0/16` | Account default VPC `vpc-02297ce9cfb0e105d`. The instance lives in the `us-west-2a` subnet. This stack does not create the VPC. Clients are not given a route to it |
| `10.20.0.0/16` | GoNetLogo VPC, when that stack is up. Pushed to clients. Does not overlap the default VPC or the tunnel |
| `vpn.app.sapienexmachina.si` | Server name in the existing zone `app.sapienexmachina.si`. The A record's TTL is 60 seconds |

The home LAN must not be `10.8.0.0/24`. If it is, change `vpn_cidr` in `infra/vpn/variables.tf` and `VPN_PREFIX` in `scripts/openvpn-client.sh` together, and do that before you add a client. The script is the piece that picks static addresses.

Who may send UDP 1194 is `allowed_cidrs`, and on Infra up that value comes from the `VPN_ALLOWED_CIDRS` repository variable. The details are under Allowlists. This stack does not add IPv6 rules.

Profiles say `remote vpn.app.sapienexmachina.si 1194 udp` and `resolv-retry infinite`. They do not contain the instance's public address, so a rebuild does not require a new `.ovpn`. GoDaddy is not edited. The zone already exists for GoNetLogo.

## Cost

List-price sketch for `us-west-2`, 730 hours in a month. Not a bill.

**Torn down** (bootstrap only, PKI sitting in SSM): about **$0** from this repo.

There is no Elastic IP and no hosted zone here. The public address exists only while the instance exists, and the name `vpn.app.sapienexmachina.si` is one A record in the zone GoNetLogo already pays for (`app.sapienexmachina.si`, about $0.50 a month on that other stack). S3 state and SSM standard parameters are cents or free. The budget, if it is one of the account's first two, is free.

**Running** (`t4g.nano`, the default): about **$8 a month**.

| Piece | About |
| --- | --- |
| `t4g.nano` | $3.07 |
| Public IPv4 on the instance, $0.005 per hour, only while it is running | $3.65 |
| 8 GB gp3 root volume | $0.64 |
| CloudWatch logs at this size, data transfer for API calls, the A record queries | well under $1 |

The address is the one the default subnet assigns at launch. An Elastic IP created and destroyed with the instance would cost the same while running and nothing while destroyed. The auto-assigned address is the same bill with one less resource, and Infra down releases it. Clients keep using the DNS name. After a rebuild, wait out the 60 second TTL.

The instance uses the existing default VPC, so there is no second VPC and no NAT gateway. Peering has no hourly charge. Traffic that stays in one availability zone is free. Traffic that crosses availability zones over the peering connection is about $0.01 per GB each way.

`t4g.micro` adds about $3 and can cross the $10 budget while the server is up. Data transfer out to the internet is extra if the API responses are large. The free-tier allowance, if the account still has it, covers the small calls. Split tunnel keeps ordinary browsing off this path.

The first two AWS Budgets in an account are free. GoNetLogo already has one (`gonetlogo-monthly`). This stack adds `openvpn-monthly` at $10 of usage, credits ignored, so the mail still arrives while credits pay the bill. A third budget in the account is about $0.10 a day. AWS sends a confirmation link to `budget_email` before any alert. Open that link.

## One-time bootstrap

From a shell whose AWS credentials are an administrator in account `457504029722`:

```bash
cd infra/bootstrap
tofu init
tofu apply
```

Keep `terraform.tfstate` from that directory somewhere private. It is gitignored. It is the record of the bucket, the role, and the budget. Do not delete it.

```bash
tofu output -raw deploy_role_arn
```

GoNetLogo's bootstrap must already have created the public zone `app.sapienexmachina.si`. This stack looks that zone up and does not create one. There is no GoDaddy change.

Bootstrap does not create a GitHub OIDC provider. The account already has `arn:aws:iam::457504029722:oidc-provider/token.actions.githubusercontent.com` from GoNetLogo. This stack reads it with a data source. It does not modify `gonetlogo-*` or `sapienexmachina-*` resources, and it does not modify the hosted zone. The deploy role may change only the A record `vpn.app.sapienexmachina.si`.

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

`show` writes `clients/<name>.ovpn` mode `600` and prints the path, the VPN address, and `vpn.app.sapienexmachina.si`. It does not print the file. The profile's `remote` line is `remote vpn.app.sapienexmachina.si 1194 udp`, with `resolv-retry infinite`. Copy `clients/windows-pc.ovpn` onto the Windows PC and `clients/linux-box.ovpn` onto the Linux machine (a USB drive, or a machine you already control). Do not commit them. You can generate the files before the server is up. They connect once Infra up has written the A record.

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

That creates the security group, a `t4g.nano` Amazon Linux 2023 instance in the default VPC's `us-west-2a` subnet, the A record `vpn.app.sapienexmachina.si`, and the log group `/openvpn/server`. User-data installs OpenVPN, pulls the PKI from SSM, and starts it. UDP 1194 is open to `allowed_cidrs`. Port 22 is not open. The instance's public address is the one the subnet assigns. The A record points the name at it. Destroy deletes the record and releases the address.

While the server is up, a later apply does not replace it just because Amazon published a new AMI. Changing user-data does replace it, and the same apply updates the A record. Clients keep the same profile. Resolvers may keep the old address for up to 60 seconds. Adding a client does not replace the instance.

If `t4g.nano` runs out of memory during `dnf`, set `instance_type` to `t4g.micro` and apply again. User-data also creates a 1 GB swap file.

### Session Manager

There is no SSH key and no security-group rule for port 22. From the admin shell, after Infra up:

```bash
cd infra/vpn
aws ssm start-session --target "$(tofu output -raw instance_id)"
```

On the instance, `sudo journalctl -u openvpn-server@server` and `sudo tail -n 200 /var/log/cloud-init-output.log`. If user-data failed because `init` had not been run, run `init`, then either replace the instance or start `/usr/local/sbin/openvpn-sync` and `openvpn-server@server` from that session.

## Allowlists

Two lists. They are not the same thing.

### Who can open UDP 1194

`allowed_cidrs` is the only internet allowlist. The security group uses it and nothing else does. TLS and tls-crypt still authenticate the session. This is an extra cut in front of that.

Infra up and Infra plan read the repository variable `VPN_ALLOWED_CIDRS` (Settings → Secrets and variables → Actions → Variables). It is not a secret. Leave it unset and the workflows use `0.0.0.0/0`. Set it to a comma-separated list or a JSON list:

```text
203.0.113.10/32, 198.51.100.0/24
```

```text
["203.0.113.10/32", "198.51.100.0/24"]
```

A bad entry fails the workflow before OpenTofu runs, with the CIDR and the reason. A bare address such as `203.0.113.10` is taken as a `/32`. Host bits are rejected (`203.0.113.10/24` is not the network address; use `203.0.113.0/24`). IPv6 is rejected. An empty list is rejected. A local `tofu apply` that does not set `TF_VAR_allowed_cidrs` uses the default `0.0.0.0/0` and will reopen the port. Use the workflow, or export the same JSON list.

Find the address you are connecting from:

```bash
curl -4 -fsS https://checkip.amazonaws.com
```

On Windows:

```powershell
(Invoke-RestMethod https://checkip.amazonaws.com).Trim()
```

That address is a `/32` only until the ISP or the cloud egress changes it. A residential address often changes. A phone on another network, or a laptop on hotel wifi, is locked out until its prefix is on the list. The remote Linux box leaves through whatever address its cloud provider uses that day, which may be a shared pool rather than one stable host, so put every prefix it might use. Several CIDRs are the normal case. Changing the variable and running Infra up updates the security group in place. It does not replace the instance.

### Who can talk inside the tunnel

`infra/vpn/access.yaml` names the new connections that may be forwarded. Return traffic and an ICMP echo in that same direction are added for each rule. Everything else is dropped, including the dynamic pool `10.8.0.200`–`10.8.0.249`. There is no rule from `windows-pc` or `mac-mini` to `linux-box`, so that direction does not exist. `any-client` means every active static client. `gonetlogo` means `10.20.0.0/16`.

Names are resolved from the SSM address book when `openvpn-sync` runs. A rule that names a client who has not been added yet is skipped until that client exists, then the next sync installs it. Sync rebuilds the chain in one step and accepts flows that are already established, so an update does not cut an open session. A session that the new list would refuse dies when it ends, and the next attempt is dropped. Drops are logged at about six a minute with the prefix `openvpn-drop:` and shipped to the `/openvpn/server` log group.

To let `linux-box` reach a new client on port 1337, add the client, give it a static address, and add a rule:

```yaml
  - from: linux-box
    to: mac-mini
    proto: tcp
    port: 1337
```

Editing `access.yaml` changes user-data. The next Infra up replaces the instance. Reconnect afterwards. Adding only a client, without a new rule, does not replace the instance. The next sync picks up the new address for rules that already name it.

## Reaching GoNetLogo

`peer_gonetlogo` defaults to true. Infra up looks for a VPC tagged `Name=gonetlogo`. That tag is set in GoNetLogo's `infra/app/network.tf`. The VPC id changes every time that stack is created.

- If the VPC is up, this stack creates the peering, adds `10.20.0.0/16` to the default VPC's main route table, and adds `172.31.0.0/16` to every route table in the GoNetLogo VPC. Destroy removes those routes and nothing else in either table.
- If the VPC is not up, apply still succeeds and creates no peering. `tofu output gonetlogo_vpc_id` is null. Clients are still pushed `10.20.0.0/16` (the server config does not change when the VPC appears), and that traffic is dropped until the peering exists. It is not a default route, so home internet is unaffected.
- Bring GoNetLogo up later, then run Infra up again. The plan adds the peering and the routes. The instance is not replaced, because user-data did not change. Reconnect the clients if they connected before the route was pushed.
- Tear GoNetLogo down after this stack has deleted its return routes, or run Infra up here first with the GoNetLogo VPC still present. If that VPC is already gone, deleting a return route can fail with `InvalidRouteTableID.NotFound`. Remove the stale routes from state and apply again:

```bash
cd infra/vpn
tofu state rm 'aws_route.gonetlogo_return'
tofu apply
```

The instance masquerades client traffic into the peered VPC, so GoNetLogo sees the default VPC CIDR `172.31.0.0/16`, not `10.8.0.0/24`. GoNetLogo cannot open a connection to a VPN client address. Source/destination check on the instance stays enabled.

GoNetLogo's task security group `gonetlogo-task` allows TCP 8080 only from `gonetlogo-alb`. This repo does not change that group. Until GoNetLogo allows TCP 8080 from `172.31.0.0/16`, a client can route to a task and still get no answer. Do not open 8080 to `0.0.0.0/0`, and do not use `10.8.0.0/24` as the source, because the packets are masqueraded. Any other private service in that VPC needs the same kind of rule for the port you want. The public load balancer is a separate path and does not need the peering.

After that rule exists, from the Linux client, with both tunnels up and a task running:

```bash
curl -sS --max-time 10 http://<task-private-ip>:8080/healthz
```

The task address is in `10.20.0.0/24` or `10.20.1.0/24` and changes when the task is replaced. The ECS console, or `aws ecs describe-tasks` on cluster `gonetlogo`, shows the current one.

## Windows 11

The PC is native Windows 11. Copy `windows-pc.ovpn` onto it and import that file. Do not reuse another machine's profile.

**OpenVPN Connect:** Import Profile → File, then connect. The profile asks Connect to check the server name and to route only what the server pushes.

**OpenVPN GUI** (community edition, from openvpn.net): put the file in `C:\Users\<you>\OpenVPN\config\` or `C:\Program Files\OpenVPN\config\`. The GUI may need to be run as administrator the first time so it can install the pushed routes (`10.8.0.0/24` and, when peering is on, `10.20.0.0/16`).

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

One destroy removes the security group, the instance, its public address, the root volume, the A record, the peering connection and the routes this stack added for it, and the log group. It does not delete the default VPC, any other route in that VPC, or the hosted zone. The instance has no deletion protection. The security group waits up to 20 minutes for the network interface to release.

Left in place: the state bucket and the vpn state file, the deploy role, the budget, every SSM parameter under `/openvpn`, and GoNetLogo's zone. Client profiles do not change. The next Infra up builds a new instance, writes a new A record at the new address, and pulls the same PKI.

## Full teardown

Destroy the vpn stack first so the A record is removed while the role can still change it. The vpn state lives in the bucket bootstrap owns. Bootstrap does not delete `app.sapienexmachina.si`.

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

Bootstrap is not planned in GitHub. An empty local state on the runner would ask to create the bucket again. The plan looks up the default VPC and the existing hosted zone, so both have to be there before a green plan. The GoNetLogo VPC does not. A missing `Name=gonetlogo` VPC skips peering instead of failing the plan.

`scripts/test-pki.sh` runs the client script and the instance sync script against a fake AWS CLI. It checks that two clients get different keys, that the server config and the profile carry the TLS settings above, and that a revoke lands on the CRL.

## What the role can do

The deploy role's trust policy is `sts:AssumeRoleWithWebIdentity` for the two subjects above and audience `sts.amazonaws.com`. Its policies cover the state bucket, the `openvpn-instance` role and instance profile (not its own trust policy), passing that role only to `ec2.amazonaws.com`, the security group and instance in us-west-2, creating and deleting the peering to a VPC tagged `Name=gonetlogo`, and adding or removing the routes for that peering. It cannot create or delete a VPC, a subnet, an internet gateway, a route table, or an Elastic IP. In Route 53 it can call `ChangeResourceRecordSets` only on the existing `app.sapienexmachina.si` zone, and only when every name in the change is `vpn.app.sapienexmachina.si` and every type is `A`. It can read that zone's records so OpenTofu can refresh the one record. It cannot delete the zone or change `gonetlogo.app.sapienexmachina.si`. It can also read the public Amazon Linux AMI parameter and read and write SSM parameters under `/openvpn` (including `/openvpn/secrets`, because the client workflow writes keys). KMS is limited to calls that SSM makes in this account, for the default SSM key. A deny blocks IAM, S3, SSM, ECR, ECS, and log resources whose names start with `gonetlogo` or `sapienexmachina`, and blocks security-group edits and instance termination against resources tagged with those projects.

The instance role is `AmazonSSMManagedInstanceCore` plus read of `/openvpn/pki/*` and `/openvpn/clients/*`, decrypt via SSM, and write to the one log group. It cannot read `/openvpn/secrets`.

## Troubleshooting

- **AssumeRole failed.** The workflow job must set `environment: production`. Compare the subject in the error to `github_subjects`. The id form is the one this repository issues.
- **Plan failed on the hosted zone.** GoNetLogo's bootstrap has not created `app.sapienexmachina.si`, or this bootstrap has not been applied so the role can read it.
- **Plan failed on the default VPC.** `vpc-02297ce9cfb0e105d` is missing, or its CIDR is not `172.31.0.0/16`, or `us-west-2a` has no subnet.
- **Infra up user-data failed.** Session Manager, then `/var/log/cloud-init-output.log`. The usual cause is `init` not run yet, so `/openvpn/pki/ca.crt` is missing. `dnf` dying on `t4g.nano` is the other one. Use `t4g.micro`.
- **Client cannot connect.** The server must be up, and the resolver must have the current A record. After a rebuild that can take the 60 second TTL. A revoked certificate stays revoked.
- **Client got 10.8.0.200 or higher instead of its static address.** OpenVPN dropped privileges and then could not enter `/etc/openvpn/server` (`0750 root:openvpn`), so it never read `ccd/`. The server runs as group `openvpn`, and as user `openvpn` when that account exists. Sync puts the directory and the CCD files back to `0750`/`0640 root:openvpn` on every run, and leaves `server.key` and the tls-crypt key at `0600 root`. The CRL is `0640 root:openvpn` because it is read again on each connection. A running instance still has the old `user`/`group` lines until the next Infra up, which replaces it because user-data changed. Reconnect after that. The `chmod o+x /etc/openvpn/server` hotfix is not needed on the new instance.
- **Tunnel works, `10.20.0.0/16` does not.** Run Infra up again after the GoNetLogo VPC exists. `tofu output gonetlogo_vpc_id` is null when peering was skipped. If the route is there and curl still times out, the task security group does not allow this VPC yet. That follow-up is below.
- **Connected, but curl times out.** Windows firewall, or the PC's tunnel is down. `Connection refused` means the packet arrived and Jan is not listening on `0.0.0.0` or the VPN address.
- **Home internet died after connecting.** The profile or the server is pushing `redirect-gateway`. Neither file in this repo does. Disconnect and check the imported profile.
- **Revoke did not drop a live session.** The sync timer restarts OpenVPN within about a minute of the CRL change. `sudo systemctl restart openvpn-server@server` from Session Manager does it immediately.
- **PKI lock is held.** Another add, revoke, or init is running, or a runner was killed. Wait 15 minutes, or delete the SSM parameter `/openvpn/secrets/lock` if you are sure nothing else is writing the CA.
- **Budget mail never arrives.** Open the confirmation link AWS sent to `budget_email`.
