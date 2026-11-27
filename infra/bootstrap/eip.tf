# Stable public IPv4. This stack allocates it and does not attach it.
# infra/vpn associates it, and Infra down only disassociates it, so the
# address survives instance replacement and a normal teardown. Releasing
# it is a deliberate destroy of this resource from an administrator
# shell, after the vpn stack is down. While it exists it costs about
# $0.005 per hour, including while nothing is attached.
resource "aws_eip" "vpn" {
  domain = "vpc"

  tags = {
    Name    = "openvpn"
    project = "openvpn"
  }
}

# Pointer the vpn stack reads. The allocation id is not a secret.
# Destroying the address removes this parameter with it.
resource "aws_ssm_parameter" "eip_allocation_id" {
  name        = "/openvpn/network/eip-allocation-id"
  description = "Allocation id of the OpenVPN Elastic IP. infra/vpn associates this address and does not release it."
  type        = "String"
  value       = aws_eip.vpn.id
}
