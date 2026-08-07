variable "name" {
  type = string
}

variable "aws_region" {
  type = string
}

variable "sns_kms_key_arn" {
  description = "CMK usada para cifrar el topic SNS de alertas; se recomienda reutilizar la clave de datos del entorno."
  type        = string
  default     = ""
}

# El circuito de imagen y el informe diario de costos avisan a Slack por el mismo
# topic que ya escucha Amazon Q. Se autoriza por policy del topic y no en la policy
# del rol: las inline policies de los roles de GitHub estan cerca del limite de
# 10.240 caracteres, y una autorizacion nombrada aca se aplica con el mismo
# `Terraform apply dev` que crea el topic, sin volver a correr el bootstrap.
variable "notification_publisher_role_arns" {
  description = "Roles autorizados a publicar avisos en el topic de alertas."
  type        = list(string)
  default     = []
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

variable "budget_sns_notifications_enabled" {
  description = "Publica las alertas de AWS Budgets en el topic SNS compartido."
  type        = bool
  default     = false
}

variable "cost_anomaly_detection_enabled" {
  description = "Crea un monitor por servicio y una suscripción inmediata de Cost Anomaly Detection."
  type        = bool
  default     = false
}

variable "cost_anomaly_threshold_usd" {
  description = "Impacto absoluto mínimo en USD para notificar una anomalía."
  type        = number
  default     = 10

  validation {
    condition     = var.cost_anomaly_threshold_usd > 0
    error_message = "cost_anomaly_threshold_usd debe ser mayor que cero."
  }
}

variable "slack_workspace_id" {
  description = "ID del workspace Slack autorizado en Amazon Q Developer; vacío junto con slack_channel_id deshabilita Slack."
  type        = string
  default     = ""

  validation {
    condition = (
      (trimspace(var.slack_workspace_id) == "" && trimspace(var.slack_channel_id) == "") ||
      (
        can(regex("^T[A-Z0-9]+$", var.slack_workspace_id)) &&
        can(regex("^[CG][A-Z0-9]+$", var.slack_channel_id))
      )
    )
    error_message = "slack_workspace_id y slack_channel_id deben configurarse juntos con IDs válidos de Slack."
  }
}

variable "slack_channel_id" {
  description = "ID del canal Slack que recibe alertas; vacío junto con slack_workspace_id deshabilita Slack."
  type        = string
  default     = ""
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
