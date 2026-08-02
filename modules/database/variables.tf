variable "name" {
  type = string
}

variable "subnet_ids" {
  type = list(string)
}

variable "security_group_ids" {
  type = list(string)
}

variable "database_name" {
  type    = string
  default = "vetsoftware"
}

variable "master_username" {
  type    = string
  default = "vetsoftware_admin"
}

variable "engine_version" {
  description = "Versión MySQL compatible con RDS."
  type        = string
  default     = "8.4"
}

variable "parameter_group_family" {
  type    = string
  default = "mysql8.4"
}

variable "instance_class" {
  description = "Ejemplos: db.t4g.micro, db.t4g.small, db.t4g.medium."
  type        = string
  default     = "db.t4g.small"
}

variable "allocated_storage" {
  type    = number
  default = 20
}

variable "max_allocated_storage" {
  type    = number
  default = 100

  validation {
    condition     = var.max_allocated_storage == 0 || var.max_allocated_storage >= var.allocated_storage
    error_message = "max_allocated_storage debe ser 0 para deshabilitar autoescalado o mayor o igual a allocated_storage."
  }
}

variable "multi_az" {
  type    = bool
  default = false
}

variable "backup_retention_period" {
  type    = number
  default = 7

  validation {
    condition     = var.backup_retention_period >= 7 && var.backup_retention_period <= 35
    error_message = "backup_retention_period debe estar entre 7 y 35 dias."
  }
}

variable "performance_insights_enabled" {
  type    = bool
  default = true
}

variable "apply_immediately" {
  type    = bool
  default = false
}

variable "tags" {
  type    = map(string)
  default = {}
}
