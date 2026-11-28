# Instance profile for the Packer builder. The role has no policies.
# The builder is reached by SSH with Packer's temporary key, not by
# Session Manager. It cannot read /openvpn. Bootstrap creates the
# profile so Build AMI can run before the vpn stack exists, and so a
# build still works after Infra down has deleted the server's own role.
data "aws_iam_policy_document" "ami_builder_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ami_builder" {
  name                 = "openvpn-ami-builder"
  description          = "Temporary Packer builder for the OpenVPN base image. No AWS permissions."
  assume_role_policy   = data.aws_iam_policy_document.ami_builder_assume.json
  max_session_duration = 3600
}

resource "aws_iam_instance_profile" "ami_builder" {
  name = "openvpn-ami-builder"
  role = aws_iam_role.ami_builder.name
}
