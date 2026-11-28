# Instance profile for the Packer builder. It can register with Session
# Manager and nothing else. It cannot read /openvpn. Bootstrap creates
# it so Build AMI can run before the vpn stack exists, and so a build
# still works after Infra down has deleted the server's own role.
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
  description          = "Temporary Packer builder for the OpenVPN base image. Session Manager only."
  assume_role_policy   = data.aws_iam_policy_document.ami_builder_assume.json
  max_session_duration = 3600
}

resource "aws_iam_role_policy_attachment" "ami_builder_ssm" {
  role       = aws_iam_role.ami_builder.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ami_builder" {
  name = "openvpn-ami-builder"
  role = aws_iam_role.ami_builder.name
}
