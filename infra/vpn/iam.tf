data "aws_iam_policy_document" "instance_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "instance" {
  name                 = "openvpn-instance"
  description          = "OpenVPN instance. Session Manager, server PKI, and the VPN log group."
  assume_role_policy   = data.aws_iam_policy_document.instance_assume.json
  max_session_duration = 3600
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "instance" {
  name   = "openvpn-instance"
  role   = aws_iam_role.instance.id
  policy = data.aws_iam_policy_document.instance.json
}

resource "aws_iam_instance_profile" "instance" {
  name = "openvpn-instance"
  role = aws_iam_role.instance.name
}

data "aws_iam_policy_document" "instance" {
  # Server material and the client address book only. Client private keys
  # and the CA key live under /openvpn/secrets and are not in this list.
  statement {
    sid    = "ServerMaterial"
    effect = "Allow"
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:GetParametersByPath",
    ]
    resources = [
      "arn:aws:ssm:${var.aws_region}:${var.account_id}:parameter/openvpn/clients",
      "arn:aws:ssm:${var.aws_region}:${var.account_id}:parameter/openvpn/clients/*",
      "arn:aws:ssm:${var.aws_region}:${var.account_id}:parameter/openvpn/pki",
      "arn:aws:ssm:${var.aws_region}:${var.account_id}:parameter/openvpn/pki/*",
    ]
  }

  statement {
    sid    = "SsmKms"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:DescribeKey",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${var.aws_region}.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "kms:CallerAccount"
      values   = [var.account_id]
    }
  }

  statement {
    sid    = "VpnLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:DescribeLogStreams",
      "logs:PutLogEvents",
    ]
    resources = [
      "arn:aws:logs:${var.aws_region}:${var.account_id}:log-group:/openvpn/server",
      "arn:aws:logs:${var.aws_region}:${var.account_id}:log-group:/openvpn/server:*",
    ]
  }

  statement {
    sid       = "DescribeLogGroups"
    effect    = "Allow"
    actions   = ["logs:DescribeLogGroups"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.aws_region]
    }
  }
}
