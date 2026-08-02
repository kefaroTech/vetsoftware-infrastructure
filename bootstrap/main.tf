data "aws_caller_identity" "current" {}

locals {
  name        = "${var.project_name}-${var.environment}-tfstate"
  bucket_name = var.state_bucket_name != "" ? var.state_bucket_name : "${local.name}-${data.aws_caller_identity.current.account_id}"
}

resource "aws_kms_key" "state" {
  count = var.enable_kms ? 1 : 0

  description             = "Terraform state for ${var.project_name} ${var.environment}"
  deletion_window_in_days = 30
  enable_key_rotation     = true
}

resource "aws_kms_alias" "state" {
  count = var.enable_kms ? 1 : 0

  name          = "alias/${local.name}"
  target_key_id = aws_kms_key.state[0].key_id
}

resource "aws_s3_bucket" "state" {
  bucket = local.bucket_name

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = var.enable_kms ? "aws:kms" : "AES256"
      kms_master_key_id = var.enable_kms ? aws_kms_key.state[0].arn : null
    }

    bucket_key_enabled = var.enable_kms
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

data "aws_iam_policy_document" "state" {
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.state.arn,
      "${aws_s3_bucket.state.arn}/*"
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.state.json
}

module "ecr" {
  source = "../modules/ecr"

  project_name                      = var.project_name
  github_organization               = var.github_organization
  github_organization_id            = var.github_organization_id
  github_environment                = var.github_environment
  existing_github_oidc_provider_arn = var.existing_github_oidc_provider_arn
  images_to_keep                    = var.ecr_images_to_keep
  repositories = {
    backend = {
      name                 = "${var.project_name}-backend"
      github_repository    = var.github_repositories.backend
      github_repository_id = var.github_repository_ids.backend
    }
    private_front = {
      name                 = "${var.project_name}-front"
      github_repository    = var.github_repositories.private_front
      github_repository_id = var.github_repository_ids.private_front
    }
    public_front = {
      name                 = "${var.project_name}-public-front"
      github_repository    = var.github_repositories.public_front
      github_repository_id = var.github_repository_ids.public_front
    }
  }
  tags = var.tags
}
