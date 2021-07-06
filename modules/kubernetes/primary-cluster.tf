module "primary_nat64_instance" {
  source                    = "../nat64"

  instance_name             = format("%v-primary", var.project_name)
  vpc_id                    = element(aws_vpc.primary_vpc.*.id, 0)
  subnet_id                 = element(aws_subnet.primary_public_subnet.*.id, 0)
  instance_type             = var.nat64_instance_type
  ssh_key_name              = aws_key_pair.ssh_keypair.key_name
  master_security_group_id  = aws_security_group.primary_master_security_group.id
  workers_security_group_id = aws_security_group.primary_workers_security_group.id
  nat64_ipv6_cidr           = local.nat64_ipv6_cidr_pool
  vpc_ipv6_cidr             = aws_vpc.primary_vpc.ipv6_cidr_block
  tags                      = var.tags
}

# ==================================================
# VPC
# ==================================================
# ==================================================

resource "aws_vpc" "primary_vpc" {
  cidr_block                        = "${var.ipv4_vpc_cidr}"
  enable_dns_support                = true
  enable_dns_hostnames              = false
  assign_generated_ipv6_cidr_block  = true

  tags                              = merge(
    {
      "Name"          = format("%v-primary-vpc", var.project_name)
      "cluster"       = var.primary_cluster_name
    },
    var.tags
  )
}

resource "aws_internet_gateway" "primary_igw" {
  vpc_id              = aws_vpc.primary_vpc.id

  tags                = merge(
    {
      "Name"          = format("%v-primary-igw", var.project_name)
      "cluster"       = var.primary_cluster_name
    },
    var.tags
  )
}

# ==================================================
# Subnets
# ==================================================
# ==================================================

## -------------------------------------------------
## Primary cluster subnet
## -------------------------------------------------
resource "aws_subnet" "primary_public_subnet" {
  count                           = "${length(var.aws_zones)}"
  vpc_id                          = aws_vpc.primary_vpc.id
  cidr_block                      = "${cidrsubnet(var.ipv4_vpc_cidr, 8, count.index)}"
  ipv6_cidr_block                 = "${cidrsubnet(aws_vpc.primary_vpc.ipv6_cidr_block, 8, count.index)}"
  availability_zone               = "${var.aws_zones[count.index]}"
  map_public_ip_on_launch         = true
  assign_ipv6_address_on_creation = true

  tags                    = merge(
    {
      "Name"                                                        = format("%v-primary-public-%v", var.project_name, var.aws_zones[count.index])
      format("kubernetes.io/cluster/%v", var.primary_cluster_name)  = "owned"
      "kubernetes.io/role/elb"                                      = "1"
      "cluster"                                                     = var.primary_cluster_name
    },
    var.tags
  )
}

# ==================================================
# Routing
# ==================================================
# ==================================================

## -------------------------------------------------
## Primary cluster route
## -------------------------------------------------
resource "aws_route_table" "primary_route" {
  vpc_id = aws_vpc.primary_vpc.id

  # Default routes through Internet Gateway
  route {
    cidr_block      = "0.0.0.0/0"
    gateway_id      = aws_internet_gateway.primary_igw.id
  }
  route {
    ipv6_cidr_block = "::/0"
    gateway_id      = aws_internet_gateway.primary_igw.id
  }

  tags = merge(
    {
      "Name"       = format("%v-primary-route", var.project_name)
      "cluster"    = var.primary_cluster_name
    },
    var.tags
  )
}

resource "aws_route" "primary_route_nat64_instance" {
  route_table_id                = aws_route_table.primary_route.id
  destination_ipv6_cidr_block   = "${local.nat64_ipv6_cidr_pool}"
  instance_id                   = module.primary_nat64_instance.instance_id
  depends_on                    = [aws_route_table.primary_route, module.primary_nat64_instance]
}

resource "aws_route_table_association" "primary_route_primary_subnet_assoc" {
  count           = "${length(var.aws_zones)}"
  route_table_id  = aws_route_table.primary_route.id
  subnet_id       = element(aws_subnet.primary_public_subnet.*.id, count.index)
}

# ==================================================
# IAM roles
# ==================================================
# ==================================================

## -------------------------------------------------
## Master node
## -------------------------------------------------
data "template_file" "primary_master_policy_json" {
  template  = file("${path.module}/templates/master-policy.json.tpl")
}

resource "aws_iam_policy" "primary_master_policy" {
  name        = "${var.project_name}-primary-master-iam-policy"
  path        = "/"
  description = "Policy for role ${var.project_name}-primary-master"
  policy      = data.template_file.primary_master_policy_json.rendered
}

resource "aws_iam_role" "primary_master_role" {
  name = "${var.project_name}-primary-master"

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

resource "aws_iam_policy_attachment" "primary_master_policy_attachment" {
  name        = "${var.project_name}-primary-master-policy-attachment"
  roles       = [aws_iam_role.primary_master_role.name]
  policy_arn  = aws_iam_policy.primary_master_policy.arn
}

resource "aws_iam_policy_attachment" "primary_master_user_data_policy_attachment" {
  name        = "${var.project_name}-primary-master-user-data-policy-attachment"
  roles       = [aws_iam_role.primary_master_role.name]
  policy_arn  = aws_iam_policy.user_data_bucket_policy.arn
}

resource "aws_iam_instance_profile" "primary_master_profile" {
  name = "${var.project_name}-primary-master-instance-profile"
  role = aws_iam_role.primary_master_role.name
}

## -------------------------------------------------
## Worker node
## -------------------------------------------------
data "template_file" "primary_worker_policy_json" {
  template  = file("${path.module}/templates/worker-policy.json.tpl")
}

resource "aws_iam_policy" "primary_worker_policy" {
  name        = "${var.project_name}-primary-worker-iam-policy"
  path        = "/"
  description = "Policy for role ${var.project_name}-primary-worker"
  policy      = data.template_file.primary_worker_policy_json.rendered
}

resource "aws_iam_role" "primary_worker_role" {
  name = "${var.project_name}-worker"

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

resource "aws_iam_policy_attachment" "primary_worker_policy_attachment" {
  name       = "${var.project_name}-primary-worker-policy-attachment"
  roles      = [aws_iam_role.primary_worker_role.name]
  policy_arn = aws_iam_policy.primary_worker_policy.arn
}

resource "aws_iam_policy_attachment" "primary_worker_user_data_policy_attachment" {
  name        = "${var.project_name}-primary-worker-user-data-policy-attachment"
  roles       = [aws_iam_role.primary_worker_role.name]
  policy_arn  = aws_iam_policy.user_data_bucket_policy.arn
}

resource "aws_iam_instance_profile" "primary_worker_profile" {
  name = "${var.project_name}-primary-worker-instance-profile"
  role = aws_iam_role.primary_worker_role.name
}

# ==================================================
# Security Group
# ==================================================
# ==================================================

## -------------------------------------------------
## Master security group
## -------------------------------------------------
resource "aws_security_group" "primary_master_security_group" {
  vpc_id = aws_vpc.primary_vpc.id
  name   = "${var.project_name}-primary-master"

  tags = merge(
    {
      "Name"                                                        = format("%v-primary-master", var.project_name)
      format("kubernetes.io/cluster/%v", var.primary_cluster_name)  = "owned"
      "cluster"                                                     = var.primary_cluster_name
    },
    var.tags,
  )
}

## Allow egress traffic
resource "aws_security_group_rule" "primary_master_allow_all_ipv4_outbound" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.primary_master_security_group.id
}
resource "aws_security_group_rule" "primary_master_allow_all_ipv6_outbound" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  ipv6_cidr_blocks  = ["::/0"]
  security_group_id = aws_security_group.primary_master_security_group.id
}

## Allow the security group members to talk with each other without restrictions
resource "aws_security_group_rule" "primary_master_allow_cluster_crosstalk" {
  type                     = "ingress"
  from_port                = 0
  to_port                  = 0
  protocol                 = "-1"
  source_security_group_id = aws_security_group.primary_master_security_group.id
  security_group_id        = aws_security_group.primary_master_security_group.id
}

## Allow SSH connections
resource "aws_security_group_rule" "primary_master_allow_ssh_from_ipv4_cidr" {
  count             = length(var.ssh_access_ipv4_cidr)
  type              = "ingress"
  from_port         = 22
  to_port           = 22
  protocol          = "tcp"
  cidr_blocks       = [var.ssh_access_ipv4_cidr[count.index]]
  security_group_id = aws_security_group.primary_master_security_group.id
}
resource "aws_security_group_rule" "primary_master_allow_ssh_from_ipv6_cidr" {
  count             = length(var.ssh_access_ipv6_cidr)
  type              = "ingress"
  from_port         = 22
  to_port           = 22
  protocol          = "tcp"
  ipv6_cidr_blocks  = [var.ssh_access_ipv6_cidr[count.index]]
  security_group_id = aws_security_group.primary_master_security_group.id
}

## Allow API connections
resource "aws_security_group_rule" "primary_master_allow_api_from_ipv4_cidr" {
  count             = length(var.api_access_ipv4_cidr)
  type              = "ingress"
  from_port         = var.kubernetes_api_server_port
  to_port           = var.kubernetes_api_server_port
  protocol          = "tcp"
  cidr_blocks       = [var.api_access_ipv4_cidr[count.index]]
  security_group_id = aws_security_group.primary_master_security_group.id
}
resource "aws_security_group_rule" "primary_master_allow_api_from_ipv6_cidr" {
  count             = length(var.api_access_ipv6_cidr)
  type              = "ingress"
  from_port         = var.kubernetes_api_server_port
  to_port           = var.kubernetes_api_server_port
  protocol          = "tcp"
  ipv6_cidr_blocks  = [var.api_access_ipv6_cidr[count.index]]
  security_group_id = aws_security_group.primary_master_security_group.id
}

## -------------------------------------------------
## Workers security group
## -------------------------------------------------
resource "aws_security_group" "primary_workers_security_group" {
  vpc_id = aws_vpc.primary_vpc.id
  name   = "${var.project_name}-primary-workers"

  tags = merge(
    {
      "Name"                                                        = format("%v-primary-workers", var.project_name)
      format("kubernetes.io/cluster/%v", var.primary_cluster_name)  = "owned"
      "cluster"                                                     = var.primary_cluster_name
    },
    var.tags,
  )
}

## Allow all egress traffic
resource "aws_security_group_rule" "primary_workers_allow_all_ipv4_outbound" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.primary_workers_security_group.id
}
resource "aws_security_group_rule" "primary_workers_allow_all_ipv6_outbound" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  ipv6_cidr_blocks  = ["::/0"]
  security_group_id = aws_security_group.primary_workers_security_group.id
}

## Allow the security group members to communicate with each other without restrictions
resource "aws_security_group_rule" "primary_workers_allow_cluster_crosstalk" {
  type                     = "ingress"
  from_port                = 0
  to_port                  = 0
  protocol                 = "-1"
  source_security_group_id = aws_security_group.primary_workers_security_group.id
  security_group_id        = aws_security_group.primary_workers_security_group.id
}

## Allow the security group members to communicate with the outside world
resource "aws_security_group_rule" "primary_workers_allow_node_ports" {
  type                      = "ingress"
  from_port                 = 30000
  to_port                   = 32767
  protocol                  = "tcp"
  cidr_blocks               = ["0.0.0.0/0"]
  ipv6_cidr_blocks          = ["::/0"]
  security_group_id         = aws_security_group.primary_workers_security_group.id
}

## Allow SSH connections
resource "aws_security_group_rule" "primary_workers_allow_ssh_from_ipv4_cidr" {
  count             = length(var.ssh_access_ipv4_cidr)
  type              = "ingress"
  from_port         = 22
  to_port           = 22
  protocol          = "tcp"
  cidr_blocks       = [var.ssh_access_ipv4_cidr[count.index]]
  security_group_id = aws_security_group.primary_workers_security_group.id
}
resource "aws_security_group_rule" "primary_workers_allow_ssh_from_ipv6_cidr" {
  count             = length(var.ssh_access_ipv6_cidr)
  type              = "ingress"
  from_port         = 22
  to_port           = 22
  protocol          = "tcp"
  ipv6_cidr_blocks  = [var.ssh_access_ipv6_cidr[count.index]]
  security_group_id = aws_security_group.primary_workers_security_group.id
}

## -------------------------------------------------
## Master-Worker nodes association
## -------------------------------------------------
resource "aws_security_group_rule" "primary_workers_allow_master_ipip_traffic" {
  type                     = "ingress"
  from_port                = 0
  to_port                  = 0
  protocol                 = "94"
  source_security_group_id = aws_security_group.primary_master_security_group.id
  security_group_id        = aws_security_group.primary_workers_security_group.id
}
resource "aws_security_group_rule" "primary_workers_allow_master_ip4_encap_traffic" {
  type                     = "ingress"
  from_port                = 0
  to_port                  = 0
  protocol                 = "4"
  source_security_group_id = aws_security_group.primary_master_security_group.id
  security_group_id        = aws_security_group.primary_workers_security_group.id
}
resource "aws_security_group_rule" "primary_workers_allow_master_etcd_traffic" {
  type                     = "ingress"
  from_port                = 2379
  to_port                  = 2380
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.primary_master_security_group.id
  security_group_id        = aws_security_group.primary_workers_security_group.id
}
resource "aws_security_group_rule" "primary_workers_allow_master_calico_bgp_traffic" {
  type                     = "ingress"
  from_port                = 179
  to_port                  = 179
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.primary_master_security_group.id
  security_group_id        = aws_security_group.primary_workers_security_group.id
}
resource "aws_security_group_rule" "primary_workers_allow_master_kubelet_healthcheck_traffic" {
  type                     = "ingress"
  from_port                = 10250
  to_port                  = 10250
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.primary_master_security_group.id
  security_group_id        = aws_security_group.primary_workers_security_group.id
}
resource "aws_security_group_rule" "primary_master_allow_worker_api_server_traffic" {
  type                     = "ingress"
  from_port                = var.kubernetes_api_server_port
  to_port                  = var.kubernetes_api_server_port
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.primary_workers_security_group.id
  security_group_id        = aws_security_group.primary_master_security_group.id
}

# ==================================================
# Bootstraping configuration
# ==================================================
# ==================================================

## -------------------------------------------------
## Generates kubeadm token
## -------------------------------------------------

data "template_file" "primary_kubeadm_token" {
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

data "template_file" "primary_master_node_bootstrap_script" {
  template                      = file("${path.module}/scripts/bootstrap-kubernetes-master-node.sh")

  vars = {
    aws_region                  = var.aws_region
    kubeadm_token               = data.template_file.primary_kubeadm_token.rendered
    dns_name                    = "${var.primary_cluster_name}.${var.hosted_zone}"
    cluster_name                = var.primary_cluster_name
    kubernetes_version          = var.kubernetes_version
    kubernetes_api_server_port  = var.kubernetes_api_server_port
    pod_subnet_cidr             = var.kubernetes_pod_subnet_cidr
    service_subnet_cidr         = var.kubernetes_service_subnet_cidr
    dns64_host_ip               = module.primary_nat64_instance.ipv6_address

    # Addons related
    asg_name                    = "${var.primary_cluster_name}-nodes"
    asg_min_nodes               = var.min_worker_count
    asg_max_nodes               = var.max_worker_count
  }

  depends_on                    = [module.primary_nat64_instance]
}

data "template_file" "primary_worker_node_bootstrap_script" {
  template                      = file("${path.module}/scripts/bootstrap-kubernetes-worker-node.sh")

  vars = {
    aws_region                  = var.aws_region
    kubernetes_version          = var.kubernetes_version
    kubernetes_api_server_port  = var.kubernetes_api_server_port
    kubeadm_token               = data.template_file.primary_kubeadm_token.rendered
    master_ip                   = element(aws_instance.primary_master_node.ipv6_addresses, 0)
    dns_name                    = "${var.primary_cluster_name}.${var.hosted_zone}"
    dns64_host_ip               = module.primary_nat64_instance.ipv6_address
  }
}

## Using a S3 bucket to get around the 16k user data limitation in EC2
resource "aws_s3_bucket_object" "master_kubernetes_calico_user_data" {
  bucket  = aws_s3_bucket.user_data_bucket.id
  key     = "master-kubernetes-calico-encoded.enc"
  content = base64gzip(file("${path.module}/scripts/calico.yaml"))
  etag    = "${md5(base64gzip(file("${path.module}/scripts/calico.yaml")))}"
}

resource "aws_s3_bucket_object" "primary_master_kubernetes_bootstrap_script_user_data" {
  bucket  = aws_s3_bucket.user_data_bucket.id
  key     = "primary-master-kubernetes-bootstrap-script.enc"
  content = base64gzip(data.template_file.primary_master_node_bootstrap_script.rendered)
  etag    = "${md5(base64gzip(data.template_file.primary_master_node_bootstrap_script.rendered))}"
}
data "template_file" "load_primary_master_bootstrap_data" {
  template  = file("${path.module}/scripts/load-primary-master-bootstrap-data.sh")

  vars = {
    s3_bootstrap_user_data_bucket = var.s3_bootstrap_user_data_bucket
  }
}
data "template_cloudinit_config" "load_primary_master_bootstrap_data_cloud_init" {
  gzip            = true
  base64_encode   = true

  part {
    filename      = "load-master-bootstrap-data.sh"
    content_type  = "text/x-shellscript"
    content       = data.template_file.load_primary_master_bootstrap_data.rendered
  }
}

resource "aws_s3_bucket_object" "primary_worker_kubernetes_bootstrap_script_user_data" {
  bucket = aws_s3_bucket.user_data_bucket.id
  key = "primary-worker-kubernetes-bootstrap-script.enc"
  content = base64gzip(data.template_file.primary_worker_node_bootstrap_script.rendered)
  etag = "${md5(base64gzip(data.template_file.primary_worker_node_bootstrap_script.rendered))}"
}
data "template_file" "load_primary_worker_bootstrap_data" {
  template  = file("${path.module}/scripts/load-primary-worker-bootstrap-data.sh")

  vars = {
    s3_bootstrap_user_data_bucket = var.s3_bootstrap_user_data_bucket
  }
}
data "template_cloudinit_config" "load_primary_worker_bootstrap_data_cloud_init" {
  gzip            = true
  base64_encode   = true

  part {
    filename      = "load-worker-bootstrap-data.sh"
    content_type  = "text/x-shellscript"
    content       = data.template_file.load_primary_worker_bootstrap_data.rendered
  }
}

resource "aws_s3_bucket_object" "primary_addons" {
  for_each  = fileset("${path.module}/addons", "**/*")
  bucket    = aws_s3_bucket.user_data_bucket.id
  key       = "addons/${each.value}.enc"
  content   = base64gzip(file("${path.module}/addons/${each.value}"))
  etag      = md5(base64gzip(file("${path.module}/addons/${each.value}")))
}

# ==================================================
# EC2 instances
# ==================================================
# ==================================================

## -------------------------------------------------
## Master node (Primary)
## -------------------------------------------------
resource "aws_instance" "primary_master_node" {
  instance_type               = var.master_instance_type
  ami                         = data.aws_ami.ubuntu_20_04.id
  key_name                    = aws_key_pair.ssh_keypair.key_name
  subnet_id                   = element(aws_subnet.primary_public_subnet.*.id, 0)
  ipv6_addresses              = [cidrhost(element(aws_subnet.primary_public_subnet.*.ipv6_cidr_block, 0), 100)]
  associate_public_ip_address = true
  source_dest_check           = false

  vpc_security_group_ids = [
    aws_security_group.primary_master_security_group.id
  ]

  iam_instance_profile        = aws_iam_instance_profile.primary_master_profile.name

  user_data                   = data.template_cloudinit_config.load_primary_master_bootstrap_data_cloud_init.rendered

  tags = merge(
    {
      "Name"                                                        = format("%v-primary-master-node", var.project_name)
      format("kubernetes.io/cluster/%v", var.primary_cluster_name)  = "owned"
      "cluster"                                                     = var.primary_cluster_name
    },
    var.tags
  )

  root_block_device {
    volume_type           = "gp2"
    volume_size           = "50"
    delete_on_termination = true
  }

  lifecycle {
    create_before_destroy = true
    ignore_changes = [
      ami,
      associate_public_ip_address,
    ]
  }

  depends_on = [aws_s3_bucket.user_data_bucket]
}

## -------------------------------------------------
## Worker nodes (Primary)
## -------------------------------------------------
resource "aws_launch_template" "primary_worker_nodes" {
  name_prefix   = format("%v-primary-worker-nodes-", var.project_name)
  image_id      = data.aws_ami.ubuntu_20_04.id
  instance_type = var.worker_instance_type
  key_name      = aws_key_pair.ssh_keypair.key_name

  iam_instance_profile {
    name = aws_iam_instance_profile.primary_worker_profile.name
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
    subnet_id                   = "${element(aws_subnet.primary_public_subnet.*.id, 0)}"

    security_groups = [
      aws_security_group.primary_workers_security_group.id
    ]

    delete_on_termination       = true
  }

  user_data                   = data.template_cloudinit_config.load_primary_worker_bootstrap_data_cloud_init.rendered

  tags = merge(
    {
      "Name"                                                        = format("%v-primary-worker-nodes", var.project_name)
      format("kubernetes.io/cluster/%v", var.primary_cluster_name)  = "owned"
      "cluster"                                                     = var.primary_cluster_name
    },
    var.tags
  )

  lifecycle {
    create_before_destroy = true
    ignore_changes        = [user_data]
  }
}

resource "aws_autoscaling_group" "primary_worker_nodes" {
  vpc_zone_identifier   = aws_subnet.primary_public_subnet.*.id

  name                  = format("%v-primary-worker-nodes", var.project_name)
  max_size              = var.max_worker_count
  min_size              = var.min_worker_count
  desired_capacity      = var.min_worker_count

  launch_template {
    id      = aws_launch_template.primary_worker_nodes.id
    version = aws_launch_template.primary_worker_nodes.latest_version
  }

  tags = concat(
    [{
      key                 = "kubernetes.io/cluster/${var.primary_cluster_name}"
      value               = "owned"
      propagate_at_launch = true
    },
    {
      key                 = "Name"
      value               = format("%v-primary-worker-nodes", var.project_name)
      propagate_at_launch = true
    },
    {
      key                 = "cluster"
      value               = var.primary_cluster_name
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

resource "aws_route53_zone" "primary_sub_dns_zone" {
  name = "${var.primary_cluster_name}.${var.hosted_zone}"
}

resource "aws_route53_record" "primary_master_ns_main_record" {
  zone_id         = data.aws_route53_zone.main_dns_zone.zone_id
  name            = "${var.primary_cluster_name}.${var.hosted_zone}"
  allow_overwrite = true
  type            = "NS"
  ttl             = 300

  records         = [
    aws_route53_zone.primary_sub_dns_zone.name_servers[0],
    aws_route53_zone.primary_sub_dns_zone.name_servers[1],
    aws_route53_zone.primary_sub_dns_zone.name_servers[2],
    aws_route53_zone.primary_sub_dns_zone.name_servers[3],
  ]
}

resource "aws_route53_record" "primary_master_ns_sub_record" {
  zone_id         = aws_route53_zone.primary_sub_dns_zone.zone_id
  name            = "${var.primary_cluster_name}.${var.hosted_zone}"
  allow_overwrite = true
  type            = "NS"
  ttl             = 300

  records         = [
    aws_route53_zone.primary_sub_dns_zone.name_servers[0],
    aws_route53_zone.primary_sub_dns_zone.name_servers[1],
    aws_route53_zone.primary_sub_dns_zone.name_servers[2],
    aws_route53_zone.primary_sub_dns_zone.name_servers[3],
  ]
}

resource "aws_route53_record" "primary_master_aaaa_record" {
  zone_id         = aws_route53_zone.primary_sub_dns_zone.zone_id
  name            = "${var.primary_cluster_name}.${var.hosted_zone}"
  allow_overwrite = true
  type            = "AAAA"
  ttl             = 300

  records         = [element(aws_instance.primary_master_node.ipv6_addresses, 0)]
}