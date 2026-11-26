locals {
  vpn_network = cidrhost(var.vpn_cidr, 0)
  vpn_netmask = cidrnetmask(var.vpn_cidr)
  server_ip   = cidrhost(var.vpn_cidr, 1)
  # .10-.199 are reserved for ifconfig-push. The dynamic pool is only a
  # fallback for a client that connects before its CCD file is synced.
  pool_start = cidrhost(var.vpn_cidr, 200)
  pool_end   = cidrhost(var.vpn_cidr, 249)

  gonetlogo_network = cidrhost(var.gonetlogo_cidr, 0)
  gonetlogo_netmask = cidrnetmask(var.gonetlogo_cidr)

  # peer_gonetlogo is the switch. A missing VPC is the other off position.
  # More than one match is rejected by the security group precondition
  # rather than peering an arbitrary id.
  peer_active = var.peer_gonetlogo && length(data.aws_vpcs.gonetlogo.ids) == 1

  # The cloud-init script is larger than EC2's 16KB user-data limit, so
  # the instance receives a gzip wrapper and unpacks it at boot.
  user_data_script = templatefile("${path.module}/templates/user-data.sh.tftpl", {
    sync_script   = file("${path.module}/files/sync.sh")
    nat_script    = file("${path.module}/files/nat.sh")
    access_script = file("${path.module}/files/access.sh")
    render_script = file("${path.module}/../../scripts/render-access.py")
    access_yaml   = file("${path.module}/access.yaml")
    server_conf = templatefile("${path.module}/templates/server.conf.tftpl", {
      vpn_network       = local.vpn_network
      vpn_netmask       = local.vpn_netmask
      server_ip         = local.server_ip
      pool_start        = local.pool_start
      pool_end          = local.pool_end
      peer_gonetlogo    = var.peer_gonetlogo
      gonetlogo_network = local.gonetlogo_network
      gonetlogo_netmask = local.gonetlogo_netmask
    })
    sync_service   = file("${path.module}/files/openvpn-sync.service")
    sync_timer     = file("${path.module}/files/openvpn-sync.timer")
    cwagent_json   = file("${path.module}/files/amazon-cloudwatch-agent.json")
    peer_gonetlogo = var.peer_gonetlogo
    vpn_cidr       = var.vpn_cidr
    gonetlogo_cidr = var.gonetlogo_cidr
  })

  user_data = join("", [
    "#!/bin/bash\n",
    "set -euo pipefail\n",
    "base64 -d <<'OPENVPN_USER_DATA_GZ' | gunzip | bash\n",
    base64gzip(local.user_data_script),
    "\nOPENVPN_USER_DATA_GZ\n",
  ])
}
