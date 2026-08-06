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

variable "tags" {
  type    = map(string)
  default = {}
}
