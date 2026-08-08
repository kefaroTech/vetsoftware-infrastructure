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

variable "enabled_log_exports" {
  description = "Logs de MySQL que RDS publica en CloudWatch. Cada valor crea su log group gestionado."
  type        = list(string)
  default     = ["error", "slowquery"]

  validation {
    condition     = !contains(var.enabled_log_exports, "general")
    error_message = "El log 'general' registra el texto de cada consulta, con datos personales de titulares. Ley 1581 de 2012, principio de finalidad y temporalidad."
  }

  validation {
    condition     = alltrue([for log in var.enabled_log_exports : contains(["error", "slowquery", "audit"], log)])
    error_message = "enabled_log_exports solo admite error, slowquery o audit."
  }

  validation {
    condition     = length(var.enabled_log_exports) == length(distinct(var.enabled_log_exports))
    error_message = "enabled_log_exports no admite valores repetidos: cada uno crea un log group."
  }
}

variable "log_retention_days" {
  description = "Caducidad de los log groups de la instancia. Sin esto RDS los crea con retencion infinita."
  type        = number
  default     = 30

  # CloudWatch solo acepta esta lista cerrada, y el 0 significa "nunca caduca",
  # que es justo lo que se esta corrigiendo. Un valor fuera de rango falla en el
  # apply, no en el plan, asi que se rechaza aqui.
  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.log_retention_days)
    error_message = "log_retention_days debe ser un valor de retencion valido de CloudWatch Logs y nunca 0 -conservar para siempre-."
  }
}

variable "kms_key_arn" {
  description = "CMK del entorno que cifra los log groups de la instancia."
  type        = string
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
