variable "name" {
  type = string
}

variable "service_name" {
  type = string
}

variable "instance_type" {
  type = string
}

variable "instance_count" {
  type    = number
  default = 1

  validation {
    condition     = var.instance_count >= 1 && var.instance_count <= 5
    error_message = "instance_count debe estar entre 1 y 5."
  }
}

variable "subnet_ids" {
  type = list(string)
}

variable "security_group_ids" {
  type = list(string)
}

variable "ami_ssm_parameter" {
  description = "Parámetro público de AMI. Cambie a x86_64 si la instancia no es ARM."
  type        = string
  default     = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

variable "root_volume_size" {
  type    = number
  default = 10
}

variable "root_volume_type" {
  type    = string
  default = "gp3"
}

variable "associate_public_ip_address" {
  type    = bool
  default = true
}

variable "user_data" {
  type      = string
  sensitive = true
}

variable "secret_arns" {
  description = "Secrets Manager ARNs que el servicio puede leer."
  type        = list(string)
  default     = []
}

variable "log_retention_days" {
  type    = number
  default = 30
}

variable "detailed_monitoring" {
  type    = bool
  default = false
}

variable "disable_api_termination" {
  type    = bool
  default = false
}

variable "tags" {
  type    = map(string)
  default = {}
}
