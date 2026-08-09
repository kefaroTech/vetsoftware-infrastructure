module "kms" {
  source = "../../modules/kms"

  name                            = local.name
  cost_alerts_sns_enabled         = true
  event_notifications_sns_enabled = true
  sns_publisher_role_arns         = [local.deployment_notifier_role_arn, local.cost_reporter_role_arn]
  tags                            = local.common_tags
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
  log_retention_days           = var.log_retention_days
  kms_key_arn                  = module.kms.key_arn
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
  # Cost Explorer quedo habilitado a mano desde Billing -no se puede por API-, que
  # era lo unico que faltaba: ce:CreateAnomalyMonitor respondia "User not enabled
  # for cost explorer access". Al habilitarlo, AWS crea por su cuenta un monitor de
  # servicios y un resumen diario por correo, y la cuota es de uno por cuenta: hay
  # que importarlo o borrarlo antes del primer apply con esto encendido.
  cost_anomaly_detection_enabled = true
  cost_anomaly_threshold_usd     = var.cost_anomaly_threshold_usd
  slack_workspace_id             = var.slack_workspace_id
  slack_channel_id               = var.slack_channel_id
  slack_alerts_channel_id        = var.slack_alerts_channel_id
  slack_infra_channel_id         = var.slack_infra_channel_id
  slack_critical_channel_id      = var.slack_critical_channel_id
  runbook_url                    = var.runbook_url
  notification_publisher_role_arns = [
    local.deployment_notifier_role_arn,
    local.cost_reporter_role_arn,
  ]

  ecs_events_enabled               = true
  ecs_cluster_name                 = module.backend.cluster_name
  ecs_cluster_arn                  = module.backend.cluster_arn
  ecs_service_name                 = module.backend.service_name
  ecs_service_arn                  = module.backend.service_arn
  backend_log_group_name           = module.backend.log_group_name
  cloudflare_tunnel_log_group_name = module.backend.cloudflare_tunnel_log_group_name
  container_insights_enabled       = var.backend_container_insights

  database_events_enabled = true
  database_identifier     = module.database.identifier
  database_arn            = module.database.arn
  # Los umbrales de conexiones y disco se derivan de estos dos valores en vez de
  # escribirse a mano: cambiar la clase de instancia o ampliar el volumen mueve
  # las alarmas con ellos. max_connections lo calcula RDS como
  # {DBInstanceClassMemory/12582880} y hay que reconfirmarlo con
  # SHOW GLOBAL VARIABLES LIKE 'max_connections' al cambiar de clase.
  database_max_connections       = var.database_max_connections
  database_allocated_storage_gib = var.database_allocated_storage

  cache_alarms_enabled          = true
  cache_name                    = module.cache.name
  cache_maximum_data_storage_gb = var.valkey_maximum_data_storage_gb
  cache_maximum_ecpu_per_second = var.valkey_maximum_ecpu_per_second

  alloy_instance_ids = []
  tags               = local.common_tags
}

module "scheduled_shutdown" {
  source = "../../modules/scheduled_shutdown"

  name                   = local.name
  ecs_cluster_arn        = module.backend.cluster_arn
  ecs_service_arn        = module.backend.service_arn
  ecs_service_name       = module.backend.service_name
  database_arn           = module.database.arn
  database_identifier    = module.database.identifier
  schedule_timezone      = var.schedule_timezone
  backend_stop_schedule  = var.backend_stop_schedule
  database_stop_schedule = var.database_stop_schedule
  enabled                = var.scheduled_shutdown_enabled
  # Avisar del apagado solo tiene sentido si hay canal donde avisar: sin Slack
  # configurado, el topic ni siquiera existe.
  stop_notice_enabled = local.slack_notifications_enabled
  # El apagado es un evento, no una alarma: nadie tiene que hacer nada cuando
  # llega. Va al canal de infra junto a los despliegues.
  notification_topic_arn   = local.slack_notifications_enabled ? module.monitoring.events_topic_arn : ""
  notification_kms_key_arn = module.kms.key_arn
  tags                     = local.common_tags
}

# Linea base de trazabilidad de la cuenta. Va aqui y no en el bootstrap porque
# necesita la CMK y el topic de alertas del entorno; dev y prod tienen cada uno
# la suya porque viven en cuentas separadas y CloudTrail, GuardDuty y Access
# Analyzer son singletons de cuenta.
#
# Todo lo que queda activo es gratuito. GuardDuty y los data events de
# CloudTrail se facturan, asi que se dejan apagados y el contrato lo fija.
module "account_baseline" {
  source = "../../modules/account_baseline"

  name           = local.name
  aws_account_id = data.aws_caller_identity.current.account_id
  aws_region     = var.aws_region
  kms_key_arn    = module.kms.key_arn

  regulated_bucket_arns = ["${aws_s3_bucket.application.arn}/"]
  alarm_topic_arn       = module.monitoring.alarm_topic_arn

  # Los access logs siguen la retencion del entorno: dev se recrea a proposito y
  # sus registros no tienen valor probatorio. El rastro de CloudTrail no la
  # sigue -se queda en el default de cinco anios- porque su Object Lock es
  # COMPLIANCE y lo que se escriba corto no se puede alargar despues.
  access_log_retention_days = var.log_retention_days

  tags = local.common_tags
}

# El bucket de aplicacion guarda documentos generados -PDF de facturacion,
# historias clinicas-. Esto es lo que responde "quien descargo este documento y
# cuando", que es la pregunta que hace un titular al ejercer sus derechos.
resource "aws_s3_bucket_logging" "application" {
  bucket = aws_s3_bucket.application.id

  target_bucket = module.account_baseline.access_logs_bucket_name
  target_prefix = "s3/${local.application_bucket_name}/"
}
