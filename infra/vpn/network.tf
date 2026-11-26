# The account default VPC. This stack does not create a VPC, a subnet,
# an internet gateway, or a route table. It adds one route to the main
# route table when the GoNetLogo VPC is up, and removes that route on
# destroy. See peering.tf.
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

data "aws_route_table" "default_main" {
  vpc_id = data.aws_vpc.default.id

  filter {
    name   = "association.main"
    values = ["true"]
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

    precondition {
      condition     = !var.peer_gonetlogo || length(data.aws_vpcs.gonetlogo.ids) <= 1
      error_message = "More than one VPC is tagged Name=${var.gonetlogo_vpc_name}. Refusing to guess which one to peer."
    }
  }
}
