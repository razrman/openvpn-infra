data "aws_route53_zone" "vpn" {
  name         = var.zone_name
  private_zone = false
}

# GoNetLogo's bootstrap owns the zone. This record is the only thing
# we write there, and destroy removes it. The instance address changes
# every Infra up. The name in the client profiles does not.
resource "aws_route53_record" "vpn" {
  zone_id = data.aws_route53_zone.vpn.zone_id
  name    = var.vpn_hostname
  type    = "A"
  ttl     = var.dns_ttl
  records = [aws_instance.vpn.public_ip]

  lifecycle {
    precondition {
      condition     = var.vpn_hostname == var.zone_name || endswith(var.vpn_hostname, ".${var.zone_name}")
      error_message = "vpn_hostname must be the zone apex or a name under it."
    }
  }
}
