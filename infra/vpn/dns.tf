data "aws_route53_zone" "vpn" {
  name         = var.zone_name
  private_zone = false
}

# GoNetLogo's bootstrap owns the zone. This record is the only thing
# we write there, and destroy removes it. The address is the Elastic IP
# from bootstrap, so a rebuild does not change what this name resolves
# to. The record waits until the address is attached, so the first apply
# does not publish it while the instance still has the old public IP.
resource "aws_route53_record" "vpn" {
  zone_id = data.aws_route53_zone.vpn.zone_id
  name    = var.vpn_hostname
  type    = "A"
  ttl     = var.dns_ttl
  records = [data.aws_eip.vpn.public_ip]

  depends_on = [aws_eip_association.vpn]

  lifecycle {
    precondition {
      condition     = var.vpn_hostname == var.zone_name || endswith(var.vpn_hostname, ".${var.zone_name}")
      error_message = "vpn_hostname must be the zone apex or a name under it."
    }
  }
}
