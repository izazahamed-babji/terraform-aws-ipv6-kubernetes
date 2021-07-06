# ==================================================
# IAM roles
# ==================================================
# ==================================================

data "template_file" "nat64_policy_json" {
  template  = file("${path.module}/templates/nat64-policy.json.tpl")
}

resource "aws_iam_policy" "nat64_policy" {
  name        = "${var.instance_name}-nat64"
  path        = "/"
  description = "Policy for role ${var.instance_name}-nat64"
  policy      = data.template_file.nat64_policy_json.rendered
}

resource "aws_iam_role" "nat64_role" {
  name  = "${var.instance_name}-nat64"

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

resource "aws_iam_policy_attachment" "nat64_attach" {
  name        = "${var.instance_name}-nat64-attachment"
  roles       = [aws_iam_role.nat64_role.name]
  policy_arn  = aws_iam_policy.nat64_policy.arn
}

resource "aws_iam_instance_profile" "nat64_profile" {
  name  = "${var.instance_name}-nat64"
  role  = aws_iam_role.nat64_role.name
}

# ==================================================
# Security Group
# ==================================================
# ==================================================

resource "aws_security_group" "nat64_security_group" {
  name      = "${var.instance_name}-nat64"
  vpc_id    = var.vpc_id

  tags      = merge(
    {
      "Name"  = format("%v-nat64", var.instance_name)
    },
    var.tags,
  )
}

## Allow egress traffic
resource "aws_security_group_rule" "nat64_allow_all_ipv4_outbound" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.nat64_security_group.id
}
resource "aws_security_group_rule" "nat64_allow_all_ipv6_outbound" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  ipv6_cidr_blocks  = ["::/0"]
  security_group_id = aws_security_group.nat64_security_group.id
}

## Allow the security group members to talk with each other without restrictions
resource "aws_security_group_rule" "nat64_allow_cluster_crosstalk" {
  type                      = "ingress"
  from_port                 = 0
  to_port                   = 0
  protocol                  = "-1"
  source_security_group_id  = aws_security_group.nat64_security_group.id
  security_group_id         = aws_security_group.nat64_security_group.id
}

## Allow SSH connections
resource "aws_security_group_rule" "nat64_allow_ssh_from_ipv4_cidr" {
  count             = length(var.ssh_access_ipv4_cidr)
  type              = "ingress"
  from_port         = 22
  to_port           = 22
  protocol          = "tcp"
  cidr_blocks       = [var.ssh_access_ipv4_cidr[count.index]]
  security_group_id = aws_security_group.nat64_security_group.id
}
resource "aws_security_group_rule" "nat64_allow_ssh_from_ipv6_cidr" {
  count             = length(var.ssh_access_ipv6_cidr)
  type              = "ingress"
  from_port         = 22
  to_port           = 22
  protocol          = "tcp"
  ipv6_cidr_blocks  = [var.ssh_access_ipv6_cidr[count.index]]
  security_group_id = aws_security_group.nat64_security_group.id
}

## -------------------------------------------------
## NAT64-Master-Worker nodes association
## -------------------------------------------------
resource "aws_security_group_rule" "nat64_allow_icmpv6_from_master" {
  type                      = "ingress"
  from_port                 = -1
  to_port                   = -1
  protocol                  = "icmpv6"
  source_security_group_id  = var.master_security_group_id
  security_group_id         = aws_security_group.nat64_security_group.id
}
resource "aws_security_group_rule" "nat64_allow_icmpv6_from_secondary_master" {
  type                      = "ingress"
  from_port                 = -1
  to_port                   = -1
  protocol                  = "icmpv6"
  source_security_group_id  = var.workers_security_group_id
  security_group_id         = aws_security_group.nat64_security_group.id
}
resource "aws_security_group_rule" "nat64_allow_master_dns_tcp_traffic" {
  type                     = "ingress"
  from_port                = 53
  to_port                  = 53
  protocol                 = "tcp"
  source_security_group_id = var.master_security_group_id
  security_group_id        = aws_security_group.nat64_security_group.id
}
resource "aws_security_group_rule" "nat64_allow_master_dns_udp_traffic" {
  type                     = "ingress"
  from_port                = 53
  to_port                  = 53
  protocol                 = "udp"
  source_security_group_id = var.master_security_group_id
  security_group_id        = aws_security_group.nat64_security_group.id
}
resource "aws_security_group_rule" "nat64_allow_worker_dns_tcp_traffic" {
  type                     = "ingress"
  from_port                = 53
  to_port                  = 53
  protocol                 = "tcp"
  source_security_group_id = var.workers_security_group_id
  security_group_id        = aws_security_group.nat64_security_group.id
}
resource "aws_security_group_rule" "nat64_allow_worker_dns_udp_traffic" {
  type                     = "ingress"
  from_port                = 53
  to_port                  = 53
  protocol                 = "udp"
  source_security_group_id = var.workers_security_group_id
  security_group_id        = aws_security_group.nat64_security_group.id
}

# ==================================================
# AMI image
# ==================================================
# ==================================================

data "aws_ami" "ubuntu_20_04" {
  most_recent = true
  owners      = ["aws-marketplace"]

  filter {
    name   = "product-code"
    values = ["a8jyynf4hjutohctm41o2z18m"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ==================================================
# Bootstraping configuration
# ==================================================
# ==================================================

data "template_file" "nat64_node_bootstrap_script" {
  template  = file("${path.module}/scripts/bootstrap-nat64-node.sh")

  vars = {
    nat64_ipv6_cidr = var.nat64_ipv6_cidr
    vpc_ipv6_cidr   = var.vpc_ipv6_cidr
  }
}

data "template_cloudinit_config" "nat64_node_cloud_init" {
  gzip            = true
  base64_encode   = true

  part {
    filename      = "bootstrap-nat64-node.sh"
    content_type  = "text/x-shellscript"
    content       = data.template_file.nat64_node_bootstrap_script.rendered
  }
}

# ==================================================
# NAT64 EC2 instance
# ==================================================
# ==================================================

data "aws_subnet" "nat64_subnet" {
  id = var.subnet_id
}

resource "aws_instance" "nat64_node" {
  instance_type               = var.instance_type
  ami                         = data.aws_ami.ubuntu_20_04.id
  key_name                    = var.ssh_key_name
  subnet_id                   = var.subnet_id
  ipv6_addresses              = [cidrhost(element(data.aws_subnet.nat64_subnet.*.ipv6_cidr_block, 0), 200)]
  associate_public_ip_address = true
  source_dest_check           = false

  vpc_security_group_ids = [
    aws_security_group.nat64_security_group.id
  ]

  iam_instance_profile        = aws_iam_instance_profile.nat64_profile.name

  user_data_base64            = data.template_cloudinit_config.nat64_node_cloud_init.rendered

  tags = merge(
    {
      "Name"                  = format("%v-nat64-node", var.instance_name)
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
      user_data,
      associate_public_ip_address,
    ]
  }
}