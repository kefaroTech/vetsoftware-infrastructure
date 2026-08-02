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

variable "database_start_schedule" {
  description = "RDS arranca antes que ECS para estar disponible durante el despliegue de la tarea."
  type        = string
  default     = "cron(30 7 ? * MON-FRI *)"
}

variable "backend_start_schedule" {
  type    = string
  default = "cron(0 8 ? * MON-FRI *)"
}

variable "backend_stop_schedule" {
  type    = string
  default = "cron(0 20 ? * MON-FRI *)"
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
