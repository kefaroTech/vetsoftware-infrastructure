variable "name" {
  type = string
}

variable "aws_region" {
  type = string
}

variable "alarm_email" {
  description = "Correo opcional. La suscripción SNS requiere confirmación."
  type        = string
  default     = ""
}

variable "monthly_budget_usd" {
  description = "Cero deshabilita AWS Budgets."
  type        = number
  default     = 180
}

variable "ecs_cluster_name" {
  type = string
}

variable "ecs_service_name" {
  type = string
}

variable "cloudflare_tunnel_log_group_name" {
  description = "Log group JSON del sidecar cloudflared usado para detectar errores del conector."
  type        = string
}

variable "database_identifier" {
  type = string
}

variable "database_freeable_memory_threshold_bytes" {
  description = "Umbral de memoria libre de RDS; protege especialmente db.t4g.micro en dev."
  type        = number
  default     = 268435456
}

variable "alloy_instance_ids" {
  type = list(string)
}

variable "tags" {
  type    = map(string)
  default = {}
}
