resource "aws_s3_bucket" "state" {
  bucket = var.state_bucket
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  # use_lockfile writes a .tflock object on every plan and apply. Versioning
  # keeps those forever unless a lifecycle drops noncurrent versions.
  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 90
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.state]
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.state_bucket.json

  depends_on = [aws_s3_bucket_public_access_block.state]
}

data "aws_iam_policy_document" "state_bucket" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.state.arn,
      "${aws_s3_bucket.state.arn}/*",
    ]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

# The account already has this provider. GoNetLogo's bootstrap created it.
# Do not add an aws_iam_openid_connect_provider resource. A second create
# for the same URL fails, and this stack must not take ownership of it.
data "aws_iam_openid_connect_provider" "github" {
  arn = "arn:aws:iam::${var.account_id}:oidc-provider/token.actions.githubusercontent.com"
}

data "aws_iam_policy_document" "github_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # StringEquals on the full subject, not a wildcard. The job must
    # reference the GitHub environment named production or the subject
    # will not match and STS will refuse the assume-role call.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = var.github_subjects
    }
  }
}

resource "aws_iam_role" "deploy" {
  name                 = "openvpn-github-deploy"
  description          = "GitHub Actions OpenTofu and client certificates for razrman/openvpn-infra production."
  assume_role_policy   = data.aws_iam_policy_document.github_assume.json
  max_session_duration = 3600
}

resource "aws_iam_role_policy" "state" {
  name   = "openvpn-state"
  role   = aws_iam_role.deploy.id
  policy = data.aws_iam_policy_document.state.json
}

resource "aws_iam_role_policy" "infra" {
  name   = "openvpn-infra"
  role   = aws_iam_role.deploy.id
  policy = data.aws_iam_policy_document.infra.json
}

resource "aws_iam_role_policy" "pki" {
  name   = "openvpn-pki"
  role   = aws_iam_role.deploy.id
  policy = data.aws_iam_policy_document.pki.json
}

resource "aws_iam_role_policy" "deny" {
  name   = "openvpn-deny-foreign"
  role   = aws_iam_role.deploy.id
  policy = data.aws_iam_policy_document.deny.json
}

data "aws_iam_policy_document" "state" {
  statement {
    sid    = "StateBucket"
    effect = "Allow"
    actions = [
      "s3:GetBucketLocation",
      "s3:GetBucketVersioning",
      "s3:ListBucket",
      "s3:ListBucketVersions",
    ]
    resources = [aws_s3_bucket.state.arn]
  }

  statement {
    sid    = "StateObjects"
    effect = "Allow"
    actions = [
      "s3:DeleteObject",
      "s3:DeleteObjectVersion",
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:PutObject",
    ]
    resources = ["${aws_s3_bucket.state.arn}/*"]
  }
}

data "aws_iam_policy_document" "pki" {
  # Client certificates, the CA, and the CRL. The vpn instance role is
  # not allowed to read /openvpn/secrets. This role is, because the
  # client workflow issues and revokes certificates.
  statement {
    sid    = "OpenVpnParameters"
    effect = "Allow"
    actions = [
      "ssm:DeleteParameter",
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:GetParametersByPath",
      "ssm:PutParameter",
    ]
    resources = [
      "arn:aws:ssm:${var.aws_region}:${var.account_id}:parameter/openvpn",
      "arn:aws:ssm:${var.aws_region}:${var.account_id}:parameter/openvpn/*",
    ]
  }

  statement {
    sid    = "OpenVpnParameterKms"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:DescribeKey",
      "kms:Encrypt",
      "kms:GenerateDataKey",
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
}

data "aws_iam_policy_document" "deny" {
  # The allow statements above are name-scoped where IAM permits it.
  # These denies are the backstop for the other projects in this account.
  statement {
    sid    = "DenyForeignIam"
    effect = "Deny"
    actions = [
      "iam:*",
    ]
    resources = [
      "arn:aws:iam::${var.account_id}:instance-profile/gonetlogo-*",
      "arn:aws:iam::${var.account_id}:instance-profile/sapienexmachina-*",
      "arn:aws:iam::${var.account_id}:policy/gonetlogo-*",
      "arn:aws:iam::${var.account_id}:policy/sapienexmachina-*",
      "arn:aws:iam::${var.account_id}:role/gonetlogo-*",
      "arn:aws:iam::${var.account_id}:role/sapienexmachina-*",
    ]
  }

  statement {
    sid    = "DenyForeignBuckets"
    effect = "Deny"
    actions = [
      "s3:*",
    ]
    resources = [
      "arn:aws:s3:::gonetlogo-*",
      "arn:aws:s3:::gonetlogo-*/*",
      "arn:aws:s3:::sapienexmachina-*",
      "arn:aws:s3:::sapienexmachina-*/*",
    ]
  }

  statement {
    sid    = "DenyForeignParameters"
    effect = "Deny"
    actions = [
      "ssm:*",
    ]
    resources = [
      "arn:aws:ssm:${var.aws_region}:${var.account_id}:parameter/gonetlogo",
      "arn:aws:ssm:${var.aws_region}:${var.account_id}:parameter/gonetlogo/*",
      "arn:aws:ssm:${var.aws_region}:${var.account_id}:parameter/sapienexmachina",
      "arn:aws:ssm:${var.aws_region}:${var.account_id}:parameter/sapienexmachina/*",
    ]
  }

  statement {
    sid    = "DenyForeignEcrEcsLogs"
    effect = "Deny"
    actions = [
      "ecr:*",
      "ecs:*",
      "logs:*",
    ]
    resources = [
      "arn:aws:ecr:${var.aws_region}:${var.account_id}:repository/gonetlogo",
      "arn:aws:ecr:${var.aws_region}:${var.account_id}:repository/gonetlogo/*",
      "arn:aws:ecr:${var.aws_region}:${var.account_id}:repository/sapienexmachina",
      "arn:aws:ecr:${var.aws_region}:${var.account_id}:repository/sapienexmachina/*",
      "arn:aws:ecs:${var.aws_region}:${var.account_id}:cluster/gonetlogo",
      "arn:aws:ecs:${var.aws_region}:${var.account_id}:cluster/sapienexmachina",
      "arn:aws:ecs:${var.aws_region}:${var.account_id}:service/gonetlogo/*",
      "arn:aws:ecs:${var.aws_region}:${var.account_id}:service/sapienexmachina/*",
      "arn:aws:logs:${var.aws_region}:${var.account_id}:log-group:/ecs/gonetlogo",
      "arn:aws:logs:${var.aws_region}:${var.account_id}:log-group:/ecs/gonetlogo:*",
      "arn:aws:logs:${var.aws_region}:${var.account_id}:log-group:/ecs/sapienexmachina",
      "arn:aws:logs:${var.aws_region}:${var.account_id}:log-group:/ecs/sapienexmachina:*",
    ]
  }

  # EC2 ARNs are ids, not names. This deny matches resources already
  # tagged for the other projects. Describe calls are not in the list:
  # a deny on those can fail an entire describe that happens to see one
  # of their instances.
  statement {
    sid    = "DenyForeignEc2"
    effect = "Deny"
    actions = [
      "ec2:AuthorizeSecurityGroupEgress",
      "ec2:AuthorizeSecurityGroupIngress",
      "ec2:DeleteSecurityGroup",
      "ec2:DeleteSubnet",
      "ec2:DeleteVpc",
      "ec2:RevokeSecurityGroupEgress",
      "ec2:RevokeSecurityGroupIngress",
      "ec2:TerminateInstances",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Project"
      values   = ["gonetlogo", "sapienexmachina"]
    }
  }
}
