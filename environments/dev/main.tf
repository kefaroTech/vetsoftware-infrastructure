module "secrets" {
  source = "../../modules/secrets"

  name                       = local.name
  application_secrets_json   = var.application_secrets_json
  grafana_secrets_json       = var.grafana_secrets_json
  application_secret_version = var.application_secret_version
  grafana_secret_version     = var.grafana_secret_version
  recovery_window_in_days    = 0
  tags                       = local.common_tags
}

resource "aws_security_group" "backend" {
  name_prefix = "${local.name}-backend-"
  description = "Development Fargate backend"
  vpc_id      = data.aws_vpc.shared.id
  tags        = merge(local.common_tags, { Name = "${local.name}-backend" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "backend_from_shared_alb" {
  security_group_id            = aws_security_group.backend.id
  referenced_security_group_id = data.aws_security_group.shared_alb.id
  from_port                    = 8080
  to_port                      = 8080
  ip_protocol                  = "tcp"
  description                  = "Development backend only from shared ALB"
}

resource "aws_vpc_security_group_egress_rule" "backend_all" {
  security_group_id = aws_security_group.backend.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "Backend outbound dependencies and direct Grafana Cloud export"
}

resource "aws_vpc_security_group_egress_rule" "shared_alb_to_backend" {
  security_group_id            = data.aws_security_group.shared_alb.id
  referenced_security_group_id = aws_security_group.backend.id
  from_port                    = 8080
  to_port                      = 8080
  ip_protocol                  = "tcp"
  description                  = "Shared ALB to development backend"
}

resource "aws_security_group" "database" {
  name_prefix = "${local.name}-database-"
  description = "Development MySQL"
  vpc_id      = data.aws_vpc.shared.id
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

resource "aws_security_group" "cache" {
  name_prefix = "${local.name}-cache-"
  description = "Development Valkey"
  vpc_id      = data.aws_vpc.shared.id
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
  subnet_ids                   = sort(data.aws_subnets.shared_data.ids)
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
  deletion_protection          = false
  skip_final_snapshot          = true
  performance_insights_enabled = false
  apply_immediately            = true
  tags                         = local.common_tags
}

module "cache" {
  source = "../../modules/cache"

  name                     = "${local.name}-valkey"
  subnet_ids               = sort(data.aws_subnets.shared_data.ids)
  security_group_ids       = [aws_security_group.cache.id]
  major_engine_version     = var.valkey_major_engine_version
  password_version         = var.valkey_password_version
  maximum_data_storage_gb  = var.valkey_maximum_data_storage_gb
  maximum_ecpu_per_second  = var.valkey_maximum_ecpu_per_second
  snapshot_retention_limit = 1
  tags                     = local.common_tags
}

resource "aws_lb_target_group" "backend" {
  name        = substr("${local.name}-backend", 0, 32)
  port        = 8080
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = data.aws_vpc.shared.id

  deregistration_delay = 30

  health_check {
    enabled             = true
    path                = "/api/v1/actuator/health/readiness"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = local.common_tags

  lifecycle {
    precondition {
      condition     = length(data.aws_subnets.shared_public.ids) >= 2 && length(data.aws_subnets.shared_data.ids) >= 2
      error_message = "La VPC compartida debe conservar al menos dos subredes públicas y dos de datos."
    }
  }
}

resource "aws_lb_listener_rule" "backend" {
  listener_arn = data.aws_lb_listener.shared.arn
  priority     = var.shared_listener_rule_priority

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.backend.arn
  }

  condition {
    host_header {
      values = [var.api_domain_name]
    }
  }

  tags = local.common_tags

  lifecycle {
    precondition {
      condition     = var.shared_alb_listener_port != 443 || var.confirm_shared_certificate_covers_domain
      error_message = "Confirme que el certificado HTTPS compartido cubre api_domain_name."
    }
  }
}

resource "aws_route53_record" "api" {
  zone_id = var.route53_zone_id
  name    = var.api_domain_name
  type    = "A"

  alias {
    name                   = data.aws_lb.shared.dns_name
    zone_id                = data.aws_lb.shared.zone_id
    evaluate_target_health = true
  }
}

module "backend" {
  source = "../../modules/ecs_backend"

  name                  = "${local.name}-backend"
  image_uri             = var.backend_image_uri
  subnet_ids            = sort(data.aws_subnets.shared_public.ids)
  security_group_ids    = [aws_security_group.backend.id]
  target_group_arn      = aws_lb_target_group.backend.arn
  cpu                   = var.backend_cpu
  memory                = var.backend_memory
  cpu_architecture      = var.backend_cpu_architecture
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
  ]
  application_bucket_arn    = aws_s3_bucket.application.arn
  log_retention_days        = var.log_retention_days
  enable_container_insights = var.backend_container_insights
  tags                      = local.common_tags

  depends_on = [aws_lb_listener_rule.backend]
}

module "monitoring" {
  source = "../../modules/monitoring"

  name                    = local.name
  aws_region              = var.aws_region
  alarm_email             = var.alarm_email
  monthly_budget_usd      = var.monthly_budget_usd
  ecs_cluster_name        = module.backend.cluster_name
  ecs_service_name        = module.backend.service_name
  alb_arn_suffix          = data.aws_lb.shared.arn_suffix
  target_group_arn_suffix = aws_lb_target_group.backend.arn_suffix
  database_identifier     = module.database.identifier
  alloy_instance_ids      = []
  tags                    = local.common_tags
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
