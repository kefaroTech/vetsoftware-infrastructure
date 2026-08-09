variable "name" {
  description = "Nombre de la función, del schedule y del log group."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9-]{3,60}$", var.name))
    error_message = "name debe usar minusculas, numeros y guiones."
  }
}

variable "aws_account_id" {
  description = "Cuenta cuyo gasto se informa. Va en el mensaje, porque Cost Explorer factura por cuenta y no por ambiente."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "aws_account_id debe tener 12 digitos."
  }
}

variable "aws_region" {
  description = "Region del topic, para acotar el permiso de KMS con kms:ViaService."
  type        = string
}

variable "aws_partition" {
  description = "Particion AWS, para armar el ARN del log group sin depender del recurso."
  type        = string
  default     = "aws"
}

variable "topic_arn" {
  description = "Topic de finops que ya escucha Amazon Q Developer."
  type        = string

  validation {
    condition     = can(regex("^arn:[^:]+:sns:", var.topic_arn))
    error_message = "topic_arn debe ser el ARN de un topic SNS."
  }
}

variable "kms_key_arn" {
  description = "CMK que cifra el topic y el log group."
  type        = string

  validation {
    condition     = can(regex("^arn:[^:]+:kms:", var.kms_key_arn))
    error_message = "kms_key_arn debe ser el ARN de una KMS key."
  }
}

variable "schedule_expression" {
  description = "Cuando corre el informe. Cubre siempre el dia anterior."
  type        = string
  default     = "cron(0 7 * * ? *)"
}

variable "schedule_timezone" {
  description = "Zona del schedule. EventBridge la respeta, que es justamente lo que el cron de GitHub no hacia."
  type        = string
  default     = "America/Bogota"
}

variable "log_retention_days" {
  description = "Caducidad del log de la función."
  type        = number
  default     = 30

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.log_retention_days)
    error_message = "log_retention_days debe ser un valor de retencion valido de CloudWatch Logs y nunca 0."
  }
}

variable "enabled" {
  description = "Permite apagar el informe sin destruir la función."
  type        = bool
  default     = true
}

variable "tags" {
  type    = map(string)
  default = {}
}
