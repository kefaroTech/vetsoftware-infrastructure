variable "name" {
  type = string
}

variable "deletion_window_in_days" {
  type    = number
  default = 30

  validation {
    condition     = var.deletion_window_in_days >= 7 && var.deletion_window_in_days <= 30
    error_message = "deletion_window_in_days debe estar entre 7 y 30."
  }
}

variable "cost_alerts_sns_enabled" {
  description = "Autoriza a CloudWatch, AWS Budgets y Cost Anomaly Detection a cifrar alertas SNS con esta CMK."
  type        = bool
  default     = false
}

# Publicar en un topic cifrado no es solo SNS:Publish: SNS pide la data key con la
# identidad de quien publica, asi que sin permiso sobre esta CMK el aviso muere con
# un AccessDenied de KMS.
variable "sns_publisher_role_arns" {
  description = "Roles que publican en topics SNS cifrados con esta CMK."
  type        = list(string)
  default     = []
}

variable "tags" {
  type    = map(string)
  default = {}
}
