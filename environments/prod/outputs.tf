output "api_url" {
  description = "URL pública del backend."
  value       = "https://${var.api_domain_name}"
}

output "alb_dns_name" {
  value = module.alb.dns_name
}

output "cloudflare_tunnel_origin_url" {
  description = "Origen HTTPS privado para la ruta publicada en Cloudflare Tunnel."
  value       = module.alb.origin_url
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
