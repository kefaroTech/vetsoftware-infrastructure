# Los tres secretos llevan prevent_destroy porque su contenido no esta en
# ningun otro sitio: el valor entra por una variable write-only y Terraform no
# lo guarda en el state. Borrado el secreto, no hay de donde reconstruirlo, y en
# dev ni siquiera hay ventana de recuperacion -recovery_window_in_days = 0-.
resource "aws_secretsmanager_secret" "application" {
  name                    = "${var.name}/application"
  description             = "VetSoftware application runtime secrets"
  recovery_window_in_days = var.recovery_window_in_days
  tags                    = var.tags

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_secretsmanager_secret_version" "application" {
  secret_id                = aws_secretsmanager_secret.application.id
  secret_string_wo         = var.application_secrets_json
  secret_string_wo_version = var.application_secret_version
}

resource "aws_secretsmanager_secret" "grafana" {
  name                    = "${var.name}/grafana-cloud"
  description             = "Grafana Cloud OTLP credentials for Alloy"
  recovery_window_in_days = var.recovery_window_in_days
  tags                    = var.tags

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_secretsmanager_secret_version" "grafana" {
  secret_id                = aws_secretsmanager_secret.grafana.id
  secret_string_wo         = var.grafana_secrets_json
  secret_string_wo_version = var.grafana_secret_version
}

resource "aws_secretsmanager_secret" "cloudflare_tunnel" {
  name                    = "${var.name}/cloudflare-tunnel"
  description             = "Token for the remotely managed Cloudflare Tunnel connector"
  recovery_window_in_days = var.recovery_window_in_days
  tags                    = var.tags

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_secretsmanager_secret_version" "cloudflare_tunnel" {
  secret_id                = aws_secretsmanager_secret.cloudflare_tunnel.id
  secret_string_wo         = var.cloudflare_tunnel_token
  secret_string_wo_version = var.cloudflare_tunnel_token_version
}
