output "public_ip" {
  description = "Elastic IP from bootstrap. Infra down disassociates it and does not release it. Clients use vpn_hostname, not this value."
  value       = data.aws_eip.vpn.public_ip
}

output "eip_allocation_id" {
  description = "Allocation id of public_ip. Owned by infra/bootstrap."
  value       = data.aws_eip.vpn.id
}

output "vpn_hostname" {
  description = "Name in client profiles. The A record points it at the Elastic IP."
  value       = aws_route53_record.vpn.fqdn
}

output "instance_id" {
  description = "Instance id for Session Manager. There is no SSH port."
  value       = aws_instance.vpn.id
}

output "vpc_id" {
  description = "Default VPC the instance runs in. This stack does not create it."
  value       = data.aws_vpc.default.id
}

output "subnet_id" {
  description = "Default-VPC subnet in instance_az."
  value       = data.aws_subnets.default_public.ids[0]
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

output "gonetlogo_vpc_id" {
  description = "Peered GoNetLogo VPC, or null when that VPC is not up."
  value       = local.peer_active ? data.aws_vpcs.gonetlogo.ids[0] : null
}

output "peering_connection_id" {
  description = "Peering connection to GoNetLogo, or null when that VPC is not up."
  value       = local.peer_active ? aws_vpc_peering_connection.gonetlogo[0].id : null
}
