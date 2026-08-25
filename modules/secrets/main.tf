resource "aws_secretsmanager_secret" "application" {
  name                    = "${var.name}/application"
  description             = "VetSoftware application runtime secrets"
  recovery_window_in_days = var.recovery_window_in_days
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "application" {
  secret_id = aws_secretsmanager_secret.application.id

  # Las claves son el contrato que leen las definiciones de tarea de ECS por
  # sufijo -"<arn>:JWT_SECRET::"-. No se renombran.
  secret_string_wo = jsonencode({
    JWT_SECRET       = var.jwt_secret
    RESEND_API_KEY   = var.resend_api_key
    RECAPTCHA_SECRET = var.recaptcha_secret
    DIAN_ENC_KEY     = var.dian_enc_key
  })

  secret_string_wo_version = var.application_secret_version
}

resource "aws_secretsmanager_secret" "grafana" {
  name                    = "${var.name}/grafana-cloud"
  description             = "Grafana Cloud OTLP credentials for Alloy"
  recovery_window_in_days = var.recovery_window_in_days
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "grafana" {
  secret_id = aws_secretsmanager_secret.grafana.id

  # OTEL_EXPORTER_OTLP_HEADERS la lee el backend por su nombre exacto; las otras
  # dos las consumen el sidecar colector -basicauth- y Alloy.
  secret_string_wo = jsonencode({
    OTLP_USERNAME              = var.otlp_username
    OTLP_API_KEY               = var.otlp_api_key
    OTEL_EXPORTER_OTLP_HEADERS = var.otel_exporter_otlp_headers
  })

  secret_string_wo_version = var.grafana_secret_version
}

resource "aws_secretsmanager_secret" "cloudflare_tunnel" {
  name                    = "${var.name}/cloudflare-tunnel"
  description             = "Token for the remotely managed Cloudflare Tunnel connector"
  recovery_window_in_days = var.recovery_window_in_days
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "cloudflare_tunnel" {
  secret_id                = aws_secretsmanager_secret.cloudflare_tunnel.id
  secret_string_wo         = var.cloudflare_tunnel_token
  secret_string_wo_version = var.cloudflare_tunnel_token_version
}

# La lee Kinesis Firehose por su cuenta -secrets_manager_configuration- en cada
# entrega, no Terraform y no la aplicacion. El JSON se arma aqui para que el
# secreto contenga exactamente una clave y nada mas.
resource "aws_secretsmanager_secret" "grafana_logs" {
  count = var.grafana_logs_secret_enabled ? 1 : 0

  name                    = "${var.name}/grafana-cloud-logs"
  description             = "Grafana Cloud logs access key consumed by Kinesis Firehose"
  recovery_window_in_days = var.recovery_window_in_days
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "grafana_logs" {
  count = var.grafana_logs_secret_enabled ? 1 : 0

  secret_id                = aws_secretsmanager_secret.grafana_logs[0].id
  secret_string_wo         = jsonencode({ api_key = var.grafana_logs_access_key })
  secret_string_wo_version = var.grafana_logs_secret_version
}
