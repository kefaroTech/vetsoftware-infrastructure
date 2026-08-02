variable "name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  type = list(string)
}

variable "security_group_ids" {
  type = list(string)
}

variable "backend_port" {
  type    = number
  default = 8080
}

variable "health_check_path" {
  type    = string
  default = "/api/v1/actuator/health/readiness"
}

variable "certificate_arn" {
  description = "Certificado ACM emitido que cubre los hostnames del tunel."
  type        = string

  validation {
    condition     = can(regex("^arn:[^:]+:acm:[^:]+:[0-9]{12}:certificate/.+$", var.certificate_arn))
    error_message = "certificate_arn debe ser el ARN de un certificado ACM emitido."
  }
}

variable "ssl_policy" {
  type    = string
  default = "ELBSecurityPolicy-TLS13-1-2-2021-06"
}

variable "enable_deletion_protection" {
  type    = bool
  default = true
}

variable "access_log_retention_days" {
  type    = number
  default = 90
}

variable "kms_key_arn" {
  description = "CMK usada para cifrar el grupo de logs de acceso del ALB."
  type        = string
}

variable "tags" {
  type    = map(string)
  default = {}
}
