variable "name" {
  type = string
}

# ---------------------------------------------------------------------------
# Un secreto, una variable. El JSON lo compone este modulo.
#
# Antes entraban dos blobs JSON ya armados desde fuera y eso tenia dos costes.
# La validacion solo podia mirar dentro con jsondecode envuelto en try, asi que
# un JSON mal formado no distinguia "falta una clave" de "faltan las comillas".
# Y quien producia el blob -un secreto de GitHub, de solo escritura- decidia los
# nombres de clave sin que nada los verificase.
#
# Los nombres de clave del JSON son CONTRATO: las definiciones de tarea de ECS
# los leen por sufijo -"<arn>:JWT_SECRET::"- en los dos entornos. Renombrar una
# clave aqui no rompe ningun plan: rompe el arranque del contenedor.
# ---------------------------------------------------------------------------

variable "jwt_secret" {
  description = "Clave de firma de los JWT; viaja al secreto de aplicacion bajo la clave JWT_SECRET. No se persiste en state."
  type        = string
  sensitive   = true
  ephemeral   = true

  validation {
    condition     = length(var.jwt_secret) >= 32
    error_message = "jwt_secret debe tener al menos 32 caracteres."
  }
}

variable "resend_api_key" {
  description = "Clave de API de Resend para el envio de correo; clave RESEND_API_KEY del secreto de aplicacion. No se persiste en state."
  type        = string
  sensitive   = true
  ephemeral   = true

  validation {
    condition     = length(var.resend_api_key) > 0
    error_message = "resend_api_key no puede estar vacio."
  }
}

variable "recaptcha_secret" {
  description = "Secreto de servidor de reCAPTCHA; clave RECAPTCHA_SECRET del secreto de aplicacion. No se persiste en state."
  type        = string
  sensitive   = true
  ephemeral   = true

  validation {
    condition     = length(var.recaptcha_secret) > 0
    error_message = "recaptcha_secret no puede estar vacio."
  }
}

variable "dian_enc_key" {
  description = "Clave AES-256 -32 bytes en base64- del cifrado de campos DIAN; clave DIAN_ENC_KEY del secreto de aplicacion. No se persiste en state."
  type        = string
  sensitive   = true
  ephemeral   = true

  validation {
    condition     = length(var.dian_enc_key) > 0
    error_message = "dian_enc_key no puede estar vacio."
  }
}

variable "otlp_username" {
  description = "Numeric instance ID de Grafana Cloud usado como usuario OTLP; clave OTLP_USERNAME del secreto de Grafana. No se persiste en state."
  type        = string
  sensitive   = true
  ephemeral   = true

  validation {
    condition     = length(var.otlp_username) > 0
    error_message = "otlp_username no puede estar vacio."
  }
}

variable "otlp_api_key" {
  description = "Token de la Cloud Access Policy usado como contrasena OTLP; clave OTLP_API_KEY del secreto de Grafana. No se persiste en state."
  type        = string
  sensitive   = true
  ephemeral   = true

  validation {
    condition     = length(var.otlp_api_key) > 0
    error_message = "otlp_api_key no puede estar vacio."
  }
}

variable "otel_exporter_otlp_headers" {
  description = "Cabecera ya construida -Authorization=Basic <base64 usuario:token>- que exporta el SDK; clave OTEL_EXPORTER_OTLP_HEADERS del secreto de Grafana. No se persiste en state."
  type        = string
  sensitive   = true
  ephemeral   = true

  validation {
    condition     = length(var.otel_exporter_otlp_headers) > 0
    error_message = "otel_exporter_otlp_headers no puede estar vacio."
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
