data "aws_ssm_parameter" "al2023_arm" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

data "aws_eip" "vpn" {
  filter {
    name   = "tag:Name"
    values = ["openvpn"]
  }

  filter {
    name   = "tag:Project"
    values = ["openvpn"]
  }
}

resource "aws_instance" "vpn" {
  ami           = data.aws_ssm_parameter.al2023_arm.value
  instance_type = var.instance_type
  subnet_id     = aws_subnet.public.id

  vpc_security_group_ids = [aws_security_group.vpn.id]
  iam_instance_profile   = aws_iam_instance_profile.instance.name

  # A launch address lets user-data reach the package mirrors and SSM
  # before the Elastic IP association finishes. Associating the Elastic
  # IP releases that temporary address. Clients use the Elastic IP.
  associate_public_ip_address = true

  user_data = templatefile("${path.module}/templates/user-data.sh.tftpl", {
    sync_script = file("${path.module}/files/sync.sh")
    server_conf = templatefile("${path.module}/templates/server.conf.tftpl", {
      vpn_network = local.vpn_network
      vpn_netmask = local.vpn_netmask
      server_ip   = local.server_ip
      pool_start  = local.pool_start
      pool_end    = local.pool_end
    })
    sync_service = file("${path.module}/files/openvpn-sync.service")
    sync_timer   = file("${path.module}/files/openvpn-sync.timer")
    cwagent_json = file("${path.module}/files/amazon-cloudwatch-agent.json")
  })
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
  }

  depends_on = [aws_cloudwatch_log_group.vpn]
}

resource "aws_eip_association" "vpn" {
  allocation_id = data.aws_eip.vpn.id
  instance_id   = aws_instance.vpn.id
}
