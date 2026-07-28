locals {
  application_bucket = var.application_bucket_name != "" ? var.application_bucket_name : "${var.name}-app-${var.account_id}-${var.aws_region}"
  audit_bucket       = var.audit_bucket_name != "" ? var.audit_bucket_name : "${var.name}-audit-${var.account_id}-${var.aws_region}"
  stream_name        = var.delivery_stream_name != "" ? var.delivery_stream_name : "${var.name}-audit"
}

resource "aws_s3_bucket" "application" {
  bucket        = local.application_bucket
  force_destroy = false

  tags = merge(var.tags, { DataClassification = "confidential" })
}

resource "aws_s3_bucket_versioning" "application" {
  bucket = aws_s3_bucket.application.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "application" {
  bucket = aws_s3_bucket.application.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "application" {
  bucket = aws_s3_bucket.application.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "application" {
  bucket = aws_s3_bucket.application.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "application" {
  bucket = aws_s3_bucket.application.id

  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = var.application_noncurrent_expiration_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_s3_bucket" "audit" {
  bucket              = local.audit_bucket
  object_lock_enabled = true
  force_destroy       = false

  lifecycle {
    prevent_destroy = true
  }

  tags = merge(var.tags, {
    DataClassification = "audit"
    RetentionMode      = "COMPLIANCE"
  })
}

resource "aws_s3_bucket_versioning" "audit" {
  bucket = aws_s3_bucket.audit.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_object_lock_configuration" "audit" {
  bucket = aws_s3_bucket.audit.id

  rule {
    default_retention {
      mode = "COMPLIANCE"
      days = var.audit_retention_days
    }
  }

  depends_on = [aws_s3_bucket_versioning.audit]
}

resource "aws_s3_bucket_server_side_encryption_configuration" "audit" {
  bucket = aws_s3_bucket.audit.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "audit" {
  bucket = aws_s3_bucket.audit.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "audit" {
  bucket = aws_s3_bucket.audit.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "audit" {
  bucket = aws_s3_bucket.audit.id

  rule {
    id     = "archive-audit"
    status = "Enabled"

    filter {}

    transition {
      days          = var.transition_to_glacier_days
      storage_class = "GLACIER"
    }

    noncurrent_version_transition {
      noncurrent_days = var.transition_to_glacier_days
      storage_class   = "GLACIER"
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_object_lock_configuration.audit]
}

data "aws_iam_policy_document" "bucket_tls" {
  for_each = {
    application = aws_s3_bucket.application.arn
    audit       = aws_s3_bucket.audit.arn
  }

  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions   = ["s3:*"]
    resources = [each.value, "${each.value}/*"]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "application" {
  bucket = aws_s3_bucket.application.id
  policy = data.aws_iam_policy_document.bucket_tls["application"].json
}

resource "aws_cloudwatch_log_group" "firehose" {
  name              = "/aws/firehose/${local.stream_name}"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

resource "aws_cloudwatch_log_stream" "firehose" {
  name           = "S3Delivery"
  log_group_name = aws_cloudwatch_log_group.firehose.name
}

data "aws_iam_policy_document" "firehose_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["firehose.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "firehose" {
  name_prefix        = "${var.name}-firehose-"
  assume_role_policy = data.aws_iam_policy_document.firehose_assume.json
  tags               = var.tags
}

data "aws_iam_policy_document" "firehose" {
  statement {
    sid = "BucketMetadata"
    actions = [
      "s3:GetBucketLocation",
      "s3:ListBucket",
      "s3:ListBucketMultipartUploads"
    ]
    resources = [aws_s3_bucket.audit.arn]
  }

  statement {
    sid = "DeliverObjects"
    actions = [
      "s3:AbortMultipartUpload",
      "s3:ListMultipartUploadParts",
      "s3:PutObject"
    ]
    resources = ["${aws_s3_bucket.audit.arn}/*"]
  }

  statement {
    sid       = "WriteDeliveryLogs"
    actions   = ["logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.firehose.arn}:*"]
  }
}

resource "aws_iam_role_policy" "firehose" {
  name   = "deliver-audit-to-s3"
  role   = aws_iam_role.firehose.id
  policy = data.aws_iam_policy_document.firehose.json
}

resource "aws_kinesis_firehose_delivery_stream" "audit" {
  name        = local.stream_name
  destination = "extended_s3"

  extended_s3_configuration {
    role_arn            = aws_iam_role.firehose.arn
    bucket_arn          = aws_s3_bucket.audit.arn
    prefix              = "audit/!{timestamp:yyyy/MM/dd}/"
    error_output_prefix = "errors/!{firehose:error-output-type}/!{timestamp:yyyy/MM/dd}/"
    buffering_interval  = var.firehose_buffer_interval
    buffering_size      = var.firehose_buffer_size
    compression_format  = "GZIP"

    cloudwatch_logging_options {
      enabled         = true
      log_group_name  = aws_cloudwatch_log_group.firehose.name
      log_stream_name = aws_cloudwatch_log_stream.firehose.name
    }
  }

  tags = var.tags
}

data "aws_iam_policy_document" "audit_bucket" {
  source_policy_documents = [data.aws_iam_policy_document.bucket_tls["audit"].json]

  statement {
    sid    = "AllowFirehoseDelivery"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.firehose.arn]
    }

    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.audit.arn}/*"]
  }
}

resource "aws_s3_bucket_policy" "audit" {
  bucket = aws_s3_bucket.audit.id
  policy = data.aws_iam_policy_document.audit_bucket.json
}
