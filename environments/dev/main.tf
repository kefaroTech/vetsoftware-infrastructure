module "kms" {
  source = "../../modules/kms"

  name                    = local.name
  cost_alerts_sns_enabled = true
  tags                    = local.common_tags
}

module "network" {
  source = "../../modules/network"

  name                    = local.name
  vpc_cidr                = var.vpc_cidr
  availability_zone_count = var.availability_zone_count
  kms_key_arn             = module.kms.key_arn
  flow_log_retention_days = var.log_retention_days
  tags                    = local.common_tags
}

module "secrets" {
  source = "../../modules/secrets"

  name                            = local.name
  application_secrets_json        = var.application_secrets_json
  grafana_secrets_json            = var.grafana_secrets_json
  application_secret_version      = var.application_secret_version
  grafana_secret_version          = var.grafana_secret_version
  cloudflare_tunnel_token         = var.cloudflare_tunnel_token
  cloudflare_tunnel_token_version = var.cloudflare_tunnel_token_version
  recovery_window_in_days         = 0
  tags                            = local.common_tags
}

resource "aws_security_group" "backend" {
  name_prefix = "${local.name}-backend-"
  description = "Development Fargate backend"
  vpc_id      = module.network.vpc_id
  tags        = merge(local.common_tags, { Name = "${local.name}-backend" })

  lifecycle {
    create_before_destroy = true
  }
}

# Excepcion de costo aprobada: dev consume las APIs publicas de AWS sobre TLS.
# El security group no contiene reglas de ingreso; cloudflared usa localhost.
#trivy:ignore:AVD-AWS-0104
resource "aws_vpc_security_group_egress_rule" "backend_public_https" {
  security_group_id = aws_security_group.backend.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  description       = "HTTPS to public AWS APIs and external services"
}

resource "aws_vpc_security_group_egress_rule" "backend_cloudflare_tunnel" {
  for_each = toset(var.cloudflare_tunnel_ipv4_cidrs)

  security_group_id = aws_security_group.backend.id
  cidr_ipv4         = each.value
  from_port         = 7844
  to_port           = 7844
  ip_protocol       = "tcp"
  description       = "Cloudflare Tunnel HTTP2 transport"
}

resource "aws_security_group" "database" {
  name_prefix = "${local.name}-database-"
  description = "Development MySQL"
  vpc_id      = module.network.vpc_id
  tags        = merge(local.common_tags, { Name = "${local.name}-database" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "database_from_backend" {
  security_group_id            = aws_security_group.database.id
  referenced_security_group_id = aws_security_group.backend.id
  from_port                    = 3306
  to_port                      = 3306
  ip_protocol                  = "tcp"
  description                  = "Development MySQL only from development backend"
}

resource "aws_vpc_security_group_egress_rule" "backend_to_database" {
  security_group_id            = aws_security_group.backend.id
  referenced_security_group_id = aws_security_group.database.id
  from_port                    = 3306
  to_port                      = 3306
  ip_protocol                  = "tcp"
  description                  = "Development backend to MySQL"
}

resource "aws_security_group" "cache" {
  name_prefix = "${local.name}-cache-"
  description = "Development Valkey"
  vpc_id      = module.network.vpc_id
  tags        = merge(local.common_tags, { Name = "${local.name}-cache" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "cache_from_backend" {
  security_group_id            = aws_security_group.cache.id
  referenced_security_group_id = aws_security_group.backend.id
  from_port                    = 6379
  to_port                      = 6379
  ip_protocol                  = "tcp"
  description                  = "Development Valkey only from development backend"
}

resource "aws_vpc_security_group_egress_rule" "backend_to_cache" {
  security_group_id            = aws_security_group.backend.id
  referenced_security_group_id = aws_security_group.cache.id
  from_port                    = 6379
  to_port                      = 6379
  ip_protocol                  = "tcp"
  description                  = "Development backend to Valkey"
}

resource "aws_s3_bucket" "application" {
  bucket        = local.application_bucket_name
  force_destroy = true
  tags          = merge(local.common_tags, { DataClassification = "confidential" })
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
      kms_master_key_id = module.kms.key_arn
      sse_algorithm     = "aws:kms"
    }

    bucket_key_enabled = true
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
    id     = "development-retention"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 7
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

data "aws_iam_policy_document" "application_bucket" {
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.application.arn,
      "${aws_s3_bucket.application.arn}/*",
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "application" {
  bucket = aws_s3_bucket.application.id
  policy = data.aws_iam_policy_document.application_bucket.json
}

module "database" {
  source = "../../modules/database"

  name                         = "${local.name}-mysql"
  subnet_ids                   = module.network.data_subnet_ids
  security_group_ids           = [aws_security_group.database.id]
  database_name                = var.database_name
  master_username              = var.database_master_username
  engine_version               = var.database_engine_version
  parameter_group_family       = var.database_parameter_group_family
  instance_class               = var.database_instance_class
  allocated_storage            = var.database_allocated_storage
  max_allocated_storage        = var.database_max_allocated_storage
  multi_az                     = false
  backup_retention_period      = var.database_backup_retention_days
  performance_insights_enabled = false
  apply_immediately            = true
  tags                         = local.common_tags
}

module "cache" {
  source = "../../modules/cache"

  name                     = "${local.name}-valkey"
  subnet_ids               = module.network.data_subnet_ids
  security_group_ids       = [aws_security_group.cache.id]
  major_engine_version     = var.valkey_major_engine_version
  password_version         = var.valkey_password_version
  maximum_data_storage_gb  = var.valkey_maximum_data_storage_gb
  maximum_ecpu_per_second  = var.valkey_maximum_ecpu_per_second
  snapshot_retention_limit = 1
  tags                     = local.common_tags
}

module "backend" {
  source = "../../modules/ecs_backend"

  name                  = "${local.name}-backend"
  image_uri             = var.backend_image_uri
  subnet_ids            = module.network.public_subnet_ids
  security_group_ids    = [aws_security_group.backend.id]
  assign_public_ip      = true
  cpu                   = var.backend_cpu
  memory                = var.backend_memory
  cpu_architecture      = var.backend_cpu_architecture
  health_check_path     = var.backend_health_check_path
  desired_count         = 1
  min_count             = 0
  max_count             = 1
  fargate_base          = 0
  fargate_weight        = 0
  fargate_spot_weight   = 1
  environment_variables = local.backend_environment
  secrets               = local.backend_secrets
  runtime_secret_arns = [
    module.database.master_secret_arn,
    module.cache.connection_secret_arn,
    module.secrets.application_secret_arn,
    module.secrets.grafana_secret_arn,
    module.secrets.cloudflare_tunnel_secret_arn,
  ]
  cloudflare_tunnel_secret_arn = module.secrets.cloudflare_tunnel_secret_arn
  application_bucket_arn       = aws_s3_bucket.application.arn
  database_connect_resource_arns = [
    "arn:aws:rds-db:${var.aws_region}:${data.aws_caller_identity.current.account_id}:dbuser:${module.database.resource_id}/${module.database.master_username}"
  ]
  kms_key_arn               = module.kms.key_arn
  log_retention_days        = var.log_retention_days
  enable_container_insights = var.backend_container_insights
  tags                      = local.common_tags
}

module "monitoring" {
  source = "../../modules/monitoring"

  name                             = local.name
  aws_region                       = var.aws_region
  sns_kms_key_arn                  = module.kms.key_arn
  alarm_email                      = var.alarm_email
  monthly_budget_usd               = var.monthly_budget_usd
  budget_sns_notifications_enabled = true
  cost_anomaly_detection_enabled   = true
  cost_anomaly_threshold_usd       = var.cost_anomaly_threshold_usd
  slack_workspace_id               = var.slack_workspace_id
  slack_channel_id                 = var.slack_channel_id
  ecs_cluster_name                 = module.backend.cluster_name
  ecs_service_name                 = module.backend.service_name
  cloudflare_tunnel_log_group_name = module.backend.cloudflare_tunnel_log_group_name
  database_identifier              = module.database.identifier
  alloy_instance_ids               = []
  tags                             = local.common_tags
}

module "scheduled_shutdown" {
  source = "../../modules/scheduled_shutdown"

  name                    = local.name
  ecs_cluster_arn         = module.backend.cluster_arn
  ecs_service_arn         = module.backend.service_arn
  ecs_service_name        = module.backend.service_name
  database_arn            = module.database.arn
  database_identifier     = module.database.identifier
  schedule_timezone       = var.schedule_timezone
  database_start_schedule = var.database_start_schedule
  backend_start_schedule  = var.backend_start_schedule
  backend_stop_schedule   = var.backend_stop_schedule
  database_stop_schedule  = var.database_stop_schedule
  enabled                 = var.scheduled_shutdown_enabled
  tags                    = local.common_tags
}
