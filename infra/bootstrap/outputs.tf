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

output "zone_name" {
  description = "Existing zone the A record is written into. This stack does not create it and does not change GoDaddy."
  value       = data.aws_route53_zone.app.name
}

output "hosted_zone_id" {
  description = "Zone id the deploy role is scoped to. Re-apply bootstrap if GoNetLogo replaces the zone."
  value       = data.aws_route53_zone.app.zone_id
}

output "vpn_hostname" {
  description = "Only name the deploy role may change. Client profiles use this as remote."
  value       = var.vpn_hostname
}

output "budget_email" {
  description = "Address that must confirm the AWS Budgets subscription."
  value       = var.budget_email
}

output "budget_name" {
  description = "Monthly budget. The first two budgets in the account are free."
  value       = aws_budgets_budget.monthly.name
}
