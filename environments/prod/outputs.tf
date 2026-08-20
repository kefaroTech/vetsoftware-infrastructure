output "api_url" {
  description = "URL pública del backend."
  value       = "https://${var.api_domain_name}"
}

output "cloudflare_tunnel_origin_url" {
  description = "Origen local que debe configurarse en el hostname prod del túnel remoto."
  value       = module.backend.cloudflare_tunnel_origin_url
}

output "ecs_cluster_name" {
  value = module.backend.cluster_name
}

output "ecs_service_name" {
  value = module.backend.service_name
}

output "database_endpoint" {
  description = "Endpoint privado; la contraseña permanece en Secrets Manager."
  value       = module.database.endpoint
}

output "database_hardening" {
  value = module.database.hardening
}

output "database_logging" {
  value = module.database.logging
}

output "valkey_endpoint" {
  description = "Endpoint privado; REDIS_URL permanece en Secrets Manager."
  value       = module.cache.endpoint
}

output "alloy_private_dns" {
  value = aws_route53_record.alloy.fqdn
}

output "application_bucket_name" {
  value = module.storage_audit.application_bucket_name
}

output "audit_bucket_name" {
  value = module.storage_audit.audit_bucket_name
}

output "firehose_delivery_stream_name" {
  value = module.storage_audit.delivery_stream_name
}

output "application_secret_arn" {
  value = module.secrets.application_secret_arn
}

output "grafana_secret_arn" {
  value = module.secrets.grafana_secret_arn
}

output "monthly_budget_usd" {
  value = var.monthly_budget_usd
}

output "network_egress_profile" {
  description = "Contrato de salida economica: Fargate publico, APIs AWS por HTTPS y S3 por Gateway Endpoint."
  value = merge(module.security.public_https_egress, {
    assign_public_ip    = module.backend.assign_public_ip
    interface_endpoints = 0
    s3_gateway_endpoint = true
  })
}

# A donde va a parar una alarma de produccion. Se expone aparte del contrato de
# alertas porque la pregunta que responde es la que quedo sin respuesta durante
# meses: no "que se vigila" sino "quien se entera". El ultimo campo es
# literalmente el valor que recibe account_baseline: si es nulo, la regla de
# EventBridge que rutearia los hallazgos de GuardDuty tampoco se crea.
output "alarm_destinations" {
  description = "Destinos efectivos de las alarmas de produccion: correo suscrito, Slack y topicos por severidad."
  value = {
    email_enabled               = trimspace(var.alarm_email) != ""
    slack_enabled               = module.monitoring.alerting.slack_enabled
    warning_topic_arn           = module.monitoring.alerting.warning_topic_arn
    critical_topic_arn          = module.monitoring.alerting.critical_topic_arn
    events_topic_arn            = module.monitoring.alerting.events_topic_arn
    finops_topic_arn            = module.monitoring.alerting.finops_topic_arn
    guardduty_routing_topic_arn = module.monitoring.alarm_topic_arn
  }
}

output "alerting" {
  description = "Contrato de alertas operativas de produccion: severidades, umbrales derivados y circuitos de eventos activos."
  value       = module.monitoring.alerting
}

output "traceability" {
  value = module.account_baseline.traceability
}

output "cmk_authorized_services" {
  value = module.kms.authorized_services
}
