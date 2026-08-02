variable "name" {
  description = "Prefijo de recursos."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR principal de la VPC."
  type        = string
  default     = "10.40.0.0/16"
}

variable "availability_zone_count" {
  description = "Cantidad de AZ. Las capas de datos y la distribución de tareas requieren al menos dos."
  type        = number
  default     = 2

  validation {
    condition     = var.availability_zone_count >= 2 && var.availability_zone_count <= 3
    error_message = "availability_zone_count debe estar entre 2 y 3."
  }
}

variable "enable_s3_gateway_endpoint" {
  description = "Crea el endpoint S3 gratuito en las tablas de rutas."
  type        = bool
  default     = true
}

variable "kms_key_arn" {
  description = "CMK usada para cifrar los VPC Flow Logs."
  type        = string
}

variable "flow_log_retention_days" {
  type    = number
  default = 30
}

variable "tags" {
  type    = map(string)
  default = {}
}
