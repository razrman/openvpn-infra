# Bootstrap allocates the address and records its allocation id. This
# stack only attaches it. Destroy disassociates the address and leaves
# the allocation in place, so the next Infra up gets the same public IP.
data "aws_ssm_parameter" "eip_allocation_id" {
  name = "/openvpn/network/eip-allocation-id"
}

data "aws_eip" "vpn" {
  id = data.aws_ssm_parameter.eip_allocation_id.value
}

resource "aws_eip_association" "vpn" {
  allocation_id       = data.aws_eip.vpn.id
  instance_id         = aws_instance.vpn.id
  allow_reassociation = true

  lifecycle {
    precondition {
      condition = (
        try(data.aws_eip.vpn.tags["project"], "") == "openvpn" ||
        try(data.aws_eip.vpn.tags["Project"], "") == "openvpn"
      )
      error_message = "Refusing to associate ${data.aws_eip.vpn.public_ip} (${data.aws_eip.vpn.id}): it is not tagged project=openvpn."
    }
  }
}
