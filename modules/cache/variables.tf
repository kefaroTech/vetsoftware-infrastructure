variable "name" {
  type = string
}

variable "subnet_ids" {
  type = list(string)
}

variable "security_group_ids" {
  type = list(string)
}

variable "major_engine_version" {
  type    = string
  default = "8"
}

variable "user_name" {
  type    = string
  default = "vetsoftware"
}

variable "password_version" {
  description = "Incremente para rotar coordinadamente RBAC y el secreto REDIS_URL."
  type        = number
  default     = 1
}

variable "daily_snapshot_time" {
  type    = string
  default = "05:00"
}

variable "snapshot_retention_limit" {
  type    = number
  default = 7
}

variable "maximum_data_storage_gb" {
  description = "Límite de crecimiento para controlar costos del cache serverless."
  type        = number
  default     = 10

  validation {
    condition     = var.maximum_data_storage_gb >= 1 && var.maximum_data_storage_gb <= 5000
    error_message = "maximum_data_storage_gb debe estar entre 1 y 5000."
  }
}

variable "maximum_ecpu_per_second" {
  description = "Máximo de ECPU por segundo permitido al cache serverless."
  type        = number
  default     = 5000

  validation {
    condition     = var.maximum_ecpu_per_second >= 1000 && var.maximum_ecpu_per_second <= 15000000
    error_message = "maximum_ecpu_per_second debe estar entre 1000 y 15000000."
  }
}

variable "tags" {
  type    = map(string)
  default = {}
}
