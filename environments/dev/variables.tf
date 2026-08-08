variable "project_name" {
  type    = string
  default = "vetsoftware"

  validation {
    condition     = can(regex("^[a-z0-9-]{3,20}$", var.project_name))
    error_message = "project_name debe usar minúsculas, números y guiones."
  }
}

variable "environment" {
  type    = string
  default = "dev"

  validation {
    condition     = var.environment == "dev"
    error_message = "Este root module administra exclusivamente el entorno dev."
  }
}

variable "vpc_cidr" {
  description = "CIDR exclusivo de la VPC de desarrollo. No debe solaparse con el de produccion."
  type        = string
  default     = "10.50.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr debe ser un bloque CIDR IPv4 valido."
  }
}

variable "availability_zone_count" {
  description = "Cantidad de AZ propias de dev. Las subredes de datos exigen al menos dos."
  type        = number
  default     = 2

  validation {
    condition     = var.availability_zone_count >= 2 && var.availability_zone_count <= 3
    error_message = "availability_zone_count debe estar entre 2 y 3."
  }
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "tags" {
  type = map(string)
  default = {
    Owner      = "VetSoftware"
    CostCenter = "development"
  }
}

variable "api_domain_name" {
  description = "Host publico exclusivo de dev publicado mediante Cloudflare Tunnel."
  type        = string

  validation {
    condition     = length(trimspace(var.api_domain_name)) > 0
    error_message = "api_domain_name es obligatorio para enrutar dev por host."
  }
}

variable "backend_image_uri" {
  description = "Imagen ARM64 de vetsoftware-dev-backend fijada por digest ECR."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}\\.dkr\\.ecr\\.[a-z0-9-]+\\.amazonaws\\.com(\\.cn)?/vetsoftware-dev-backend@sha256:[0-9a-f]{64}$", var.backend_image_uri))
    error_message = "backend_image_uri debe usar vetsoftware-dev-backend@sha256:<64 hex>; los tags no son desplegables."
  }
}

variable "backend_health_check_path" {
  description = "Endpoint de readiness usado por ECS antes de iniciar cloudflared."
  type        = string
  default     = "/api/v1/actuator/health/readiness"
}

variable "backend_cpu_architecture" {
  type    = string
  default = "ARM64"
}

variable "backend_cpu" {
  type    = number
  default = 512
}

variable "backend_memory" {
  type    = number
  default = 2048
}

variable "backend_extra_environment" {
  type    = map(string)
  default = {}
}

variable "backend_container_insights" {
  type    = bool
  default = false
}

variable "pdf_max_concurrent_renders" {
  type    = number
  default = 1
}

variable "pdf_acquire_timeout" {
  type    = string
  default = "30s"
}

variable "pdf_max_html_size" {
  type    = string
  default = "5MB"
}

variable "pdf_max_pdf_size" {
  type    = string
  default = "15MB"
}

variable "database_name" {
  type    = string
  default = "vetsoftware"
}

variable "database_master_username" {
  type    = string
  default = "vetsoftware_admin"
}

variable "database_engine_version" {
  type    = string
  default = "8.4"
}

variable "database_parameter_group_family" {
  type    = string
  default = "mysql8.4"
}

variable "database_instance_class" {
  type    = string
  default = "db.t4g.micro"
}

variable "database_allocated_storage" {
  type    = number
  default = 20
}

variable "database_max_allocated_storage" {
  description = "Cero deshabilita Storage Autoscaling para fijar el costo de dev."
  type        = number
  default     = 0
}

variable "database_backup_retention_days" {
  type    = number
  default = 7

  validation {
    condition     = var.database_backup_retention_days >= 7 && var.database_backup_retention_days <= 35
    error_message = "database_backup_retention_days debe estar entre 7 y 35 dias."
  }
}

variable "valkey_major_engine_version" {
  type    = string
  default = "8"
}

# La contrasena de Valkey se genera en un recurso ephemeral y la consumen dos
# recursos distintos, ambos gobernados por esta version. Una serie de applies
# cortados los dejo escritos en ejecuciones distintas: cada uno capturo un valor
# distinto del ephemeral y, al no cambiar la version, ninguno se reescribio. El
# backend fallaba con "WRONGPASS invalid username-password pair". Subirla a 2
# fuerza a que los dos vuelvan a escribirse en el mismo apply, con el mismo valor.
variable "valkey_password_version" {
  type    = number
  default = 2
}

variable "valkey_maximum_data_storage_gb" {
  type    = number
  default = 1
}

variable "valkey_maximum_ecpu_per_second" {
  type    = number
  default = 1000
}

# El secreto de aplicacion es write-only: Terraform solo lo reescribe cuando cambia
# esta version. Subirla a 2 empuja el JSON que ahora incluye DIAN_ENC_KEY; sin el
# bump, APPLICATION_SECRETS_JSON puede tener la clave y Secrets Manager seguir
# sirviendo el contenido viejo.
variable "application_secret_version" {
  type    = number
  default = 2
}

variable "grafana_secret_version" {
  type    = number
  default = 1
}

variable "cloudflare_tunnel_token_version" {
  type    = number
  default = 1
}

variable "application_secrets_json" {
  description = "JSON con JWT_SECRET, RESEND_API_KEY, RECAPTCHA_SECRET y DIAN_ENC_KEY (AES-256, 32 bytes en base64)."
  type        = string
  sensitive   = true
  ephemeral   = true
}

variable "grafana_secrets_json" {
  description = "JSON con OTLP_USERNAME, OTLP_API_KEY y OTEL_EXPORTER_OTLP_HEADERS."
  type        = string
  sensitive   = true
  ephemeral   = true

  validation {
    condition = try(
      length(jsondecode(var.grafana_secrets_json).OTEL_EXPORTER_OTLP_HEADERS) > 0,
      false
    )
    error_message = "grafana_secrets_json debe incluir OTEL_EXPORTER_OTLP_HEADERS para exportación directa."
  }
}

variable "cloudflare_tunnel_token" {
  description = "Token del tunel remoto de desarrollo; inyectar mediante TF_VAR."
  type        = string
  sensitive   = true
  ephemeral   = true
}

variable "cloudflare_tunnel_ipv4_cidrs" {
  description = "Rangos oficiales usados por los endpoints de Cloudflare Tunnel en el puerto 7844."
  type        = list(string)
  default = [
    "198.41.192.7/32",
    "198.41.192.27/32",
    "198.41.192.37/32",
    "198.41.192.47/32",
    "198.41.192.57/32",
    "198.41.192.67/32",
    "198.41.192.77/32",
    "198.41.192.107/32",
    "198.41.192.167/32",
    "198.41.192.227/32",
    "198.41.200.13/32",
    "198.41.200.23/32",
    "198.41.200.33/32",
    "198.41.200.43/32",
    "198.41.200.53/32",
    "198.41.200.63/32",
    "198.41.200.73/32",
    "198.41.200.113/32",
    "198.41.200.193/32",
    "198.41.200.233/32",
  ]
}

variable "grafana_otlp_endpoint" {
  description = "Base OTLP de Grafana Cloud, terminada normalmente en /otlp."
  type        = string
}

variable "cors_allowed_origins" {
  type = list(string)
}

variable "email_from" {
  type = string
}

variable "registration_verification_url" {
  type = string
}

variable "password_reset_url" {
  type = string
}

variable "login_url" {
  type = string
}

variable "recaptcha_enabled" {
  type    = bool
  default = true
}

variable "tracing_sampling" {
  type    = number
  default = 0.25

  validation {
    condition     = var.tracing_sampling >= 0 && var.tracing_sampling <= 1
    error_message = "tracing_sampling debe estar entre 0 y 1."
  }
}

variable "application_bucket_name" {
  type    = string
  default = ""
}

variable "log_retention_days" {
  type    = number
  default = 3
}

variable "alarm_email" {
  description = "Correo que recibe las notificaciones del topic SNS dev; requiere confirmar la suscripción."
  type        = string
  default     = ""
}

variable "monthly_budget_usd" {
  description = "Presupuesto mensual dev usado por AWS Budgets."
  type        = number
  default     = 35

  validation {
    condition     = var.monthly_budget_usd > 0
    error_message = "monthly_budget_usd debe ser mayor que cero en dev."
  }
}

variable "cost_anomaly_threshold_usd" {
  description = "Impacto absoluto mínimo para avisar una anomalía de costo dev."
  type        = number
  default     = 3

  validation {
    condition     = var.cost_anomaly_threshold_usd > 0
    error_message = "cost_anomaly_threshold_usd debe ser mayor que cero."
  }
}

variable "slack_workspace_id" {
  description = "ID T... del workspace autorizado en Amazon Q Developer; configurar junto con slack_channel_id."
  type        = string
  default     = ""
}

variable "slack_channel_id" {
  description = "ID C... o G... del canal Slack de alertas; configurar junto con slack_workspace_id."
  type        = string
  default     = ""
}

# Vacio deja lo critico en el mismo canal que el informe de costos, que es como
# esta hoy. Con un canal propio, una tarea que muere deja de competir por
# atencion con un aviso de presupuesto.
variable "slack_critical_channel_id" {
  description = "Canal Slack dedicado a alertas criticas de dev. Vacio reutiliza slack_channel_id."
  type        = string
  default     = ""
}

variable "runbook_url" {
  description = "URL del runbook citada en cada notificacion enviada a Slack."
  type        = string
  default     = ""
}

# RDS calcula max_connections como {DBInstanceClassMemory/12582880}. AWS
# documenta que en clases micro la memoria reservada deja el resultado alrededor
# de 60. Reconfirmar con SHOW GLOBAL VARIABLES LIKE 'max_connections' al cambiar
# database_instance_class: si este valor miente, las alarmas de conexiones
# avisan tarde o no avisan.
variable "database_max_connections" {
  description = "max_connections efectivo de la instancia dev; los umbrales de conexiones se derivan de aqui."
  type        = number
  default     = 60

  validation {
    condition     = var.database_max_connections > 0
    error_message = "database_max_connections debe ser mayor que cero."
  }
}

# Solo apaga. El encendido es manual, con el workflow "Start dev environment".
variable "scheduled_shutdown_enabled" {
  type    = bool
  default = true
}

variable "schedule_timezone" {
  type    = string
  default = "America/Bogota"
}

variable "backend_stop_schedule" {
  type    = string
  default = "cron(0 20 ? * MON-FRI *)"
}

variable "database_stop_schedule" {
  type    = string
  default = "cron(15 20 ? * MON-FRI *)"
}
