# Address embedded in every client profile. It stays allocated when the
# vpn stack is destroyed, so existing .ovpn files keep the same remote.
# AWS bills a public IPv4 at $0.005 per hour whether or not it is
# attached, about $3.65 a month. A DNS name would be cheaper and would
# need a domain. The profile would then depend on that name resolving.
resource "aws_eip" "vpn" {
  domain = "vpc"

  tags = {
    Name = "openvpn"
  }
}

# Usage cost, with credits left out, so the alert still fires while
# credits are paying the bill. The first two budgets in an account are
# free. GoNetLogo already has one. AWS will not deliver mail until the
# address accepts the confirmation link.
resource "aws_budgets_budget" "monthly" {
  name         = "openvpn-monthly"
  budget_type  = "COST"
  limit_amount = var.budget_limit_usd
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_types {
    include_credit             = false
    include_discount           = true
    include_other_subscription = true
    include_recurring          = true
    include_refund             = false
    include_subscription       = true
    include_support            = true
    include_tax                = true
    include_upfront            = true
    use_blended                = false
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.budget_email]
  }
}
