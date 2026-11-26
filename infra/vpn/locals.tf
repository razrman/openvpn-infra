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
}
