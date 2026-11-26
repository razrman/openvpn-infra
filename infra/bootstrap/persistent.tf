# GoNetLogo's bootstrap owns this zone. This stack only reads its id so
# the deploy role can be scoped to it. Do not add an aws_route53_zone
# resource here.
data "aws_route53_zone" "app" {
  name         = var.zone_name
  private_zone = false
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
