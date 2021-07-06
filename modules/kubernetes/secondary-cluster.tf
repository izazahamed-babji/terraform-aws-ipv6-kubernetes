module "secondary_nat64_instance" {
  source                    = "../nat64"

  instance_name             = format("%v-secondary", var.project_name)
  vpc_id                    = element(aws_vpc.secondary_vpc.*.id, 0)
  subnet_id                 = element(aws_subnet.secondary_public_subnet.*.id, 0)
  instance_type             = var.nat64_instance_type
  ssh_key_name              = aws_key_pair.ssh_keypair.key_name
  master_security_group_id  = element(aws_security_group.secondary_master_security_group.*.id, 0)
  workers_security_group_id = element(aws_security_group.secondary_workers_security_group.*.id, 0)
  nat64_ipv6_cidr           = local.nat64_ipv6_cidr_pool
  vpc_ipv6_cidr             = element(aws_vpc.secondary_vpc.*.ipv6_cidr_block, 0)
  tags                      = var.tags
}

# ==================================================
# VPC
# ==================================================
# ==================================================

resource "aws_vpc" "secondary_vpc" {
  count                             = var.enable_secondary_cluster ? 1 : 0
  cidr_block                        = "${var.ipv4_vpc_cidr}"
  enable_dns_support                = true
  enable_dns_hostnames              = false
  assign_generated_ipv6_cidr_block  = true

  tags                              = merge(
    {
      "Name"                        = format("%v-secondary-vpc", var.project_name)
      "cluster"                     = var.secondary_cluster_name
    },
    var.tags
  )
}

resource "aws_internet_gateway" "secondary_igw" {
  count                 = var.enable_secondary_cluster ? 1 : 0
  vpc_id                = element(aws_vpc.secondary_vpc.*.id, 0)

  tags                  = merge(
    {
      "Name"            = format("%v-secondary-igw", var.project_name)
      "cluster"         = var.secondary_cluster_name
    },
    var.tags
  )
}

# ==================================================
# Subnets
# ==================================================
# ==================================================

resource "aws_subnet" "secondary_public_subnet" {
  count                           = "${var.enable_secondary_cluster ? "${length(var.aws_zones)}" : 0}"
  vpc_id                          = element(aws_vpc.secondary_vpc.*.id, 0)
  cidr_block                      = "${cidrsubnet(var.ipv4_vpc_cidr, 8, count.index)}"
  ipv6_cidr_block                 = "${cidrsubnet(element(aws_vpc.secondary_vpc.*.ipv6_cidr_block, 0), 8, count.index)}"
  availability_zone               = "${var.aws_zones[count.index]}"
  map_public_ip_on_launch         = true
  assign_ipv6_address_on_creation = true

  tags                    = merge(
    {
      "Name"                                                          = format("%v-secondary-public-%v", var.project_name, var.aws_zones[count.index])
      format("kubernetes.io/cluster/%v", var.secondary_cluster_name)  = "owned"
      "kubernetes.io/role/elb"                                        = "1"
      "cluster"                                                       = var.secondary_cluster_name
    },
    var.tags
  )
}

# ==================================================
# Routing
# ==================================================
# ==================================================

resource "aws_route_table" "secondary_route" {
  count   = "${var.enable_secondary_cluster ? 1 : 0}"
  vpc_id  = element(aws_vpc.secondary_vpc.*.id, 0)

  # Default routes through Internet Gateway
  route {
    cidr_block      = "0.0.0.0/0"
    gateway_id      = element(aws_internet_gateway.secondary_igw.*.id, 0)
  }
  route {
    ipv6_cidr_block = "::/0"
    gateway_id      = element(aws_internet_gateway.secondary_igw.*.id, 0)
  }

  tags = merge(
    {
      "Name"       = format("%v-secondary-route", var.project_name)
      "cluster"    = var.secondary_cluster_name
    },
    var.tags
  )
}

resource "aws_route" "secondary_route_nat64_instance" {
  count                         = "${var.enable_secondary_cluster ? length(var.aws_zones) : 0}"
  route_table_id                = element(aws_route_table.secondary_route.*.id, 0)
  destination_ipv6_cidr_block   = "${local.nat64_ipv6_cidr_pool}"
  instance_id                   = module.secondary_nat64_instance.instance_id
  depends_on                    = [aws_route_table.secondary_route, module.secondary_nat64_instance]
}

resource "aws_route_table_association" "secondary_route_secondary_subnet_assoc" {
  count           = "${var.enable_secondary_cluster ? length(var.aws_zones) : 0}"
  route_table_id  = element(aws_route_table.secondary_route.*.id, 0)
  subnet_id       = element(aws_subnet.secondary_public_subnet.*.id, count.index)
}

# ==================================================
# IAM roles
# ==================================================
# ==================================================

data "template_file" "secondary_master_policy_json" {
  template  = file("${path.module}/templates/master-policy.json.tpl")
}

resource "aws_iam_policy" "secondary_master_policy" {
  count       = "${var.enable_secondary_cluster ? 1 : 0}"
  name        = "${var.project_name}-secondary-master-iam-policy"
  path        = "/"
  description = "Policy for role ${var.project_name}-secondary-master"
  policy      = data.template_file.secondary_master_policy_json.rendered
}

resource "aws_iam_role" "secondary_master_role" {
  count = "${var.enable_secondary_cluster ? 1 : 0}"
  name  = "${var.project_name}-secondary-master"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
EOF

}

resource "aws_iam_policy_attachment" "secondary_master_policy_attachment" {
  count       = "${var.enable_secondary_cluster ? 1 : 0}"
  name        = "${var.project_name}-secondary-master-policy-attachment"
  roles       = [element(aws_iam_role.secondary_master_role.*.name, 0)]
  policy_arn  = element(aws_iam_policy.secondary_master_policy.*.arn, 0)
}

resource "aws_iam_policy_attachment" "secondary_master_user_data_policy_attachment" {
  count       = "${var.enable_secondary_cluster ? 1 : 0}"
  name        = "${var.project_name}-secondary-master-user-data-policy-attachment"
  roles       = [element(aws_iam_role.secondary_master_role.*.name, 0)]
  policy_arn  = aws_iam_policy.user_data_bucket_policy.arn
}

resource "aws_iam_instance_profile" "secondary_master_profile" {
  count = "${var.enable_secondary_cluster ? 1 : 0}"
  name  = "${var.project_name}-secondary-master-instance-profile"
  role  = element(aws_iam_role.secondary_master_role.*.name, 0)
}

## -------------------------------------------------
## Worker node
## -------------------------------------------------
data "template_file" "secondary_worker_policy_json" {
  template  = file("${path.module}/templates/worker-policy.json.tpl")
}

resource "aws_iam_policy" "secondary_worker_policy" {
  count       = "${var.enable_secondary_cluster ? 1 : 0}"
  name        = "${var.project_name}-secondary-worker-iam-policy"
  path        = "/"
  description = "Policy for role ${var.project_name}-secondary-worker"
  policy      = data.template_file.secondary_worker_policy_json.rendered
}

resource "aws_iam_role" "secondary_worker_role" {
  count = "${var.enable_secondary_cluster ? 1 : 0}"
  name  = "${var.project_name}-secondary-worker"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
EOF

}

resource "aws_iam_policy_attachment" "secondary_worker_policy_attachment" {
  count       = "${var.enable_secondary_cluster ? 1 : 0}"
  name        = "${var.project_name}-secondary-worker-policy-attachment"
  roles       = [element(aws_iam_role.secondary_worker_role.*.name, 0)]
  policy_arn  = element(aws_iam_policy.secondary_worker_policy.*.arn, 0)
}

resource "aws_iam_policy_attachment" "secondary_worker_user_data_policy_attachment" {
  count       = "${var.enable_secondary_cluster ? 1 : 0}"
  name        = "${var.project_name}-secondary-worker-user-data-policy-attachment"
  roles       = [element(aws_iam_role.secondary_worker_role.*.name, 0)]
  policy_arn  = aws_iam_policy.user_data_bucket_policy.arn
}

resource "aws_iam_instance_profile" "secondary_worker_profile" {
  count = "${var.enable_secondary_cluster ? 1 : 0}"
  name  = "${var.project_name}-secondary-worker-instance-profile"
  role  = element(aws_iam_role.secondary_worker_role.*.name, 0)
}

# ==================================================
# Security Group
# ==================================================
# ==================================================

## -------------------------------------------------
## Master security group
## -------------------------------------------------
resource "aws_security_group" "secondary_master_security_group" {
  count   = "${var.enable_secondary_cluster ? 1 : 0}"
  vpc_id  = element(aws_vpc.secondary_vpc.*.id, 0)
  name    = "${var.project_name}-secondary-master"

  tags    = merge(
    {
      "Name"                                                        = format("%v-master", var.project_name)
      format("kubernetes.io/cluster/%v", var.secondary_cluster_name)  = "owned"
      "cluster"                                                     = var.secondary_cluster_name
    },
    var.tags,
  )
}

## Allow egress traffic
resource "aws_security_group_rule" "secondary_master_allow_all_ipv4_outbound" {
  count             = "${var.enable_secondary_cluster ? 1 : 0}"
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = element(aws_security_group.secondary_master_security_group.*.id, 0)
}
resource "aws_security_group_rule" "secondary_master_allow_all_ipv6_outbound" {
  count             = "${var.enable_secondary_cluster ? 1 : 0}"
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  ipv6_cidr_blocks  = ["::/0"]
  security_group_id = element(aws_security_group.secondary_master_security_group.*.id, 0)
}

## Allow the security group members to talk with each other without restrictions
resource "aws_security_group_rule" "secondary_secondary_master_allow_cluster_crosstalk" {
  count                     = "${var.enable_secondary_cluster ? 1 : 0}"
  type                      = "ingress"
  from_port                 = 0
  to_port                   = 0
  protocol                  = "-1"
  source_security_group_id  = element(aws_security_group.secondary_master_security_group.*.id, 0)
  security_group_id         = element(aws_security_group.secondary_master_security_group.*.id, 0)
}

## Allow SSH connections
resource "aws_security_group_rule" "secondary_master_allow_ssh_from_ipv4_cidr" {
  count             = "${var.enable_secondary_cluster ? length(var.ssh_access_ipv4_cidr) : 0}"
  type              = "ingress"
  from_port         = 22
  to_port           = 22
  protocol          = "tcp"
  cidr_blocks       = [var.ssh_access_ipv4_cidr[count.index]]
  security_group_id = element(aws_security_group.secondary_master_security_group.*.id, 0)
}
resource "aws_security_group_rule" "secondary_master_allow_ssh_from_ipv6_cidr" {
  count             = "${var.enable_secondary_cluster ? length(var.ssh_access_ipv6_cidr) : 0}"
  type              = "ingress"
  from_port         = 22
  to_port           = 22
  protocol          = "tcp"
  ipv6_cidr_blocks  = [var.ssh_access_ipv6_cidr[count.index]]
  security_group_id = element(aws_security_group.secondary_master_security_group.*.id, 0)
}

## Allow API connections
resource "aws_security_group_rule" "secondary_master_security_groupmaster_allow_api_from_ipv4_cidr" {
  count             = "${var.enable_secondary_cluster ? length(var.api_access_ipv4_cidr) : 0}"
  type              = "ingress"
  from_port         = var.kubernetes_api_server_port
  to_port           = var.kubernetes_api_server_port
  protocol          = "tcp"
  cidr_blocks       = [var.api_access_ipv4_cidr[count.index]]
  security_group_id = element(aws_security_group.secondary_master_security_group.*.id, 0)
}
resource "aws_security_group_rule" "secondary_master_allow_api_from_ipv6_cidr" {
  count             = "${var.enable_secondary_cluster ? length(var.api_access_ipv6_cidr) : 0}"
  type              = "ingress"
  from_port         = var.kubernetes_api_server_port
  to_port           = var.kubernetes_api_server_port
  protocol          = "tcp"
  ipv6_cidr_blocks  = [var.api_access_ipv6_cidr[count.index]]
  security_group_id = element(aws_security_group.secondary_master_security_group.*.id, 0)
}

## -------------------------------------------------
## Workers security group
## -------------------------------------------------
resource "aws_security_group" "secondary_workers_security_group" {
  count   = "${var.enable_secondary_cluster ? 1 : 0}"
  vpc_id  = element(aws_vpc.secondary_vpc.*.id, 0)
  name    = "${var.project_name}-secondary-workers"

  tags    = merge(
    {
      "Name"                                                          = format("%v-secondary-workers", var.project_name)
      format("kubernetes.io/cluster/%v", var.secondary_cluster_name)  = "owned"
      "cluster"                                                       = var.secondary_cluster_name
    },
    var.tags
  )
}

## Allow all egress traffic
resource "aws_security_group_rule" "secondary_workers_allow_all_ipv4_outbound" {
  count             = "${var.enable_secondary_cluster ? 1 : 0}"
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = element(aws_security_group.secondary_workers_security_group.*.id, 0)
}
resource "aws_security_group_rule" "secondary_workers_allow_all_ipv6_outbound" {
  count             = "${var.enable_secondary_cluster ? 1 : 0}"
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  ipv6_cidr_blocks  = ["::/0"]
  security_group_id = element(aws_security_group.secondary_workers_security_group.*.id, 0)
}

## Allow the security group members to communicate with each other without restrictions
resource "aws_security_group_rule" "secondary_workers_allow_cluster_crosstalk" {
  count                     = "${var.enable_secondary_cluster ? 1 : 0}"
  type                      = "ingress"
  from_port                 = 0
  to_port                   = 0
  protocol                  = "-1"
  source_security_group_id  = element(aws_security_group.secondary_workers_security_group.*.id, 0)
  security_group_id         = element(aws_security_group.secondary_workers_security_group.*.id, 0)
}

## Allow the security group members to communicate with the outside world
resource "aws_security_group_rule" "secondary_workers_allow_node_ports" {
  count             = "${var.enable_secondary_cluster ? 1 : 0}"
  type              = "ingress"
  from_port         = 30000
  to_port           = 32767
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  ipv6_cidr_blocks  = ["::/0"]
  security_group_id = element(aws_security_group.secondary_workers_security_group.*.id, 0)
}

## Allow SSH connections
resource "aws_security_group_rule" "secondary_workers_allow_ssh_from_ipv4_cidr" {
  count             = "${var.enable_secondary_cluster ? length(var.ssh_access_ipv4_cidr) : 0}"
  type              = "ingress"
  from_port         = 22
  to_port           = 22
  protocol          = "tcp"
  cidr_blocks       = [var.ssh_access_ipv4_cidr[count.index]]
  security_group_id = element(aws_security_group.secondary_workers_security_group.*.id, 0)
}
resource "aws_security_group_rule" "secondary_workers_allow_ssh_from_ipv6_cidr" {
  count             = "${var.enable_secondary_cluster ? length(var.ssh_access_ipv6_cidr) : 0}"
  type              = "ingress"
  from_port         = 22
  to_port           = 22
  protocol          = "tcp"
  ipv6_cidr_blocks  = [var.ssh_access_ipv6_cidr[count.index]]
  security_group_id = element(aws_security_group.secondary_workers_security_group.*.id, 0)
}

## -------------------------------------------------
## Master-Worker nodes association
## -------------------------------------------------
resource "aws_security_group_rule" "secondary_workers_allow_master_ipip_traffic" {
  count                     = "${var.enable_secondary_cluster ? 1 : 0}"
  type                      = "ingress"
  from_port                 = 0
  to_port                   = 0
  protocol                  = "94"
  source_security_group_id  = element(aws_security_group.secondary_master_security_group.*.id, 0)
  security_group_id         = element(aws_security_group.secondary_workers_security_group.*.id, 0)
}
resource "aws_security_group_rule" "secondary_workers_allow_master_ip4_encap_traffic" {
  count                     = "${var.enable_secondary_cluster ? 1 : 0}"
  type                      = "ingress"
  from_port                 = 0
  to_port                   = 0
  protocol                  = "4"
  source_security_group_id  = element(aws_security_group.secondary_master_security_group.*.id, 0)
  security_group_id         = element(aws_security_group.secondary_workers_security_group.*.id, 0)
}
resource "aws_security_group_rule" "secondary_workers_allow_master_etcd_traffic" {
  count                     = "${var.enable_secondary_cluster ? 1 : 0}"
  type                      = "ingress"
  from_port                 = 2379
  to_port                   = 2380
  protocol                  = "tcp"
  source_security_group_id  = element(aws_security_group.secondary_master_security_group.*.id, 0)
  security_group_id         = element(aws_security_group.secondary_workers_security_group.*.id, 0)
}
resource "aws_security_group_rule" "secondary_workers_allow_master_calico_bgp_traffic" {
  count                     = "${var.enable_secondary_cluster ? 1 : 0}"
  type                      = "ingress"
  from_port                 = 179
  to_port                   = 179
  protocol                  = "tcp"
  source_security_group_id  = element(aws_security_group.secondary_master_security_group.*.id, 0)
  security_group_id         = element(aws_security_group.secondary_workers_security_group.*.id, 0)
}
resource "aws_security_group_rule" "secondary_workers_allow_master_kubelet_healthcheck_traffic" {
  count                     = "${var.enable_secondary_cluster ? 1 : 0}"
  type                      = "ingress"
  from_port                 = 10250
  to_port                   = 10250
  protocol                  = "tcp"
  source_security_group_id  = element(aws_security_group.secondary_master_security_group.*.id, 0)
  security_group_id         = element(aws_security_group.secondary_workers_security_group.*.id, 0)
}
resource "aws_security_group_rule" "secondary_master_allow_worker_api_server_traffic" {
  type                     = "ingress"
  from_port                = var.kubernetes_api_server_port
  to_port                  = var.kubernetes_api_server_port
  protocol                 = "tcp"
  source_security_group_id = element(aws_security_group.secondary_workers_security_group.*.id, 0)
  security_group_id        = element(aws_security_group.secondary_master_security_group.*.id, 0)
}

# ==================================================
# Bootstraping configuration
# ==================================================
# ==================================================

data "template_file" "secondary_kubeadm_token" {
  template = file("${path.module}/templates/token.tpl")

  vars = {
    token1 = join("", random_shuffle.token1.result)
    token2 = join("", random_shuffle.token2.result)
  }

  depends_on = [
    random_shuffle.token1,
    random_shuffle.token1
  ]
}

data "template_file" "secondary_master_node_bootstrap_script" {
  template                      = file("${path.module}/scripts/bootstrap-kubernetes-master-node.sh")

  vars = {
    aws_region                  = var.aws_region
    kubeadm_token               = data.template_file.secondary_kubeadm_token.rendered
    dns_name                    = "${var.secondary_cluster_name}.${var.hosted_zone}"
    cluster_name                = var.secondary_cluster_name
    kubernetes_version          = var.kubernetes_version
    kubernetes_api_server_port  = var.kubernetes_api_server_port
    pod_subnet_cidr             = var.kubernetes_pod_subnet_cidr
    service_subnet_cidr         = var.kubernetes_service_subnet_cidr
    dns64_host_ip               = module.secondary_nat64_instance.ipv6_address

    # Addons related
    asg_name                    = "${var.secondary_cluster_name}-nodes"
    asg_min_nodes               = var.min_worker_count
    asg_max_nodes               = var.max_worker_count
  }

  depends_on                    = [module.secondary_nat64_instance]
}

data "template_file" "secondary_worker_node_bootstrap_script" {
  template                      = file("${path.module}/scripts/bootstrap-kubernetes-worker-node.sh")

  vars = {
    aws_region                  = var.aws_region
    kubernetes_version          = var.kubernetes_version
    kubernetes_api_server_port  = var.kubernetes_api_server_port
    kubeadm_token               = data.template_file.secondary_kubeadm_token.rendered
    master_ip                   = element(element(aws_instance.secondary_master_node.*.ipv6_addresses, 0), 0)
    dns_name                    = "${var.secondary_cluster_name}.${var.hosted_zone}"
    dns64_host_ip               = module.secondary_nat64_instance.ipv6_address
  }
}

resource "aws_s3_bucket_object" "secondary_master_kubernetes_bootstrap_script_user_data" {
  count   = "${var.enable_secondary_cluster ? 1 : 0}"
  bucket  = aws_s3_bucket.user_data_bucket.id
  key     = "secondary-master-kubernetes-bootstrap-script.enc"
  content = base64gzip(data.template_file.secondary_master_node_bootstrap_script.rendered)
  etag    = "${md5(base64gzip(data.template_file.secondary_master_node_bootstrap_script.rendered))}"
}
data "template_file" "load_secondary_master_bootstrap_data" {
  template  = file("${path.module}/scripts/load-secondary-master-bootstrap-data.sh")

  vars = {
    s3_bootstrap_user_data_bucket = var.s3_bootstrap_user_data_bucket
  }
}
data "template_cloudinit_config" "load_secondary_master_bootstrap_data_cloud_init" {
  gzip            = true
  base64_encode   = true

  part {
    filename      = "load-master-bootstrap-data.sh"
    content_type  = "text/x-shellscript"
    content       = data.template_file.load_secondary_master_bootstrap_data.rendered
  }
}

resource "aws_s3_bucket_object" "secondary_worker_kubernetes_bootstrap_script_user_data" {
  count   = "${var.enable_secondary_cluster ? 1 : 0}"
  bucket  = aws_s3_bucket.user_data_bucket.id
  key     = "secondary-worker-kubernetes-bootstrap-script.enc"
  content = base64gzip(data.template_file.secondary_worker_node_bootstrap_script.rendered)
  etag    = "${md5(base64gzip(data.template_file.secondary_worker_node_bootstrap_script.rendered))}"
}
data "template_file" "load_secondary_worker_bootstrap_data" {
  template  = file("${path.module}/scripts/load-secondary-worker-bootstrap-data.sh")

  vars = {
    s3_bootstrap_user_data_bucket = var.s3_bootstrap_user_data_bucket
  }
}
data "template_cloudinit_config" "load_secondary_worker_bootstrap_data_cloud_init" {
  gzip            = true
  base64_encode   = true

  part {
    filename      = "load-worker-bootstrap-data.sh"
    content_type  = "text/x-shellscript"
    content       = data.template_file.load_secondary_worker_bootstrap_data.rendered
  }
}


# ==================================================
# EC2 instance
# ==================================================
# ==================================================

## -------------------------------------------------
## Master node (Secondary)
## -------------------------------------------------
resource "aws_instance" "secondary_master_node" {
  count                       = "${var.enable_secondary_cluster ? 1 : 0}"
  instance_type               = var.master_instance_type
  ami                         = data.aws_ami.ubuntu_20_04.id
  key_name                    = aws_key_pair.ssh_keypair.key_name
  subnet_id                   = "${element(aws_subnet.secondary_public_subnet.*.id, 0)}"
  ipv6_addresses              = [cidrhost(element(aws_subnet.secondary_public_subnet.*.ipv6_cidr_block, 0), 100)]
  associate_public_ip_address = true
  source_dest_check           = false

  vpc_security_group_ids = [
    element(aws_security_group.secondary_master_security_group.*.id, 0)
  ]

  iam_instance_profile        = element(aws_iam_instance_profile.secondary_master_profile.*.name, 0)

  user_data                   = data.template_cloudinit_config.load_secondary_master_bootstrap_data_cloud_init.rendered

  tags = merge(
    {
      "Name"                                                          = format("%v-secondary-master-node", var.project_name)
      format("kubernetes.io/cluster/%v", var.secondary_cluster_name)  = "owned"
      "cluster"                                                       = var.secondary_cluster_name
    },
    var.tags
  )

  root_block_device {
    volume_type           = "gp2"
    volume_size           = "50"
    delete_on_termination = true
  }

  lifecycle {
    ignore_changes = [
      ami,
      associate_public_ip_address,
    ]
  }

  depends_on = [aws_s3_bucket.user_data_bucket]
}

## -------------------------------------------------
## Worker nodes (Secondary)
## -------------------------------------------------
resource "aws_launch_template" "secondary_worker_nodes" {
  count         = "${var.enable_secondary_cluster ? 1 : 0}"
  name_prefix   = format("%v-secondary-worker-nodes-", var.project_name)
  image_id      = data.aws_ami.ubuntu_20_04.id
  instance_type = var.worker_instance_type
  key_name      = aws_key_pair.ssh_keypair.key_name

  iam_instance_profile {
    name = element(aws_iam_instance_profile.secondary_worker_profile.*.name, 0)
  }

  block_device_mappings {
    device_name = "/dev/sda1"
    ebs {
        volume_type           = "gp2"
        volume_size           = "50"
        delete_on_termination = true
    }
  }

  network_interfaces {
    associate_public_ip_address = true
    subnet_id                   = "${element(aws_subnet.secondary_public_subnet.*.id, 0)}"

    security_groups = [
      element(aws_security_group.secondary_workers_security_group.*.id, 0)
    ]

    delete_on_termination       = true
  }

  user_data                   = data.template_cloudinit_config.load_secondary_worker_bootstrap_data_cloud_init.rendered

  tags = merge(
    {
      "Name"                                                          = format("%v-secondary-worker-nodes", var.project_name)
      format("kubernetes.io/cluster/%v", var.secondary_cluster_name)  = "owned"
      "cluster"                                                       = var.secondary_cluster_name
    },
    var.tags
  )

  lifecycle {
    create_before_destroy = true
    ignore_changes        = [user_data]
  }
}

resource "aws_autoscaling_group" "secondary_worker_nodes" {
  count                 = "${var.enable_secondary_cluster ? 1 : 0}"
  vpc_zone_identifier   = aws_subnet.secondary_public_subnet.*.id

  name                  = format("%v-secondary-worker-nodes", var.project_name)
  max_size              = var.max_worker_count
  min_size              = var.min_worker_count
  desired_capacity      = var.min_worker_count

  launch_template {
    id      = element(aws_launch_template.secondary_worker_nodes.*.id, 0)
    version = element(aws_launch_template.secondary_worker_nodes.*.latest_version, 0)
  }

  tags = concat(
    [{
      key                 = "kubernetes.io/cluster/${var.secondary_cluster_name}"
      value               = "owned"
      propagate_at_launch = true
    },
    {
      key                 = "Name"
      value               = format("%v-secondary-worker-nodes", var.project_name)
      propagate_at_launch = true
    },
    {
      key                 = "cluster"
      value               = var.secondary_cluster_name
      propagate_at_launch = true
    }],
    var.tags2
  )

  lifecycle {
    ignore_changes = [desired_capacity]
  }
}

# ==================================================
# # DNS record
# ==================================================
# ==================================================

resource "aws_route53_zone" "secondary_sub_dns_zone" {
  name = "${var.secondary_cluster_name}.${var.hosted_zone}"
}

resource "aws_route53_record" "secondary_master_ns_main_record" {
  zone_id         = data.aws_route53_zone.main_dns_zone.zone_id
  name            = "${var.secondary_cluster_name}.${var.hosted_zone}"
  allow_overwrite = true
  type            = "NS"
  ttl             = 300

  records         = [
    aws_route53_zone.secondary_sub_dns_zone.name_servers[0],
    aws_route53_zone.secondary_sub_dns_zone.name_servers[1],
    aws_route53_zone.secondary_sub_dns_zone.name_servers[2],
    aws_route53_zone.secondary_sub_dns_zone.name_servers[3],
  ]
}

resource "aws_route53_record" "secondary_master_ns_sub_record" {
  zone_id         = aws_route53_zone.secondary_sub_dns_zone.zone_id
  name            = "${var.secondary_cluster_name}.${var.hosted_zone}"
  allow_overwrite = true
  type            = "NS"
  ttl             = 300

  records         = [
    aws_route53_zone.secondary_sub_dns_zone.name_servers[0],
    aws_route53_zone.secondary_sub_dns_zone.name_servers[1],
    aws_route53_zone.secondary_sub_dns_zone.name_servers[2],
    aws_route53_zone.secondary_sub_dns_zone.name_servers[3],
  ]
}

resource "aws_route53_record" "secondary_master_aaaa_record" {
  zone_id         = aws_route53_zone.secondary_sub_dns_zone.zone_id
  name            = "${var.secondary_cluster_name}.${var.hosted_zone}"
  allow_overwrite = true
  type            = "AAAA"
  ttl             = 300

  records         = [element(element(aws_instance.secondary_master_node.*.ipv6_addresses, 0), 0)]
}