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

# ---------------------------------------------------------------------------
# Clave de acceso del envio de logs por Kinesis Firehose
#
# Secreto propio y no una clave mas dentro de grafana-cloud, por dos razones. La
# documentacion de AWS no aclara si Firehose tolera claves hermanas en el
# secreto: solo dice que fallara al conectar si el JSON no tiene el formato
# correcto, y ese fallo es silencioso y en tiempo de entrega. Y los secretos de
# GitHub son de solo escritura, asi que anadir una clave al secreto compartido
# obligaba a reescribir a ciegas las credenciales OTLP que ya funcionan.
#
# El modulo construye el JSON entero para garantizar que dentro no hay nada mas
# que api_key.
# ---------------------------------------------------------------------------

variable "grafana_logs_secret_enabled" {
  description = "Crea el secreto dedicado del que Kinesis Firehose lee la clave de acceso del endpoint de logs."
  type        = bool
  default     = false
}

variable "grafana_logs_access_key" {
  description = "Clave de acceso del endpoint de logs, con el formato <loki_instance_id>:<token>. No se persiste en state."
  type        = string
  sensitive   = true
  ephemeral   = true
  default     = null

  # El formato lo fija Grafana Labs en su plantilla oficial de CloudFormation:
  # AccessKey: !Sub '${LogsInstanceID}:${LogsWriteToken}'. Solo el token, sin el
  # ID de instancia delante, produce un apply verde y un stream que no entrega
  # nada: el peor de los fallos posibles para lo que este modulo viene a evitar.
  validation {
    condition     = !var.grafana_logs_secret_enabled || can(regex("^[0-9]+:.+$", var.grafana_logs_access_key))
    error_message = "grafana_logs_access_key debe ser <loki_instance_id>:<token>, sin espacios alrededor de los dos puntos; solo el token no entrega nada y no da error."
  }
}

variable "grafana_logs_secret_version" {
  description = "Incremente para rotar la clave de acceso del envio de logs."
  type        = number
  default     = 1
}
