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
  description = "IPv4 CIDRs allowed to reach OpenVPN on UDP 1194. This is the only internet allowlist. Infra up and Infra plan pass VPN_ALLOWED_CIDRS when that GitHub variable is set, and use 0.0.0.0/0 when it is empty. IPv6 is not accepted."
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

variable "default_vpc_id" {
  type        = string
  description = "Account default VPC. The instance is placed in a public subnet of this VPC. The stack does not create or delete the VPC."
  default     = "vpc-02297ce9cfb0e105d"
}

variable "instance_az" {
  type        = string
  description = "Availability zone of the default-VPC subnet that holds the instance. The default VPC has a public subnet in each of a, b, c, and d."
  default     = "us-west-2a"
}

variable "zone_name" {
  type        = string
  description = "Existing public zone owned by GoNetLogo's bootstrap. This stack looks it up and does not create or delete it. The same name is the default in infra/bootstrap."
  default     = "app.sapienexmachina.si"
}

variable "vpn_hostname" {
  type        = string
  description = "A record in zone_name. Client profiles use this as remote. Infra up points it at the instance and Infra down deletes it. The deploy role may change only this name."
  default     = "vpn.app.sapienexmachina.si"
}

variable "dns_ttl" {
  type        = number
  description = "TTL of the A record. Short so a rebuilt instance is picked up quickly."
  default     = 60

  validation {
    condition     = var.dns_ttl >= 30 && var.dns_ttl <= 300
    error_message = "dns_ttl must be from 30 to 300 seconds."
  }
}

variable "peer_gonetlogo" {
  type        = bool
  description = "Peer to the VPC tagged Name=gonetlogo and push 10.20.0.0/16 to clients. When that VPC does not exist, apply skips the peering instead of failing. Set false to never peer."
  default     = true
}

variable "gonetlogo_vpc_name" {
  type        = string
  description = "Name tag on the GoNetLogo VPC, from that repo's infra/app/network.tf. The VPC id changes every time that stack is recreated."
  default     = "gonetlogo"
}

variable "gonetlogo_cidr" {
  type        = string
  description = "GoNetLogo VPC CIDR from that repo's infra/app/locals.tf. Pushed to clients and routed across the peering. It must not overlap the default VPC or the tunnel."
  default     = "10.20.0.0/16"

  validation {
    condition     = can(cidrhost(var.gonetlogo_cidr, 0))
    error_message = "gonetlogo_cidr must be an IPv4 CIDR."
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
