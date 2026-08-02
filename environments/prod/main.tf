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

  name                               = local.name
  vpc_id                             = module.network.vpc_id
  approved_external_https_ipv4_cidrs = var.approved_external_https_ipv4_cidrs
  tags                               = local.common_tags
}

resource "aws_vpc_endpoint" "private_aws_api" {
  for_each = toset([
    "ec2messages",
    "ecr.api",
    "ecr.dkr",
    "firehose",
    "logs",
    "secretsmanager",
    "ssm",
    "ssmmessages",
  ])

  vpc_id              = module.network.vpc_id
  service_name        = "com.amazonaws.${var.aws_region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = module.network.data_subnet_ids
  security_group_ids  = [module.security.vpc_endpoints_security_group_id]
  private_dns_enabled = true

  tags = merge(local.common_tags, { Name = "${local.name}-${replace(each.value, ".", "-")}" })
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

module "alb" {
  source = "../../modules/alb"

  name                       = local.name
  vpc_id                     = module.network.vpc_id
  subnet_ids                 = module.network.public_subnet_ids
  security_group_ids         = [module.security.alb_security_group_id]
  certificate_arn            = var.certificate_arn
  enable_deletion_protection = var.alb_deletion_protection
  kms_key_arn                = module.kms.key_arn
  health_check_path          = var.backend_health_check_path
  tags                       = local.common_tags
}

module "backend" {
  source = "../../modules/ecs_backend"

  name                  = "${local.name}-backend"
  image_uri             = var.backend_image_uri
  subnet_ids            = module.network.public_subnet_ids
  security_group_ids    = [module.security.backend_security_group_id]
  target_group_arn      = module.alb.target_group_arn
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

  name                    = local.name
  aws_region              = var.aws_region
  alarm_email             = var.alarm_email
  monthly_budget_usd      = var.monthly_budget_usd
  ecs_cluster_name        = module.backend.cluster_name
  ecs_service_name        = module.backend.service_name
  alb_arn_suffix          = module.alb.arn_suffix
  target_group_arn_suffix = module.alb.target_group_arn_suffix
  database_identifier     = module.database.identifier
  alloy_instance_ids      = module.alloy.instance_ids
  tags                    = local.common_tags
}
