locals {
  # EC2 network. It does not overlap the tunnel (10.8.0.0/24 by default)
  # and it is outside a typical 192.168 home LAN. There is no NAT gateway.
  vpc_cidr = "10.64.0.0/16"

  vpn_network = cidrhost(var.vpn_cidr, 0)
  vpn_netmask = cidrnetmask(var.vpn_cidr)
  server_ip   = cidrhost(var.vpn_cidr, 1)
  # .10-.199 are reserved for ifconfig-push. The dynamic pool is only a
  # fallback for a client that connects before its CCD file is synced.
  pool_start = cidrhost(var.vpn_cidr, 200)
  pool_end   = cidrhost(var.vpn_cidr, 249)
}
