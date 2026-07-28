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

variable "alb_arn_suffix" {
  type = string
}

variable "target_group_arn_suffix" {
  type = string
}

variable "database_identifier" {
  type = string
}

variable "alloy_instance_ids" {
  type = list(string)
}

variable "tags" {
  type    = map(string)
  default = {}
}
