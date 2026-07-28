variable "name" {
  type = string
}

variable "account_id" {
  type = string
}

variable "aws_region" {
  type = string
}

variable "application_bucket_name" {
  type    = string
  default = ""
}

variable "audit_bucket_name" {
  type    = string
  default = ""
}

variable "delivery_stream_name" {
  type    = string
  default = ""
}

variable "audit_retention_days" {
  description = "Retención WORM. COMPLIANCE no permite acortarla ni borrar objetos."
  type        = number
  default     = 365

  validation {
    condition     = var.audit_retention_days >= 365
    error_message = "audit_retention_days debe ser al menos 365."
  }
}

variable "transition_to_glacier_days" {
  type    = number
  default = 30
}

variable "application_noncurrent_expiration_days" {
  type    = number
  default = 90
}

variable "firehose_buffer_interval" {
  type    = number
  default = 300
}

variable "firehose_buffer_size" {
  type    = number
  default = 1
}

variable "log_retention_days" {
  type    = number
  default = 30
}

variable "tags" {
  type    = map(string)
  default = {}
}
