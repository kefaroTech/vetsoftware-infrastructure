variable "name" {
  type = string
}

variable "image_uri" {
  description = "Imagen inmutable del backend, preferiblemente con digest o tag de versión."
  type        = string

  validation {
    condition     = length(trimspace(var.image_uri)) > 0 && !endswith(var.image_uri, ":latest")
    error_message = "image_uri es obligatorio y no debe usar el tag mutable :latest."
  }
}

variable "subnet_ids" {
  type = list(string)
}

variable "security_group_ids" {
  type = list(string)
}

variable "target_group_arn" {
  type = string
}

variable "container_port" {
  type    = number
  default = 8080
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
  description = "Peso de Spot para capacidad adicional. La primera tarea siempre es On-Demand."
  type        = number
  default     = 0
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

variable "application_bucket_arn" {
  type = string
}

variable "firehose_stream_arn" {
  type = string
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
