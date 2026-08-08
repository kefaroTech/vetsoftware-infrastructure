output "api_url" {
  description = "URL pública de desarrollo servida por Cloudflare Tunnel."
  value       = "https://${var.api_domain_name}"
}

output "vpc_id" {
  description = "VPC exclusiva de desarrollo; dev no depende de la red de ningun otro entorno."
  value       = module.network.vpc_id
}

output "vpc_cidr" {
  value = module.network.vpc_cidr
}

output "cloudflare_tunnel_origin_url" {
  description = "Origen local que debe configurarse en el hostname dev del túnel remoto."
  value       = module.backend.cloudflare_tunnel_origin_url
}

output "ecs_cluster_name" {
  value = module.backend.cluster_name
}

output "ecs_service_name" {
  value = module.backend.service_name
}

output "database_endpoint" {
  value = module.database.endpoint
}

output "valkey_endpoint" {
  value = module.cache.endpoint
}

output "application_bucket_name" {
  value = aws_s3_bucket.application.id
}

output "scheduled_shutdown_names" {
  value = module.scheduled_shutdown.schedule_names
}

output "finops_alerts" {
  description = "Configuración multicanal de alertas de costo del entorno dev."
  value = {
    monthly_budget_usd       = var.monthly_budget_usd
    forecast_threshold_usd   = var.monthly_budget_usd * 0.8
    actual_threshold_usd     = var.monthly_budget_usd
    anomaly_threshold_usd    = var.cost_anomaly_threshold_usd
    email_enabled            = trimspace(var.alarm_email) != ""
    slack_enabled            = local.slack_notifications_enabled
    topic_arn                = module.monitoring.finops_topic_arn
    anomaly_monitor_arn      = module.monitoring.cost_anomaly_monitor_arn
    slack_configuration_arns = module.monitoring.slack_chat_configuration_arns
  }
}

output "alerting" {
  description = "Contrato de alertas operativas de dev: severidades, umbrales derivados y circuitos de eventos activos."
  value       = module.monitoring.alerting
}

output "cost_profile" {
  value = {
    backend_cpu_mib    = var.backend_cpu
    backend_memory_mib = var.backend_memory
    fargate_spot_only = (
      module.backend.capacity_provider_strategy.fargate_base == 0 &&
      module.backend.capacity_provider_strategy.fargate_weight == 0 &&
      module.backend.capacity_provider_strategy.fargate_spot_weight > 0
    )
    backend_min_tasks      = module.backend.autoscaling_range.min
    backend_max_tasks      = module.backend.autoscaling_range.max
    database_class         = var.database_instance_class
    database_backup_days   = var.database_backup_retention_days
    database_hardening     = module.database.hardening
    database_logging       = module.database.logging
    valkey_storage_gb      = var.valkey_maximum_data_storage_gb
    valkey_ecpu_per_second = var.valkey_maximum_ecpu_per_second
    log_retention_days     = var.log_retention_days
    load_balancer_count    = 0
    dedicated_alloy        = false
    dedicated_vpc          = true
    assign_public_ip       = module.backend.assign_public_ip
    public_https_cidr      = aws_vpc_security_group_egress_rule.backend_public_https.cidr_ipv4
    public_https_port      = aws_vpc_security_group_egress_rule.backend_public_https.to_port
    interface_endpoints    = 0
  }
}
