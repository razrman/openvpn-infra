output "public_ip" {
  description = "Elastic IP clients already have in their .ovpn files. This association is what makes it answer."
  value       = data.aws_eip.vpn.public_ip
}

output "instance_id" {
  description = "Instance id for Session Manager. There is no SSH port."
  value       = aws_instance.vpn.id
}

output "vpn_cidr" {
  description = "Tunnel subnet. Static client addresses are .10 through .199."
  value       = var.vpn_cidr
}

output "server_vpn_ip" {
  description = "OpenVPN address of this instance on the tunnel."
  value       = local.server_ip
}

output "log_group_name" {
  description = "CloudWatch log group for OpenVPN. Destroyed with this stack."
  value       = aws_cloudwatch_log_group.vpn.name
}

output "security_group_id" {
  description = "Security group. UDP 1194 from allowed_cidrs, no SSH."
  value       = aws_security_group.vpn.id
}
