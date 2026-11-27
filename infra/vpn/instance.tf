data "aws_ssm_parameter" "al2023_arm" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

resource "aws_instance" "vpn" {
  ami           = data.aws_ssm_parameter.al2023_arm.value
  instance_type = var.instance_type
  subnet_id     = data.aws_subnets.default_public.ids[0]

  vpc_security_group_ids = [aws_security_group.vpn.id]
  iam_instance_profile   = aws_iam_instance_profile.instance.name

  # The subnet assigns a public address at launch. aws_eip_association
  # replaces that address with the Elastic IP from bootstrap without
  # replacing this instance. Turning this flag off is ForceNew, so it
  # stays on. Source/dest check stays on: tunnel traffic into the peered
  # VPC is masqueraded to this instance's own address.
  associate_public_ip_address = true
  source_dest_check           = true

  user_data                   = local.user_data
  user_data_replace_on_change = true

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  credit_specification {
    cpu_credits = "standard"
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 8
    encrypted             = true
    delete_on_termination = true
  }

  tags = {
    Name = "openvpn"
  }

  # A newer Amazon Linux AMI should not replace a server that is already
  # up. The next create, after a destroy, reads the parameter again.
  lifecycle {
    ignore_changes = [ami]

    precondition {
      condition     = length(local.user_data) <= 16384
      error_message = "user-data is ${length(local.user_data)} bytes. EC2 accepts 16384."
    }
  }

  depends_on = [aws_cloudwatch_log_group.vpn]
}
