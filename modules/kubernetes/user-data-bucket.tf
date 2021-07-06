# ==================================================
# S3 Bucket
# ==================================================
# ==================================================

resource "aws_s3_bucket" "user_data_bucket" {
  bucket  = "${var.s3_bootstrap_user_data_bucket}"
  acl     = "private"

  tags = merge(
    {
      "Name"                                               = format("%v-%v", var.project_name, var.s3_bootstrap_user_data_bucket)
    },
    var.tags,
  )
}

data "aws_iam_policy_document" "user_data_bucket_policy" {
  statement {
    actions   = ["s3:ListBucket"]
    effect    = "Allow"
    resources = [
      "arn:aws:s3:::${aws_s3_bucket.user_data_bucket.id}",
    ]
  }
  statement {
    actions   = ["s3:GetObject"]
    effect    = "Allow"
    resources = [
      "arn:aws:s3:::${aws_s3_bucket.user_data_bucket.id}/*",
    ]
  }
}

resource "aws_iam_policy" "user_data_bucket_policy" {
  name        = "${var.project_name}-user-data"
  path        = "/"
  description = "Policy for granting S3 bucket permissions"
  policy      = data.aws_iam_policy_document.user_data_bucket_policy.json
}