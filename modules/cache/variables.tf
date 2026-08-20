variable "name" {
  description = "Nombre base del cache serverless y prefijo de sus recursos asociados."
  type        = string
}

variable "subnet_ids" {
  description = "Subredes de datos donde ElastiCache coloca sus interfaces de red."
  type        = list(string)
}

variable "security_group_ids" {
  description = "Grupos de seguridad que controlan quien alcanza el endpoint del cache."
  type        = list(string)
}

variable "major_engine_version" {
  description = "Version mayor del motor Valkey."
  type        = string
  default     = "8"
}

variable "user_name" {
  description = "Usuario RBAC de Valkey con el que se autentica la aplicacion."
  type        = string
  default     = "vetsoftware"
}

# La invariante que gobierna esta variable: el usuario RBAC y el secreto REDIS_URL
# son dos escrituras distintas de la MISMA contrasena, y ambas estan versionadas por
# este numero. Terraform solo reescribe un argumento write-only cuando su version
# cambia, asi que mientras este numero no suba ninguno de los dos se toca.
#
# Incrementarla en uno es la unica forma de rotar la contrasena, y hay que aplicar
# el modulo ENTERO para que las dos escrituras ocurran. Desde que la contrasena se
# persiste en random_password con keepers, un apply cortado a la mitad ya converge
# solo en el reintento -antes no: cada intento generaba un valor distinto-. Bajarla
# o reutilizar un valor anterior no rota nada: deja los dos consumidores como
# estaban.
variable "password_version" {
  description = "Version de la contrasena de Valkey. Incrementela -solo hacia arriba- para rotar de forma coordinada el usuario RBAC y el secreto REDIS_URL, que deben llevar SIEMPRE el mismo valor; si divergen, el backend arranca en crash loop con WRONGPASS."
  type        = number
  default     = 1

  validation {
    condition     = var.password_version >= 1 && floor(var.password_version) == var.password_version
    error_message = "password_version debe ser un entero mayor o igual que 1."
  }
}

# Sin ARN, el cache se cifra con la clave gestionada por AWS: es el comportamiento
# historico y por eso el valor por defecto es null, para que las raices que todavia
# no pasan la variable no cambien de plan. Pasar la CMK del entorno es lo correcto y
# esta pendiente de cablearse en environments/dev y environments/prod.
variable "kms_key_arn" {
  description = "ARN de la CMK del entorno que cifra los datos en reposo del cache. null usa la clave gestionada por AWS."
  type        = string
  default     = null

  validation {
    condition     = var.kms_key_arn == null || can(regex("^arn:[^:]+:kms:", var.kms_key_arn))
    error_message = "kms_key_arn debe ser el ARN de una KMS key o null."
  }
}

variable "daily_snapshot_time" {
  description = "Hora UTC en la que ElastiCache toma el snapshot diario."
  type        = string
  default     = "05:00"
}

variable "snapshot_retention_limit" {
  description = "Dias que se conservan los snapshots diarios del cache."
  type        = number
  default     = 7
}

variable "maximum_data_storage_gb" {
  description = "Límite de crecimiento para controlar costos del cache serverless."
  type        = number
  default     = 10

  validation {
    condition     = var.maximum_data_storage_gb >= 1 && var.maximum_data_storage_gb <= 5000
    error_message = "maximum_data_storage_gb debe estar entre 1 y 5000."
  }
}

variable "maximum_ecpu_per_second" {
  description = "Máximo de ECPU por segundo permitido al cache serverless."
  type        = number
  default     = 5000

  validation {
    condition     = var.maximum_ecpu_per_second >= 1000 && var.maximum_ecpu_per_second <= 15000000
    error_message = "maximum_ecpu_per_second debe estar entre 1000 y 15000000."
  }
}

variable "tags" {
  description = "Etiquetas comunes del entorno aplicadas a todos los recursos del modulo."
  type        = map(string)
  default     = {}
}
