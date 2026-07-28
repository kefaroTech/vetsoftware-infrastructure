variable "project_name" {
  description = "Nombre corto del proyecto."
  type        = string
  default     = "vetsoftware"

  validation {
    condition     = can(regex("^[a-z0-9-]{3,30}$", var.project_name))
    error_message = "project_name debe usar minúsculas, números y guiones."
  }
}

variable "environment" {
  description = "Nombre del ambiente."
  type        = string
  default     = "prod"

  validation {
    condition     = can(regex("^[a-z0-9-]{2,15}$", var.environment))
    error_message = "environment debe usar minúsculas, números y guiones."
  }
}

variable "aws_region" {
  description = "Región donde se almacena el estado."
  type        = string
  default     = "us-east-1"
}

variable "state_bucket_name" {
  description = "Nombre opcional del bucket. Vacío genera uno estable con account ID."
  type        = string
  default     = ""
}

variable "enable_kms" {
  description = "Crea una KMS key dedicada para el estado. Agrega aproximadamente USD 1/mes."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Etiquetas adicionales."
  type        = map(string)
  default     = {}
}
