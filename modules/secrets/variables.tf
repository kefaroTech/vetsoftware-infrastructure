variable "name" {
  type = string
}

variable "application_secrets_json" {
  description = "JSON con JWT_SECRET, RESEND_API_KEY y RECAPTCHA_SECRET. No se persiste en state."
  type        = string
  sensitive   = true
  ephemeral   = true

  validation {
    condition = try(
      length(jsondecode(var.application_secrets_json).JWT_SECRET) >= 32 &&
      length(jsondecode(var.application_secrets_json).RESEND_API_KEY) > 0 &&
      length(jsondecode(var.application_secrets_json).RECAPTCHA_SECRET) > 0,
      false
    )
    error_message = "application_secrets_json debe incluir JWT_SECRET (mínimo 32 caracteres), RESEND_API_KEY y RECAPTCHA_SECRET no vacíos."
  }
}

variable "grafana_secrets_json" {
  description = "JSON con OTLP_USERNAME y OTLP_API_KEY; puede incluir OTEL_EXPORTER_OTLP_HEADERS para exportación directa. No se persiste en state."
  type        = string
  sensitive   = true
  ephemeral   = true

  validation {
    condition = try(
      length(jsondecode(var.grafana_secrets_json).OTLP_USERNAME) > 0 &&
      length(jsondecode(var.grafana_secrets_json).OTLP_API_KEY) > 0,
      false
    )
    error_message = "grafana_secrets_json debe incluir OTLP_USERNAME y OTLP_API_KEY no vacíos."
  }
}

variable "cloudflare_tunnel_token" {
  description = "Token del tunel remoto de Cloudflare. No se persiste en state."
  type        = string
  sensitive   = true
  ephemeral   = true

  validation {
    condition     = length(trimspace(var.cloudflare_tunnel_token)) >= 32
    error_message = "cloudflare_tunnel_token debe contener el token completo entregado por Cloudflare."
  }
}

variable "application_secret_version" {
  description = "Incremente para rotar los secretos de aplicación."
  type        = number
  default     = 1
}

variable "grafana_secret_version" {
  description = "Incremente para rotar las credenciales de Grafana."
  type        = number
  default     = 1
}

variable "cloudflare_tunnel_token_version" {
  description = "Incremente para rotar el token del tunel Cloudflare."
  type        = number
  default     = 1
}

variable "recovery_window_in_days" {
  type    = number
  default = 7
}

variable "tags" {
  type    = map(string)
  default = {}
}
