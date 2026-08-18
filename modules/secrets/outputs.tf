output "application_secret_arn" {
  value = aws_secretsmanager_secret.application.arn
}

output "grafana_secret_arn" {
  value = aws_secretsmanager_secret.grafana.arn
}

output "cloudflare_tunnel_secret_arn" {
  value = aws_secretsmanager_secret.cloudflare_tunnel.arn
}

output "grafana_logs_secret_arn" {
  description = "Secreto dedicado del que Firehose lee la clave de acceso del endpoint de logs; vacio cuando el envio esta apagado."
  value       = var.grafana_logs_secret_enabled ? aws_secretsmanager_secret.grafana_logs[0].arn : ""
}

# El nombre y no el ARN: el nombre se conoce en plan, asi que los contratos de
# entorno pueden afirmar que el envio de logs lee de su secreto propio y no del
# compartido con OTLP, que es justo la separacion que se vino a garantizar.
output "grafana_logs_secret_name" {
  description = "Nombre del secreto dedicado del envio de logs; vacio cuando el envio esta apagado."
  value       = var.grafana_logs_secret_enabled ? aws_secretsmanager_secret.grafana_logs[0].name : ""
}
