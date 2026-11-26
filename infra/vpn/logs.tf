resource "aws_cloudwatch_log_group" "vpn" {
  name              = "/openvpn/server"
  retention_in_days = var.log_retention_days

  tags = {
    Name = "openvpn"
  }
}
