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
  default = "prod"

  validation {
    condition     = can(regex("^[a-z0-9-]{2,12}$", var.environment))
    error_message = "environment debe usar minúsculas, números y guiones."
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
    CostCenter = "production"
  }
}

variable "vpc_cidr" {
  type    = string
  default = "10.40.0.0/16"
}

variable "availability_zone_count" {
  type    = number
  default = 2
}

variable "api_domain_name" {
  type = string

  validation {
    condition     = length(trimspace(var.api_domain_name)) > 0
    error_message = "api_domain_name es obligatorio para Cloudflare Tunnel."
  }
}

variable "approved_external_https_ipv4_cidrs" {
  description = "CIDR de Resend, reCAPTCHA, Grafana u otros SaaS autorizados para salida HTTPS."
  type        = list(string)

  validation {
    condition = (
      length(var.approved_external_https_ipv4_cidrs) > 0 &&
      alltrue([
        for cidr in var.approved_external_https_ipv4_cidrs :
        can(cidrnetmask(cidr)) && cidr != "0.0.0.0/0"
      ])
    )
    error_message = "approved_external_https_ipv4_cidrs exige CIDR especificos y prohibe 0.0.0.0/0."
  }
}

variable "certificate_arn" {
  description = "Certificado ACM emitido que cubre api_domain_name y el hostname de dev."
  type        = string
}

variable "alb_deletion_protection" {
  type    = bool
  default = true
}

variable "backend_image_uri" {
  description = "Imagen Spring Boot publicada. No use :latest."
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
  default = 1024
}

variable "backend_memory" {
  type    = number
  default = 4096
}

variable "backend_desired_count" {
  type    = number
  default = 1
}

variable "backend_min_count" {
  type    = number
  default = 1
}

variable "backend_max_count" {
  type    = number
  default = 4
}

variable "backend_fargate_spot_weight" {
  type    = number
  default = 0
}

variable "backend_container_insights" {
  type    = bool
  default = false
}

variable "backend_extra_environment" {
  type    = map(string)
  default = {}
}

variable "pdf_max_concurrent_renders" {
  description = "Máximo de PDFs renderizados simultáneamente por tarea Fargate."
  type        = number
  default     = 2

  validation {
    condition     = var.pdf_max_concurrent_renders >= 1
    error_message = "pdf_max_concurrent_renders debe ser al menos 1."
  }
}

variable "pdf_acquire_timeout" {
  description = "Tiempo máximo que una solicitud espera por un cupo de render."
  type        = string
  default     = "30s"
}

variable "pdf_max_html_size" {
  description = "Tamaño máximo del HTML procesado por OpenHTMLToPDF."
  type        = string
  default     = "5MB"
}

variable "pdf_max_pdf_size" {
  description = "Tamaño máximo del PDF generado en memoria."
  type        = string
  default     = "25MB"
}

variable "alloy_instance_type" {
  type    = string
  default = "t4g.micro"
}

variable "alloy_instance_count" {
  description = "Mantenga 1 mientras use un gateway único; escalar requiere distribución consciente de trazas."
  type        = number
  default     = 1
}

variable "alloy_root_volume_size" {
  type    = number
  default = 8
}

variable "alloy_image" {
  type    = string
  default = "grafana/alloy:v1.18.0"
}

variable "alloy_container_memory_limit" {
  type    = string
  default = "700m"
}

variable "alloy_container_cpu_limit" {
  type    = string
  default = "1.0"
}

variable "alloy_pipeline_memory_limit" {
  type    = string
  default = "450MiB"
}

variable "alloy_pipeline_spike_limit" {
  type    = string
  default = "90MiB"
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
  default = "db.t4g.small"
}

variable "database_allocated_storage" {
  type    = number
  default = 20
}

variable "database_max_allocated_storage" {
  type    = number
  default = 100
}

variable "database_multi_az" {
  type    = bool
  default = false
}

variable "database_backup_retention_days" {
  type    = number
  default = 7
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
  default = 10
}

variable "valkey_maximum_ecpu_per_second" {
  type    = number
  default = 5000
}

variable "application_secret_version" {
  type    = number
  default = 1
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
  description = "JSON: JWT_SECRET, RESEND_API_KEY, RECAPTCHA_SECRET."
  type        = string
  sensitive   = true
  ephemeral   = true
}

variable "grafana_secrets_json" {
  description = "JSON: OTLP_USERNAME, OTLP_API_KEY."
  type        = string
  sensitive   = true
  ephemeral   = true
}

variable "cloudflare_tunnel_token" {
  description = "Token del tunel remoto de produccion; inyectar mediante TF_VAR."
  type        = string
  sensitive   = true
  ephemeral   = true
}

variable "grafana_otlp_endpoint" {
  description = "Base OTLP, por ejemplo https://...grafana.net/otlp."
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
  default = 1.0

  validation {
    condition     = var.tracing_sampling >= 0 && var.tracing_sampling <= 1
    error_message = "tracing_sampling debe estar entre 0 y 1."
  }
}

variable "audit_retention_days" {
  type    = number
  default = 365
}

variable "application_bucket_name" {
  type    = string
  default = ""
}

variable "audit_bucket_name" {
  type    = string
  default = ""
}

variable "alarm_email" {
  type    = string
  default = ""
}

variable "monthly_budget_usd" {
  type    = number
  default = 180
}

variable "log_retention_days" {
  type    = number
  default = 30
}
