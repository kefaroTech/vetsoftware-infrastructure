variable "name" {
  description = "Prefijo de los recursos de la linea base. Es de cuenta, no de ambiente."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9-]{3,40}$", var.name))
    error_message = "name debe usar minusculas, numeros y guiones."
  }
}

# La identidad de la cuenta llega como entrada y no desde data sources, igual
# que en github_iac_roles: asi el modulo se planifica y se contrasta sin
# credenciales AWS, que es lo que el gate ejecuta antes de cada commit.
variable "aws_account_id" {
  description = "Cuenta AWS donde vive la linea base."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "aws_account_id debe tener 12 digitos."
  }
}

variable "aws_partition" {
  description = "Particion AWS."
  type        = string
  default     = "aws"
}

variable "aws_region" {
  description = "Region donde se crea el trail. Es multi-region, asi que cubre las demas."
  type        = string
}

variable "kms_key_arn" {
  description = "CMK del entorno que cifra el rastro. Se reutiliza la existente para no anadir el cargo mensual de una clave nueva."
  type        = string

  validation {
    condition     = can(regex("^arn:[^:]+:kms:", var.kms_key_arn))
    error_message = "kms_key_arn debe ser el ARN de una KMS key."
  }
}

variable "regulated_bucket_arns" {
  description = "Buckets cuyos objetos contienen datos personales. Solo se usan si se activan los data events; el access logging se cablea por bucket desde el root."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for arn in var.regulated_bucket_arns : can(regex("^arn:[^:]+:s3:::", arn))])
    error_message = "regulated_bucket_arns debe contener ARNs de bucket S3."
  }

  # El selector usa starts_with sobre resources.ARN y compara contra el ARN del
  # OBJETO, que es "<bucket>/<clave>". Un ARN de bucket pelado casa con el
  # bucket homonimo mas largo -"...:mi-bucket" tambien prefija a
  # "...:mi-bucket-viejo/x"-, asi que la barra final no es cosmetica.
  validation {
    condition     = alltrue([for arn in var.regulated_bucket_arns : endswith(arn, "/")])
    error_message = "Cada ARN debe terminar en / para que el prefijo no alcance a otro bucket con nombre mas largo."
  }
}

variable "enable_s3_data_events" {
  description = "Data events de CloudTrail sobre los buckets regulados. CUESTA: USD 0.10 por cada 100.000 eventos. El access logging cubre la misma pregunta sin cargo, con menos detalle y mas latencia."
  type        = bool
  default     = false
}

variable "enable_guardduty" {
  description = "Detector GuardDuty de la cuenta. CUESTA por volumen analizado. Es la unica pieza de deteccion; el resto del modulo registra pero no detecta."
  type        = bool
  default     = false
}

variable "enable_access_analyzer" {
  description = "Analizador de accesos externos de la cuenta. Sin cargo."
  type        = bool
  default     = true
}

variable "trail_retention_days" {
  description = "Retencion Object Lock del rastro, en modo COMPLIANCE."
  type        = number
  default     = 1825

  # El termino de firmeza de la declaracion tributaria se maneja como cinco
  # anios, y COMPLIANCE no permite acortar lo ya escrito: quedarse corto no se
  # puede corregir despues sobre los objetos existentes.
  validation {
    condition     = var.trail_retention_days >= 1825
    error_message = "trail_retention_days debe cubrir al menos cinco anios -1825 dias-."
  }
}

variable "access_log_retention_days" {
  description = "Caducidad de los access logs de S3. Acota el unico coste real del modulo, que es el almacenamiento."
  type        = number
  default     = 365

  validation {
    condition     = var.access_log_retention_days > 0
    error_message = "access_log_retention_days debe ser positivo: sin caducidad el almacenamiento crece sin techo."
  }
}

variable "alarm_topic_arn" {
  description = "Topic SNS que recibe los hallazgos de GuardDuty. Sin el, el detector queda sin ruteo."
  type        = string
  default     = null
}

variable "tags" {
  type    = map(string)
  default = {}
}
