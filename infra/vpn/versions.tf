# Destroyable VPN stack: security group, EC2 instance in the default VPC,
# the association to the Elastic IP, the A record, and the log group.
# The GoNetLogo app stack owns the peering and its routes. State is in
# the bucket from infra/bootstrap, locked with OpenTofu's S3 lockfile
# (use_lockfile). There is no DynamoDB table. The bucket name is a
# literal because a backend block cannot interpolate.
#
# The state bucket, deploy role, Elastic IP allocation, budget, and the
# OpenVPN PKI in SSM are not in this state. Destroying this stack
# disassociates the address and leaves the allocation in place.

terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.72.0"
    }
  }

  backend "s3" {
    bucket       = "openvpn-tfstate-457504029722"
    key          = "vpn/terraform.tfstate"
    region       = "us-west-2"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region              = var.aws_region
  allowed_account_ids = [var.account_id]

  default_tags {
    tags = {
      Project   = "openvpn"
      Stack     = "vpn"
      ManagedBy = "opentofu"
    }
  }
}
