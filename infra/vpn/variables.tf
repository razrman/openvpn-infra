variable "aws_region" {
  type        = string
  description = "Region for every regional resource. The backend block in versions.tf repeats this."
  default     = "us-west-2"
}

variable "account_id" {
  type        = string
  description = "AWS account. The provider refuses to run anywhere else."
  default     = "457504029722"
}

variable "allowed_cidrs" {
  type        = list(string)
  description = "IPv4 CIDRs allowed to reach OpenVPN on UDP 1194. The default is the whole internet. OpenVPN authenticates with TLS and tls-crypt; this list is an extra cut. Edit it and apply to lock the port to a known address. IPv6 is not enabled on the VPC."
  default     = ["0.0.0.0/0"]

  validation {
    condition = length(var.allowed_cidrs) > 0 && alltrue([
      for cidr in var.allowed_cidrs : can(cidrhost(cidr, 0))
    ])
    error_message = "allowed_cidrs must contain at least one IPv4 CIDR."
  }
}

variable "instance_type" {
  type        = string
  description = "Graviton instance size. t4g.nano is enough for a handful of clients once packages are installed. User-data adds a 1 GB swap file because the install is tight on 512 MB. Use t4g.micro if cloud-init runs out of memory."
  default     = "t4g.nano"

  validation {
    condition     = contains(["t4g.nano", "t4g.micro", "t4g.small"], var.instance_type)
    error_message = "instance_type must be t4g.nano, t4g.micro, or t4g.small."
  }
}

variable "vpn_cidr" {
  type        = string
  description = "Tunnel subnet. The server is .1, static clients are .10 through .199, and .200 through .249 is only a fallback pool. scripts/openvpn-client.sh hardcodes 10.8.0.0/24. Change that script in the same edit, and do it before adding clients. The home LAN must not use this range."
  default     = "10.8.0.0/24"

  validation {
    condition     = can(cidrhost(var.vpn_cidr, 0)) && split("/", var.vpn_cidr)[1] == "24"
    error_message = "vpn_cidr must be an IPv4 /24."
  }
}

variable "log_retention_days" {
  type        = number
  description = "CloudWatch retention for /openvpn/server. The log group is destroyed with this stack."
  default     = 14

  validation {
    condition     = var.log_retention_days >= 1 && var.log_retention_days <= 365
    error_message = "log_retention_days must be from 1 to 365."
  }
}
