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
  description = "Cantidad de AZ. ALB y capas de datos requieren al menos dos."
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

variable "tags" {
  type    = map(string)
  default = {}
}
