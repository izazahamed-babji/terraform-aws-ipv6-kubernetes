variable "instance_name" {
  description = "Name of the project"
  type        = string
}

variable "vpc_id" {
  description = "value"
  type        = string  
}

variable "subnet_id" {
  description = "value"
  type        = string
}

variable "instance_type" {
  description = "Type of instance for NAT64-DNS64 node"
  default     = "t3.small"
}

variable "ssh_access_ipv4_cidr" {
  description = "List of IPv4 CIDRs from which SSH access is allowed"
  type        = list(string)
  default = [
    "0.0.0.0/0"
  ]
}

variable "ssh_access_ipv6_cidr" {
  description = "List of IPv6 CIDRs from which SSH access is allowed"
  type        = list(string)
  default = [
    "::/0"
  ]
}

variable "master_security_group_id" {
  description = "Security group ID of the master node"
  type        = string
}

variable "workers_security_group_id" {
  description = "Security group ID of the worker nodes"
  type        = string
}

variable "nat64_ipv6_cidr" {
  description = "CIDR for NAT64 translation"
  type        = string 
}

variable "vpc_ipv6_cidr" {
  description = "CIDR for VPC. This is used for configuring BIND9 to allow kube-proxy clients"
  type        = string
}

variable "ssh_key_name" {
  description = "value"
  type        = string
}

variable "tags" {
  description = "Tags used for the AWS resources"
  type        = map(string)
}