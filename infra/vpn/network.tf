# The account default VPC. This stack does not create a VPC, a subnet,
# an internet gateway, or a route table, and it does not add routes.
# The GoNetLogo app stack owns the peering. It puts gonetlogo_cidr on
# this VPC's main route table, which the instance subnet uses, and
# 172.31.0.0/16 on its own tables. Egress to those private addresses
# stays open on the security group below.
data "aws_vpc" "default" {
  id = var.default_vpc_id
}

data "aws_subnets" "default_public" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }

  filter {
    name   = "availability-zone"
    values = [var.instance_az]
  }
}

# UDP 1194 only. There is no SSH rule. Administration is Session Manager.
# Egress stays open so the instance can reach SSM, package mirrors, and,
# after masquerade, private addresses in a peered VPC.
resource "aws_security_group" "vpn" {
  name                   = "openvpn"
  description            = "OpenVPN UDP 1194 from allowed_cidrs. No SSH."
  vpc_id                 = data.aws_vpc.default.id
  revoke_rules_on_delete = true

  ingress {
    description = "OpenVPN"
    from_port   = 1194
    to_port     = 1194
    protocol    = "udp"
    cidr_blocks = var.allowed_cidrs
  }

  egress {
    description = "Outbound to SSM, package mirrors, and peered private addresses. No NAT gateway."
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "openvpn"
  }

  timeouts {
    delete = "20m"
  }

  lifecycle {
    precondition {
      condition     = data.aws_vpc.default.cidr_block == "172.31.0.0/16"
      error_message = "Refusing to use ${data.aws_vpc.default.id}: its CIDR is ${data.aws_vpc.default.cidr_block}, not 172.31.0.0/16."
    }

    precondition {
      condition     = length(data.aws_subnets.default_public.ids) > 0
      error_message = "The default VPC has no subnet in ${var.instance_az}."
    }
  }
}
