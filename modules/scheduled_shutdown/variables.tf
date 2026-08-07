variable "name" {
  type = string
}

variable "ecs_cluster_arn" {
  type = string
}

variable "ecs_service_arn" {
  type = string
}

variable "ecs_service_name" {
  type = string
}

variable "database_arn" {
  type = string
}

variable "database_identifier" {
  type = string
}

variable "schedule_timezone" {
  type    = string
  default = "America/Bogota"
}

variable "backend_stop_schedule" {
  description = "ECS se detiene antes que RDS; el encendido no se programa, se hace a mano."
  type        = string
  default     = "cron(0 20 ? * MON-FRI *)"
}

variable "database_stop_schedule" {
  description = "RDS se detiene después de ECS para permitir un cierre ordenado."
  type        = string
  default     = "cron(15 20 ? * MON-FRI *)"
}

variable "enabled" {
  type    = bool
  default = true
}

# El aviso a Slack sale por el topic de alertas que Amazon Q ya escucha, el mismo
# que usa el aviso de despliegue.
variable "stop_notice_enabled" {
  description = "Publica en el topic de alertas un aviso cuando el apagado programado detiene el ambiente."
  type        = bool
  default     = false
}

variable "notification_topic_arn" {
  description = "Topic SNS que recibe el aviso de apagado; obligatorio cuando stop_notice_enabled es true."
  type        = string
  default     = ""

  validation {
    condition     = !var.stop_notice_enabled || trimspace(var.notification_topic_arn) != ""
    error_message = "stop_notice_enabled exige un notification_topic_arn: sin topic no hay donde publicar el aviso."
  }
}

variable "notification_kms_key_arn" {
  description = "CMK que cifra el topic de avisos; vacío si el topic no está cifrado con una clave propia."
  type        = string
  default     = ""
}

variable "tags" {
  type    = map(string)
  default = {}
}
