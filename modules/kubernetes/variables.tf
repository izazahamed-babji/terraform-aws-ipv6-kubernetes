variable "project_name" {
  description = "Name of the project"
  type        = string
}

variable "aws_region" {
  description = "AWS primary region where all the infra resources are created"
  default     = "ap-southeast-2"
}

variable "aws_zones" {
  description = "AWS AZs (availability zones) where subnets should be created"
  type        = list
}

variable "enable_secondary_cluster" {
  description = "Enable the infra for the secondary cluster"
  type        = bool
  default     = false
}

variable "primary_cluster_name" {
  description = "Name of the Primary Kubernetes cluster"
  type        = string
}

variable "secondary_cluster_name" {
  description = "Name of the Secondary Kubernetes cluster"
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes version (for e.g. 1.21)"
  type        = string
  default     = "1.21.2"
}

variable "kubernetes_api_server_port" {
  description = "Kubernetes API server port"
  type        = number
  default     = 443 
}

variable "kubernetes_pod_subnet_cidr" {
  description = "CIDR for Kubernetes pods"
  type        = string
  default     = "2001:db8:1234:5678:8:2::/64"
}

variable "kubernetes_service_subnet_cidr" {
  description = "CIDR for Kubernetes services"
  type        = string
  default     = "2001:db8:1234:5678:8:3::/112"
}

variable "ipv4_vpc_cidr" {
  description = "IPv4 CIDR of the VPC"
  type        = string
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

variable "api_access_ipv4_cidr" {
  description = "List of IPv4 CIDRs from which API access is allowed"
  type        = list(string)
  default = [
    "0.0.0.0/0"
  ]
}

variable "api_access_ipv6_cidr" {
  description = "List of IPv6 CIDRs from which API access is allowed"
  type        = list(string)
  default = [
    "::/0"
  ]
}

variable "nat64_instance_type" {
  description = "Type of instance for NAT64-DNS64 node"
  default     = "t3.small"
}

variable "master_instance_type" {
  description = "Type of instance for master node"
  default     = "t3.medium"
}

variable "worker_instance_type" {
  description = "Type of instance for worker nodes"
  default     = "t3.medium"
}

variable "min_worker_count" {
  description = "Minimal number of worker nodes"
}

variable "max_worker_count" {
  description = "Maximal number of worker nodes"
}

variable "ssh_public_key" {
  description = "Path to the pulic part of SSH key which should be used for the instance"
  default     = "~/.ssh/id_rsa.pub"
}

variable "hosted_zone" {
  description = "Hosted zone to be used for the alias"
}

variable "hosted_zone_private" {
  description = "Is the hosted zone public or private"
  default     = false
}

variable "s3_bootstrap_user_data_bucket" {
  description = "S3 bucket where the bootstrap configuration is hosted"
  type        = string
  default     = "kubernetes-bootstrap-user-data"
}

variable "tags" {
  description = "Tags used for the AWS resources"
  type        = map(string)
}

variable "tags2" {
  description = "Tags in format used for the AWS Autoscaling Group"
  type        = list(object({key = string, value = string, propagate_at_launch = bool}))
}