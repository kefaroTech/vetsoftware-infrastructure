variable "name" {
  type = string
}

variable "image_uri" {
  description = "Imagen ECR inmutable del backend fijada por digest sha256."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}\\.dkr\\.ecr\\.[a-z0-9-]+\\.amazonaws\\.com(\\.cn)?/vetsoftware(-dev)?-backend@sha256:[0-9a-f]{64}$", var.image_uri))
    error_message = "image_uri debe usar el repositorio backend de dev o prod fijado con @sha256:<64 hex>."
  }
}

variable "subnet_ids" {
  type = list(string)
}

variable "security_group_ids" {
  type = list(string)
}

variable "container_port" {
  type    = number
  default = 8080
}

variable "health_check_path" {
  description = "Endpoint de readiness usado por Docker y ECS antes de iniciar cloudflared."
  type        = string
  default     = "/api/v1/actuator/health/readiness"

  validation {
    condition     = startswith(var.health_check_path, "/")
    error_message = "health_check_path debe ser una ruta absoluta."
  }
}

variable "cpu" {
  description = "Unidades Fargate: 1024 = 1 vCPU."
  type        = number
  default     = 1024
}

variable "memory" {
  description = "Memoria Fargate en MiB."
  type        = number
  default     = 4096
}

variable "ephemeral_storage_gib" {
  type    = number
  default = 20

  validation {
    condition     = var.ephemeral_storage_gib >= 20 && var.ephemeral_storage_gib <= 200
    error_message = "ephemeral_storage_gib debe estar entre 20 y 200."
  }
}

variable "cpu_architecture" {
  type    = string
  default = "ARM64"

  validation {
    condition     = contains(["ARM64", "X86_64"], var.cpu_architecture)
    error_message = "cpu_architecture debe ser ARM64 o X86_64."
  }
}

variable "desired_count" {
  type    = number
  default = 1
}

variable "min_count" {
  type    = number
  default = 1
}

variable "max_count" {
  type    = number
  default = 4
}

variable "assign_public_ip" {
  description = "Necesario sin NAT para pulls y APIs externas. El SG impide acceso directo."
  type        = bool
  default     = true
}

variable "fargate_spot_weight" {
  description = "Peso de Fargate Spot. Use fargate_base=0 y fargate_weight=0 para ejecutar solo en Spot."
  type        = number
  default     = 0

  validation {
    condition     = var.fargate_spot_weight >= 0
    error_message = "fargate_spot_weight no puede ser negativo."
  }
}

variable "fargate_base" {
  description = "Cantidad base reservada en Fargate On-Demand antes de distribuir por pesos."
  type        = number
  default     = 1

  validation {
    condition     = var.fargate_base >= 0
    error_message = "fargate_base no puede ser negativo."
  }
}

variable "fargate_weight" {
  description = "Peso de Fargate On-Demand en la estrategia de capacidad."
  type        = number
  default     = 1

  validation {
    condition     = var.fargate_weight >= 0
    error_message = "fargate_weight no puede ser negativo."
  }
}

variable "environment_variables" {
  type    = map(string)
  default = {}
}

variable "secrets" {
  description = "Mapa nombre de variable => ARN[:json-key::] de Secrets Manager."
  type        = map(string)
  default     = {}
}

variable "runtime_secret_arns" {
  description = "ARN base de los secretos que ECS puede leer."
  type        = list(string)
}

variable "cloudflare_tunnel_secret_arn" {
  description = "ARN del secreto que contiene el token del tunel remoto Cloudflare."
  type        = string
}

variable "cloudflare_tunnel_image" {
  description = "Imagen cloudflared inmutable y multi-arquitectura."
  type        = string
  default     = "cloudflare/cloudflared@sha256:5e49861633763e8933475477c20bae6039ed47f32c1d267a34babc347f28f0df"

  validation {
    condition     = can(regex("@sha256:[0-9a-f]{64}$", var.cloudflare_tunnel_image))
    error_message = "cloudflare_tunnel_image debe fijarse por digest sha256."
  }
}

variable "cloudflare_tunnel_cpu" {
  type    = number
  default = 64
}

variable "cloudflare_tunnel_memory" {
  description = "Memoria del sidecar cloudflared en MiB."
  type        = number
  default     = 128
}

variable "application_bucket_arn" {
  type = string
}

variable "kms_key_arn" {
  description = "CMK para datos S3 y grupos de logs de la aplicacion."
  type        = string
}

variable "firehose_stream_arn" {
  description = "Firehose opcional. Vacío omite el permiso de auditoría, útil en dev."
  type        = string
  default     = ""
}

variable "database_connect_resource_arns" {
  description = "ARN dbuser autorizados para migrar el cliente a RDS IAM DB Auth."
  type        = list(string)
  default     = []
}

variable "log_retention_days" {
  type    = number
  default = 30
}

variable "enable_container_insights" {
  type    = bool
  default = false
}

variable "enable_execute_command" {
  type    = bool
  default = true
}

variable "health_check_grace_period_seconds" {
  type    = number
  default = 120
}

variable "autoscaling_cpu_target" {
  type    = number
  default = 65
}

variable "autoscaling_memory_target" {
  type    = number
  default = 75
}

variable "tags" {
  type    = map(string)
  default = {}
}
