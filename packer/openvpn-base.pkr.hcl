# Amazon Linux 2023 arm64 image with the packages the VPN server needs.
# No PKI, certificates, client keys, or SSH authorized_keys. Those stay
# in SSM and in user-data. Packer SSHs to the builder with a temporary
# key. The temporary security group allows port 22 only from the host
# running Packer, and both the group and the key are deleted at the end.

packer {
  required_version = ">= 1.11.0"

  required_plugins {
    amazon = {
      version = "1.8.4"
      source  = "github.com/hashicorp/amazon"
    }
  }
}

variable "region" {
  type    = string
  default = "us-west-2"
}

variable "vpc_id" {
  type    = string
  default = "vpc-02297ce9cfb0e105d"
}

variable "source_ami" {
  type        = string
  description = "Current Amazon Linux 2023 arm64 AMI. The workflow reads the public SSM parameter. Do not bake a custom source id into this file."

  validation {
    condition     = can(regex("^ami-[0-9a-f]+$", var.source_ami))
    error_message = "The source AMI must be an AMI id."
  }
}

variable "ami_name" {
  type        = string
  description = "AMI name and Name tag. UTC date and time, so two builds on the same day do not collide."

  validation {
    condition     = can(regex("^openvpn-base-[0-9]{8}-[0-9]{4}$", var.ami_name))
    error_message = "The image name must look like openvpn-base-YYYYMMDD-HHMM."
  }
}

source "amazon-ebs" "openvpn" {
  region               = var.region
  vpc_id               = var.vpc_id
  instance_type        = "t4g.small"
  source_ami           = var.source_ami
  ami_name             = var.ami_name
  ami_description      = "OpenVPN base image. Packages only. No PKI, certificates, or SSH keys."
  ssh_username         = "ec2-user"
  ssh_interface        = "public_ip"
  ssh_timeout          = "15m"
  iam_instance_profile = "openvpn-ami-builder"
  # Do not also set temporary_security_group_source_cidrs. Packer ignores
  # the public-IP setting when that list is non-empty.
  temporary_security_group_source_public_ip = true
  associate_public_ip_address               = true
  encrypt_boot                              = true
  force_deregister                          = false
  force_delete_snapshot                     = false

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  launch_block_device_mappings {
    device_name           = "/dev/xvda"
    volume_size           = 8
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  tags = {
    project   = "openvpn"
    Name      = var.ami_name
    Project   = "openvpn"
    ManagedBy = "packer"
  }

  snapshot_tags = {
    project   = "openvpn"
    Name      = var.ami_name
    Project   = "openvpn"
    ManagedBy = "packer"
  }

  run_tags = {
    project   = "openvpn"
    Name      = "openvpn-ami-builder"
    Project   = "openvpn"
    ManagedBy = "packer"
  }
}

build {
  sources = ["source.amazon-ebs.openvpn"]

  provisioner "shell" {
    script          = "${path.root}/provision.sh"
    execute_command = "chmod +x {{ .Path }}; sudo -n {{ .Path }}"
  }
}
