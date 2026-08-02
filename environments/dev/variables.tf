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

variable "shared_environment" {
  description = "Entorno cuya VPC y ALB se reutilizan."
  type        = string
  default     = "prod"
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

variable "shared_alb_listener_port" {
  description = "Puerto del listener existente en el ALB compartido. Normalmente 443."
  type        = number
  default     = 443
}

variable "shared_listener_rule_priority" {
  type    = number
  default = 200

  validation {
    condition     = var.shared_listener_rule_priority >= 1 && var.shared_listener_rule_priority <= 50000
    error_message = "shared_listener_rule_priority debe estar entre 1 y 50000 y ser único en el listener."
  }
}

variable "confirm_shared_certificate_covers_domain" {
  description = "Confirma que el certificado del listener HTTPS incluye api_domain_name como SAN o wildcard."
  type        = bool
  default     = false
}

variable "api_domain_name" {
  description = "Host exclusivo de dev usado por la regla del ALB compartido."
  type        = string

  validation {
    condition     = length(trimspace(var.api_domain_name)) > 0
    error_message = "api_domain_name es obligatorio para enrutar dev por host."
  }
}

variable "route53_zone_id" {
  type = string
}

variable "backend_image_uri" {
  description = "Imagen ARM64 inmutable del backend. No use :latest."
  type        = string
}

variable "backend_health_check_path" {
  description = "Endpoint único de readiness para ALB y ECS."
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
  default = 1
}

variable "valkey_major_engine_version" {
  type    = string
  default = "8"
}

variable "valkey_password_version" {
  type    = number
  default = 1
}

variable "valkey_maximum_data_storage_gb" {
  type    = number
  default = 1
}

variable "valkey_maximum_ecpu_per_second" {
  type    = number
  default = 1000
}

variable "application_secret_version" {
  type    = number
  default = 1
}

variable "grafana_secret_version" {
  type    = number
  default = 1
}

variable "application_secrets_json" {
  description = "JSON con JWT_SECRET, RESEND_API_KEY y RECAPTCHA_SECRET."
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
  type    = string
  default = ""
}

variable "monthly_budget_usd" {
  type    = number
  default = 50
}

variable "scheduled_shutdown_enabled" {
  type    = bool
  default = true
}

variable "schedule_timezone" {
  type    = string
  default = "America/Bogota"
}

variable "database_start_schedule" {
  type    = string
  default = "cron(30 7 ? * MON-FRI *)"
}

variable "backend_start_schedule" {
  type    = string
  default = "cron(0 8 ? * MON-FRI *)"
}

variable "backend_stop_schedule" {
  type    = string
  default = "cron(0 20 ? * MON-FRI *)"
}

variable "database_stop_schedule" {
  type    = string
  default = "cron(15 20 ? * MON-FRI *)"
}
