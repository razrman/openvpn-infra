output "state_bucket" {
  description = "S3 bucket holding infra/vpn state. The vpn backend block uses this name."
  value       = aws_s3_bucket.state.bucket
}

output "deploy_role_arn" {
  description = "Value for the GitHub repository variable AWS_DEPLOY_ROLE_ARN."
  value       = aws_iam_role.deploy.arn
}

output "github_oidc_provider_arn" {
  description = "Existing IAM OIDC provider for token.actions.githubusercontent.com. This stack does not create it."
  value       = data.aws_iam_openid_connect_provider.github.arn
}

output "github_subjects" {
  description = "OIDC subjects allowed to assume the deploy role."
  value       = var.github_subjects
}

output "eip_public_ip" {
  description = "Stable OpenVPN address. Client profiles use this as their remote."
  value       = aws_eip.vpn.public_ip
}

output "eip_allocation_id" {
  description = "Elastic IP allocation. The vpn stack associates it and does not own it."
  value       = aws_eip.vpn.allocation_id
}

output "budget_email" {
  description = "Address that must confirm the AWS Budgets subscription."
  value       = var.budget_email
}

output "budget_name" {
  description = "Monthly budget. The first two budgets in the account are free."
  value       = aws_budgets_budget.monthly.name
}
