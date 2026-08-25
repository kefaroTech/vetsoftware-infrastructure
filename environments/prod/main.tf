module "kms" {
  source = "../../modules/kms"

  name = local.name
  tags = local.common_tags
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

module "security" {
  source = "../../modules/security"

  name   = local.name
  vpc_id = module.network.vpc_id
  tags   = local.common_tags
}

module "secrets" {
  source = "../../modules/secrets"

  name = local.name

  # Siete valores sueltos: el JSON y los nombres de clave los pone el modulo.
  jwt_secret                 = var.jwt_secret
  resend_api_key             = var.resend_api_key
  recaptcha_secret           = var.recaptcha_secret
  dian_enc_key               = var.dian_enc_key
  otlp_username              = var.otlp_username
  otlp_api_key               = var.otlp_api_key
  otel_exporter_otlp_headers = var.otel_exporter_otlp_headers

  application_secret_version      = var.application_secret_version
  grafana_secret_version          = var.grafana_secret_version
  cloudflare_tunnel_token         = var.cloudflare_tunnel_token
  cloudflare_tunnel_token_version = var.cloudflare_tunnel_token_version
  tags                            = local.common_tags
}

module "storage_audit" {
  source = "../../modules/storage_audit"

  name                                   = local.name
  account_id                             = data.aws_caller_identity.current.account_id
  aws_region                             = var.aws_region
  application_bucket_name                = var.application_bucket_name
  audit_bucket_name                      = var.audit_bucket_name
  audit_retention_days                   = var.audit_retention_days
  application_noncurrent_expiration_days = 90
  log_retention_days                     = var.log_retention_days
  kms_key_arn                            = module.kms.key_arn
  tags                                   = local.common_tags
}

module "database" {
  source = "../../modules/database"

  name                    = "${local.name}-mysql"
  subnet_ids              = module.network.data_subnet_ids
  security_group_ids      = [module.security.database_security_group_id]
  database_name           = var.database_name
  master_username         = var.database_master_username
  engine_version          = var.database_engine_version
  parameter_group_family  = var.database_parameter_group_family
  instance_class          = var.database_instance_class
  allocated_storage       = var.database_allocated_storage
  max_allocated_storage   = var.database_max_allocated_storage
  multi_az                = var.database_multi_az
  backup_retention_period = var.database_backup_retention_days
  log_retention_days      = var.log_retention_days
  kms_key_arn             = module.kms.key_arn
  tags                    = local.common_tags
}

module "cache" {
  source = "../../modules/cache"

  name                    = "${local.name}-valkey"
  subnet_ids              = module.network.data_subnet_ids
  security_group_ids      = [module.security.cache_security_group_id]
  major_engine_version    = var.valkey_major_engine_version
  password_version        = var.valkey_password_version
  maximum_data_storage_gb = var.valkey_maximum_data_storage_gb
  maximum_ecpu_per_second = var.valkey_maximum_ecpu_per_second
  tags                    = local.common_tags
}

resource "aws_route53_zone" "private" {
  name = local.private_zone_name

  vpc {
    vpc_id = module.network.vpc_id
  }

  tags = local.common_tags
}

module "alloy" {
  source = "../../modules/ec2_service"

  name               = local.name
  service_name       = "alloy"
  instance_type      = var.alloy_instance_type
  instance_count     = var.alloy_instance_count
  subnet_ids         = module.network.public_subnet_ids
  security_group_ids = [module.security.alloy_security_group_id]
  root_volume_size   = var.alloy_root_volume_size
  secret_arns        = [module.secrets.grafana_secret_arn]
  log_retention_days = var.log_retention_days
  user_data = templatefile("${path.module}/../../templates/alloy-user-data.sh.tftpl", {
    image                  = var.alloy_image
    container_memory_limit = var.alloy_container_memory_limit
    container_cpu_limit    = var.alloy_container_cpu_limit
    aws_region             = var.aws_region
    log_group_name         = "/${local.name}/alloy"
    grafana_secret_arn     = module.secrets.grafana_secret_arn
    alloy_config = templatefile("${path.module}/../../templates/alloy-config.alloy.tftpl", {
      grafana_otlp_endpoint = trimsuffix(var.grafana_otlp_endpoint, "/")
      memory_limit          = var.alloy_pipeline_memory_limit
      spike_limit           = var.alloy_pipeline_spike_limit
      grpc_port             = 4317
      http_port             = 4318
    })
  })
  tags = local.common_tags
}

resource "aws_route53_record" "alloy" {
  zone_id = aws_route53_zone.private.zone_id
  name    = "alloy.${local.private_zone_name}"
  type    = "A"
  ttl     = 30
  records = module.alloy.private_ips
}

module "backend" {
  source = "../../modules/ecs_backend"

  name                  = "${local.name}-backend"
  image_uri             = var.backend_image_uri
  subnet_ids            = module.network.public_subnet_ids
  security_group_ids    = [module.security.backend_security_group_id]
  assign_public_ip      = true
  cpu                   = var.backend_cpu
  memory                = var.backend_memory
  cpu_architecture      = var.backend_cpu_architecture
  health_check_path     = var.backend_health_check_path
  desired_count         = var.backend_desired_count
  min_count             = var.backend_min_count
  max_count             = var.backend_max_count
  fargate_spot_weight   = var.backend_fargate_spot_weight
  environment_variables = local.backend_environment
  secrets               = local.backend_secrets

  # Apagado en produccion. Una shell aqui da acceso a DB_PASSWORD, JWT_SECRET y
  # DIAN_ENC_KEY. Cuando haya que diagnosticar se activa con un apply, que deja
  # el registro de sesiones encendido a la vez, y se vuelve a apagar despues.
  enable_execute_command = var.enable_execute_command
  runtime_secret_arns = [
    module.database.master_secret_arn,
    module.cache.connection_secret_arn,
    module.secrets.application_secret_arn,
    module.secrets.cloudflare_tunnel_secret_arn,
  ]
  cloudflare_tunnel_secret_arn = module.secrets.cloudflare_tunnel_secret_arn
  application_bucket_arn       = module.storage_audit.application_bucket_arn
  firehose_stream_arn          = module.storage_audit.delivery_stream_arn
  database_connect_resource_arns = [
    "arn:aws:rds-db:${var.aws_region}:${data.aws_caller_identity.current.account_id}:dbuser:${module.database.resource_id}/${module.database.master_username}"
  ]
  kms_key_arn               = module.kms.key_arn
  log_retention_days        = var.log_retention_days
  enable_container_insights = var.backend_container_insights
  tags                      = local.common_tags

  depends_on = [
    aws_route53_record.alloy,
  ]
}

module "monitoring" {
  source = "../../modules/monitoring"

  name       = local.name
  aws_region = var.aws_region

  # El destino. alarm_email es obligatorio en produccion (ver variables.tf), y
  # mientras lo sea notification_topic_enabled es siempre verdadero: los dos
  # topicos de severidad existen y ninguna alarma puede nacer con
  # alarm_actions vacio. La CMK del entorno ya autoriza a cloudwatch, events,
  # budgets y costalerts a cifrar contra ella (modules/kms/main.tf), asi que
  # cifrar el topico no rompe la publicacion.
  alarm_email     = var.alarm_email
  sns_kms_key_arn = module.kms.key_arn

  # Se autoriza por policy del topico y no por policy del rol: las inline
  # policies de los roles de GitHub estan cerca del limite de 10.240 caracteres,
  # y una autorizacion nombrada aqui se aplica con el mismo apply que crea el
  # topico, sin volver a correr el bootstrap.
  notification_publisher_role_arns = [
    local.deployment_notifier_role_arn,
    local.cost_reporter_role_arn,
  ]

  monthly_budget_usd               = var.monthly_budget_usd
  budget_sns_notifications_enabled = true

  # Apagado mientras Cost Explorer no este habilitado a mano en la cuenta de
  # prod y su monitor de servicios importado. Ver la nota de la variable: no es
  # una bandera que se pueda encender sin ese paso previo.
  cost_anomaly_detection_enabled = var.cost_anomaly_detection_enabled
  cost_anomaly_threshold_usd     = var.cost_anomaly_threshold_usd

  # Los IDs de Slack se inyectan por TF_VAR desde iac-apply-prod; vacios dejan
  # Slack apagado sin afectar al correo ni a la existencia de los topicos.
  slack_workspace_id        = var.slack_workspace_id
  slack_channel_id          = var.slack_channel_id
  slack_alerts_channel_id   = var.slack_alerts_channel_id
  slack_infra_channel_id    = var.slack_infra_channel_id
  slack_critical_channel_id = var.slack_critical_channel_id
  runbook_url               = var.runbook_url

  # Sin el circuito de eventos, produccion no tiene ninguna alarma que detecte
  # una tarea que muere y no vuelve: las de CPU y memoria miden una tarea viva.
  # backend_crash_loop y backend_task_restarts cuelgan de aqui.
  ecs_events_enabled               = true
  ecs_cluster_name                 = module.backend.cluster_name
  ecs_cluster_arn                  = module.backend.cluster_arn
  ecs_service_name                 = module.backend.service_name
  ecs_service_arn                  = module.backend.service_arn
  backend_log_group_name           = module.backend.log_group_name
  cloudflare_tunnel_log_group_name = module.backend.cloudflare_tunnel_log_group_name

  # Falso mientras Container Insights siga apagado: RunningTaskCount vive en
  # ECS/ContainerInsights y sin el las alarmas quedarian en INSUFFICIENT_DATA
  # para siempre. Pasarlo deja el interruptor de hombre muerto a un flag.
  container_insights_enabled = var.backend_container_insights

  database_events_enabled = true
  database_identifier     = module.database.identifier
  database_arn            = module.database.arn
  # Los umbrales de conexiones y de disco se derivan de estos dos valores en vez
  # de escribirse a mano: cambiar la clase de instancia o ampliar el volumen
  # mueve las alarmas con ellos.
  database_max_connections       = var.database_max_connections
  database_allocated_storage_gib = var.database_allocated_storage

  alloy_instance_ids = module.alloy.instance_ids
  tags               = local.common_tags
}

# Linea base de trazabilidad de la cuenta. Prod tiene la suya: dev y prod viven
# en cuentas separadas, y CloudTrail, GuardDuty y Access Analyzer son singletons
# de cuenta.
#
# Todo lo que queda activo es gratuito. GuardDuty y los data events de
# CloudTrail se facturan; el contrato fija que siguen apagados, de modo que
# encenderlos sea una decision explicita y no una deriva.
module "account_baseline" {
  source = "../../modules/account_baseline"

  name           = local.name
  aws_account_id = data.aws_caller_identity.current.account_id
  aws_region     = var.aws_region
  kms_key_arn    = module.kms.key_arn

  # Los dos buckets con datos personales: el de documentos generados y el de
  # evidencia de auditoria. Leer el WORM tambien es un acceso que hay que poder
  # reconstruir: escribir de forma inmutable no registra las lecturas.
  regulated_bucket_arns = [
    "${module.storage_audit.application_bucket_arn}/",
    "${module.storage_audit.audit_bucket_arn}/",
  ]

  alarm_topic_arn = module.monitoring.alarm_topic_arn
  tags            = local.common_tags
}

resource "aws_s3_bucket_logging" "application" {
  bucket = module.storage_audit.application_bucket_name

  target_bucket = module.account_baseline.access_logs_bucket_name
  target_prefix = "s3/${module.storage_audit.application_bucket_name}/"
}

resource "aws_s3_bucket_logging" "audit" {
  bucket = module.storage_audit.audit_bucket_name

  target_bucket = module.account_baseline.access_logs_bucket_name
  target_prefix = "s3/${module.storage_audit.audit_bucket_name}/"
}
