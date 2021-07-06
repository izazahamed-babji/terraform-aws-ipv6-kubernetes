module "aws_ipv6_kubernetes" {
  source                        = "./modules/kubernetes"

  project_name                  = "rakuten-test"
  aws_region                    = "ap-southeast-2"
  aws_zones                     = ["ap-southeast-2a", "ap-southeast-2b"]
  primary_cluster_name          = "rakuten-k8s-alpha"
  secondary_cluster_name        = "rakuten-k8s-beta"
  ipv4_vpc_cidr                 = "172.20.0.0/16"
  enable_secondary_cluster      = true
  min_worker_count              = 1
  max_worker_count              = 2
  hosted_zone                   = "gl00.net"
  hosted_zone_private           = false
  s3_bootstrap_user_data_bucket = "rakuten-test-bootstrap-user-data"
  ssh_public_key                = "~/.ssh/aws_id_rsa.pub"

  tags = {
    owner = "kasunt"
  }

  tags2 = [
    {
      key                 = "owner"
      value               = "kasunt"
      propagate_at_launch = true
    },
    {
      key                 = "application"
      value               = "kubernetes"
      propagate_at_launch = true
    }
  ]
}

output "primary_cluster_fqdn" {
  value = "${module.aws_ipv6_kubernetes.primary_cluster_fqdn}"
}

output "secondary_cluster_fqdn" {
  value = "${module.aws_ipv6_kubernetes.secondary_cluster_fqdn}"
}