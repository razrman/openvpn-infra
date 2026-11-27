# The GoNetLogo app stack (razrman/GoNetLogo, infra/app) owns the VPC
# peering and the routes on both sides. It adds 10.20.0.0/16 on the
# default VPC main table, which this instance's subnet uses, and
# 172.31.0.0/16 on its own tables. This stack only pushes that CIDR to
# VPN clients when peer_gonetlogo is true.
#
# These addresses used to be resources in this state. The peering was
# deleted in AWS by hand so GoNetLogo's Infra down can destroy its
# connection before deleting its VPC. destroy is false so the next
# apply forgets them and does not call the EC2 delete APIs. A route is
# identified by table and destination, so a destroy from this state
# could remove a route the GoNetLogo stack had just created. Delete
# these blocks after one apply has dropped the addresses from state.

removed {
  from = aws_vpc_peering_connection.gonetlogo

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_route.to_gonetlogo

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_route.gonetlogo_return

  lifecycle {
    destroy = false
  }
}
