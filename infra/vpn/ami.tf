# Public Amazon Linux 2023 arm64 image. Used only when no openvpn-base
# AMI is registered yet. The id is not a secret.
data "aws_ssm_parameter" "al2023_arm" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

# Newest image this account owns, named openvpn-base-* and tagged
# project=openvpn. An empty list is normal before the first Build AMI.
# sort_ascending false is newest first.
data "aws_ami_ids" "openvpn_base" {
  owners         = [var.account_id]
  sort_ascending = false

  filter {
    name   = "tag:project"
    values = ["openvpn"]
  }

  filter {
    name   = "name"
    values = ["openvpn-base-*"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }

  filter {
    name   = "architecture"
    values = ["arm64"]
  }
}

locals {
  use_project_ami = length(data.aws_ami_ids.openvpn_base.ids) > 0
  ami_id = (
    local.use_project_ami
    ? data.aws_ami_ids.openvpn_base.ids[0]
    : nonsensitive(data.aws_ssm_parameter.al2023_arm.value)
  )
}
