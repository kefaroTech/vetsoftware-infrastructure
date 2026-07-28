output "application_secret_arn" {
  value = aws_secretsmanager_secret.application.arn
}

output "grafana_secret_arn" {
  value = aws_secretsmanager_secret.grafana.arn
}
