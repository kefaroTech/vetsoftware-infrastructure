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
  description = "Certificado ACM existente. Vacío permite crear uno o usar HTTP."
  type        = string
  default     = ""
}

variable "create_certificate" {
  type    = bool
  default = false
}

variable "domain_name" {
  type    = string
  default = ""
}

variable "route53_zone_id" {
  type    = string
  default = ""
}

variable "ssl_policy" {
  type    = string
  default = "ELBSecurityPolicy-TLS13-1-2-2021-06"
}

variable "enable_deletion_protection" {
  type    = bool
  default = true
}

variable "enable_access_logs" {
  type    = bool
  default = true
}

variable "access_log_retention_days" {
  type    = number
  default = 90
}

variable "account_id" {
  type = string
}

variable "aws_region" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}
