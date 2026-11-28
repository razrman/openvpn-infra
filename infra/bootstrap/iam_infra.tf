data "aws_iam_policy_document" "infra" {
  # The instance role only. This statement does not cover
  # openvpn-github-deploy, so a workflow cannot rewrite its own trust.
  statement {
    sid    = "InstanceRole"
    effect = "Allow"
    actions = [
      "iam:AddRoleToInstanceProfile",
      "iam:AttachRolePolicy",
      "iam:CreateInstanceProfile",
      "iam:CreateRole",
      "iam:DeleteInstanceProfile",
      "iam:DeleteRole",
      "iam:DeleteRolePolicy",
      "iam:DetachRolePolicy",
      "iam:GetInstanceProfile",
      "iam:GetRole",
      "iam:GetRolePolicy",
      "iam:ListAttachedRolePolicies",
      "iam:ListInstanceProfileTags",
      "iam:ListInstanceProfilesForRole",
      "iam:ListRolePolicies",
      "iam:ListRoleTags",
      "iam:PutRolePolicy",
      "iam:RemoveRoleFromInstanceProfile",
      "iam:TagInstanceProfile",
      "iam:TagRole",
      "iam:UntagInstanceProfile",
      "iam:UntagRole",
      "iam:UpdateAssumeRolePolicy",
      "iam:UpdateRole",
    ]
    resources = [
      "arn:aws:iam::${var.account_id}:instance-profile/openvpn-instance",
      "arn:aws:iam::${var.account_id}:role/openvpn-instance",
    ]
  }

  statement {
    sid       = "PassInstanceRole"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = ["arn:aws:iam::${var.account_id}:role/openvpn-instance"]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ec2.amazonaws.com"]
    }
  }

  # The Packer builder profile. Bootstrap creates the role. This
  # statement only lets the workflow pass it to EC2.
  statement {
    sid       = "PassAmiBuilderRole"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = ["arn:aws:iam::${var.account_id}:role/openvpn-ami-builder"]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ec2.amazonaws.com"]
    }
  }

  statement {
    sid    = "ReadSsmCorePolicy"
    effect = "Allow"
    actions = [
      "iam:GetPolicy",
      "iam:GetPolicyVersion",
    ]
    resources = ["arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"]
  }

  # Session Manager's service-linked role. Resource-level ARNs are not
  # accepted for this action. The condition is the whole restriction.
  statement {
    sid       = "SsmServiceLinkedRole"
    effect    = "Allow"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "iam:AWSServiceName"
      values   = ["ssm.amazonaws.com"]
    }
  }

  # The instance uses the default VPC. This role cannot create a VPC, a
  # subnet, an internet gateway, a route table, or an Elastic IP, and it
  # cannot release one. It can associate and disassociate the address
  # bootstrap allocated. The peering and route actions below stay on
  # this policy. infra/vpn no longer calls them. The GoNetLogo app stack
  # owns the peering and its routes.
  statement {
    sid    = "NetworkAndInstance"
    effect = "Allow"
    actions = [
      "ec2:AcceptVpcPeeringConnection",
      "ec2:AssociateAddress",
      "ec2:AuthorizeSecurityGroupEgress",
      "ec2:AuthorizeSecurityGroupIngress",
      "ec2:CreateNetworkInterface",
      "ec2:CreateRoute",
      "ec2:CreateSecurityGroup",
      "ec2:CreateTags",
      "ec2:CreateVolume",
      "ec2:CreateVpcPeeringConnection",
      "ec2:DeleteNetworkInterface",
      "ec2:DeleteRoute",
      "ec2:DeleteSecurityGroup",
      "ec2:DeleteTags",
      "ec2:DeleteVolume",
      "ec2:DeleteVpcPeeringConnection",
      "ec2:Describe*",
      "ec2:DetachNetworkInterface",
      "ec2:DisassociateAddress",
      "ec2:Get*",
      "ec2:ModifyInstanceAttribute",
      "ec2:ModifyNetworkInterfaceAttribute",
      "ec2:ModifyVolume",
      "ec2:RevokeSecurityGroupEgress",
      "ec2:RevokeSecurityGroupIngress",
      "ec2:RunInstances",
      "ec2:StopInstances",
      "ec2:TerminateInstances",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.aws_region]
    }
  }

  statement {
    sid    = "VpnLogGroup"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:DeleteLogGroup",
      "logs:DeleteRetentionPolicy",
      "logs:ListTagsForResource",
      "logs:ListTagsLogGroup",
      "logs:PutRetentionPolicy",
      "logs:TagResource",
      "logs:UntagResource",
    ]
    resources = [
      "arn:aws:logs:${var.aws_region}:${var.account_id}:log-group:/openvpn/server",
      "arn:aws:logs:${var.aws_region}:${var.account_id}:log-group:/openvpn/server:*",
    ]
  }

  # DescribeLogGroups is evaluated against * by the API.
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

  # Writes are limited to one A record in GoNetLogo's existing zone.
  # The role cannot delete the zone or change any other name in it.
  # NormalizedRecordNames is the lowercase name with no trailing dot.
  statement {
    sid     = "VpnDnsRecord"
    effect  = "Allow"
    actions = ["route53:ChangeResourceRecordSets"]
    resources = [
      data.aws_route53_zone.app.arn,
    ]

    condition {
      test     = "ForAllValues:StringEquals"
      variable = "route53:ChangeResourceRecordSetsNormalizedRecordNames"
      values   = [var.vpn_hostname]
    }

    condition {
      test     = "ForAllValues:StringEquals"
      variable = "route53:ChangeResourceRecordSetsRecordTypes"
      values   = ["A"]
    }

    condition {
      test     = "Null"
      variable = "route53:ChangeResourceRecordSetsNormalizedRecordNames"
      values   = ["false"]
    }
  }

  statement {
    sid    = "VpnDnsRead"
    effect = "Allow"
    actions = [
      "route53:GetHostedZone",
      "route53:ListResourceRecordSets",
      "route53:ListTagsForResource",
    ]
    resources = [
      data.aws_route53_zone.app.arn,
    ]
  }

  statement {
    sid    = "DnsList"
    effect = "Allow"
    actions = [
      "route53:ListHostedZones",
      "route53:ListHostedZonesByName",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "DnsGetChange"
    effect    = "Allow"
    actions   = ["route53:GetChange"]
    resources = ["arn:aws:route53:::change/*"]
  }

  # Image build. Create and register are not tag-scoped: the image does
  # not have its tag until Packer sets it. Deregister and snapshot delete
  # require project=openvpn, which Packer sets on the image and the
  # snapshot. The workflow also filters the name openvpn-base-*.
  statement {
    sid    = "AmiBuild"
    effect = "Allow"
    actions = [
      "ec2:AttachVolume",
      "ec2:CopyImage",
      "ec2:CreateImage",
      "ec2:CreateKeyPair",
      "ec2:CreateSnapshot",
      "ec2:DeleteKeyPair",
      "ec2:GetPasswordData",
      "ec2:ModifyImageAttribute",
      "ec2:ModifySnapshotAttribute",
      "ec2:RegisterImage",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.aws_region]
    }
  }

  statement {
    sid    = "AmiDeregister"
    effect = "Allow"
    actions = [
      "ec2:DeleteSnapshot",
      "ec2:DeregisterImage",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.aws_region]
    }

    condition {
      test     = "StringEquals"
      variable = "ec2:ResourceTag/project"
      values   = ["openvpn"]
    }
  }

  # Packer reaches the builder through Session Manager. The document is
  # AWS-owned, so its ARN has an empty account id.
  statement {
    sid    = "AmiSession"
    effect = "Allow"
    actions = [
      "ssm:ResumeSession",
      "ssm:StartSession",
      "ssm:TerminateSession",
    ]
    resources = [
      "arn:aws:ec2:${var.aws_region}:${var.account_id}:instance/*",
      "arn:aws:ssm:${var.aws_region}:${var.account_id}:session/*",
      "arn:aws:ssm:${var.aws_region}::document/AWS-StartSSHSession",
      "arn:aws:ssm:*::document/AWS-StartSSHSession",
    ]
  }

  statement {
    sid    = "AmiSessionDescribe"
    effect = "Allow"
    actions = [
      "ssm:DescribeInstanceInformation",
      "ssm:DescribeSessions",
      "ssm:GetConnectionStatus",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.aws_region]
    }
  }

  # Encrypted EBS snapshots for the base image. CreateGrant is how EC2
  # uses the account's EBS key. It is limited to grants for an AWS service.
  statement {
    sid    = "AmiEbsKey"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:DescribeKey",
      "kms:GenerateDataKey",
      "kms:GenerateDataKeyWithoutPlaintext",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ec2.${var.aws_region}.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "kms:CallerAccount"
      values   = [var.account_id]
    }
  }

  statement {
    sid       = "AmiEbsGrant"
    effect    = "Allow"
    actions   = ["kms:CreateGrant"]
    resources = ["*"]

    condition {
      test     = "Bool"
      variable = "kms:GrantIsForAWSResource"
      values   = ["true"]
    }

    condition {
      test     = "StringEquals"
      variable = "kms:CallerAccount"
      values   = [var.account_id]
    }
  }

  # Public SSM parameter that names the current Amazon Linux 2023 arm64 AMI.
  # The account id in this ARN is empty on purpose. AWS owns the parameter.
  statement {
    sid    = "AmazonLinuxAmi"
    effect = "Allow"
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
    ]
    resources = [
      "arn:aws:ssm:${var.aws_region}::parameter/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64",
    ]
  }
}
