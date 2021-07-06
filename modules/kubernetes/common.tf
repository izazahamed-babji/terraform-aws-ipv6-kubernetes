# ==================================================
# SSH Keypair
# ==================================================
# ==================================================

resource "aws_key_pair" "ssh_keypair" {
  key_name   = "${var.project_name}-key"
  public_key = file(var.ssh_public_key)
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
# Generate Token
# ==================================================
# ==================================================

resource "random_shuffle" "token1" {
  input        = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "a", "b", "c", "d", "e", "f", "g", "h", "i", "t", "j", "k", "l", "m", "n", "o", "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z"]
  result_count = 6
}

resource "random_shuffle" "token2" {
  input        = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "a", "b", "c", "d", "e", "f", "g", "h", "i", "t", "j", "k", "l", "m", "n", "o", "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z"]
  result_count = 16
}

# ==================================================
# # DNS zone
# ==================================================
# ==================================================

data "aws_route53_zone" "main_dns_zone" {
  name         = "${var.hosted_zone}."
  private_zone = var.hosted_zone_private
}