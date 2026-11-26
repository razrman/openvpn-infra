variable "aws_region" {
  type        = string
  description = "Region for the state bucket, the Elastic IP, and the vpn stack."
  default     = "us-west-2"
}

variable "account_id" {
  type        = string
  description = "AWS account that owns this stack. The provider refuses to run anywhere else."
  default     = "457504029722"
}

variable "state_bucket" {
  type        = string
  description = "S3 bucket for infra/vpn state. The same name is copied into infra/vpn/versions.tf because a backend block cannot read variables."
  default     = "openvpn-tfstate-457504029722"
}

variable "budget_email" {
  type        = string
  description = "Inbox for the monthly AWS Budgets alert. AWS sends a confirmation link that must be accepted before mail is delivered. The default is the address used by the GoNetLogo stack in this account. Change it before the first apply if that inbox is wrong."
  default     = "jphelps@iaip.com"

  validation {
    condition     = can(regex("^[^@[:space:]]+@[^@[:space:]]+$", var.budget_email))
    error_message = "budget_email must be an email address."
  }
}

variable "budget_limit_usd" {
  type        = string
  description = "Monthly cost alert threshold in USD, measured before credits. The running server is about $8. Torn down, the idle Elastic IP is about $4."
  default     = "10"
}

variable "github_subjects" {
  type        = list(string)
  description = "Exact token.actions.githubusercontent.com:sub values that may assume the deploy role. Both are this repository's production environment. The legacy repo:razrman/openvpn-infra:environment:production string is what was requested. This repository was created on 2026-11-26, after GitHub started putting the owner id and the repository id in the subject, so workflows will present the id form instead. Trusting both still admits only this repository and only the production environment. Change the list if a failed assume-role shows a different subject."
  default = [
    "repo:razrman/openvpn-infra:environment:production",
    "repo:razrman@1226040/openvpn-infra@1473411194:environment:production",
  ]

  validation {
    condition     = length(var.github_subjects) > 0
    error_message = "github_subjects must contain at least one subject."
  }
}
