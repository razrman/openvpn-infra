# GoNetLogo's app stack is created and destroyed on its own. The VPC id
# changes every time that stack is applied. Look it up by the Name tag
# from that repo (infra/app/network.tf). Zero matches is a skip, not an
# error: Infra up still builds the VPN server, and a later Infra up
# adds the peering once the VPC exists.
data "aws_vpcs" "gonetlogo" {
  filter {
    name   = "tag:Name"
    values = [var.gonetlogo_vpc_name]
  }
}

data "aws_vpc" "gonetlogo" {
  count = local.peer_active ? 1 : 0
  id    = data.aws_vpcs.gonetlogo.ids[0]
}

data "aws_route_tables" "gonetlogo" {
  count  = local.peer_active ? 1 : 0
  vpc_id = data.aws_vpc.gonetlogo[0].id
}

resource "aws_vpc_peering_connection" "gonetlogo" {
  count = local.peer_active ? 1 : 0

  vpc_id      = data.aws_vpc.default.id
  peer_vpc_id = data.aws_vpc.gonetlogo[0].id
  auto_accept = true

  tags = {
    Name = "openvpn-gonetlogo"
  }

  lifecycle {
    precondition {
      condition     = data.aws_vpc.gonetlogo[0].cidr_block == var.gonetlogo_cidr
      error_message = "VPC ${data.aws_vpc.gonetlogo[0].id} tagged Name=${var.gonetlogo_vpc_name} is ${data.aws_vpc.gonetlogo[0].cidr_block}, not ${var.gonetlogo_cidr}."
    }
  }
}

# One route on the default VPC main table. The instance subnet uses that
# table. Destroy deletes this route and leaves every other route alone.
resource "aws_route" "to_gonetlogo" {
  count = local.peer_active ? 1 : 0

  route_table_id            = data.aws_route_table.default_main.id
  destination_cidr_block    = var.gonetlogo_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.gonetlogo[0].id
}

# Return path. Clients are masqueraded to the instance's address in the
# default VPC, so GoNetLogo routes 172.31.0.0/16, not the tunnel
# 10.8.0.0/24. Every route table in that VPC gets the route, which covers
# the public table (gonetlogo-public) and the main table.
resource "aws_route" "gonetlogo_return" {
  for_each = local.peer_active ? toset(data.aws_route_tables.gonetlogo[0].ids) : toset([])

  route_table_id            = each.value
  destination_cidr_block    = data.aws_vpc.default.cidr_block
  vpc_peering_connection_id = aws_vpc_peering_connection.gonetlogo[0].id
}
