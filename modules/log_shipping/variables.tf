variable "name" {
  description = "Prefijo del entorno, por ejemplo vetsoftware-dev. Nombra el stream, el bucket de respaldo, los roles y las alarmas."
  type        = string
}

variable "source_log_group_name" {
  description = "Log group de CloudWatch cuyo contenido se envia a Grafana Cloud; en dev, el del contenedor backend."
  type        = string
}

variable "source_log_group_arn" {
  description = "ARN del log group de origen. Acota por aws:SourceArn quien puede asumir el rol de la suscripcion."
  type        = string
}

variable "filter_pattern" {
  description = "Patron de la suscripcion. Cadena vacia envia todos los eventos, que es lo que exige la frontera de durabilidad."
  type        = string
  default     = ""
}

variable "endpoint_url" {
  description = "Endpoint HTTP de ingesta de logs de Grafana Cloud, terminado en /aws-logs/api/v1/push."
  type        = string

  validation {
    condition     = can(regex("^https://", var.endpoint_url))
    error_message = "endpoint_url debe ser HTTPS: Firehose no acepta destinos HTTP en claro."
  }
}

variable "endpoint_name" {
  description = "Nombre legible del destino HTTP que muestra la consola de Firehose."
  type        = string
  default     = "grafana-cloud-loki"
}

# El token de la Cloud Access Policy no entra en Terraform ni en el state: lo lee
# Firehose de Secrets Manager en cada entrega. El valor lo escribe el modulo
# secrets con secret_string_wo, asi que tampoco queda en el state de origen.
variable "access_key_secret_arn" {
  description = "Secreto de Secrets Manager del que Firehose lee la clave de acceso del endpoint HTTP."
  type        = string
}

# Sin esto los logs llegan a Loki como {job=\"cloud/aws\"} y ninguna consulta
# existente los encuentra. Grafana toma cada common attribute cuyo nombre empieza
# por lbl_, quita el prefijo y lo almacena como etiqueta de flujo.
variable "loki_labels" {
  description = "Etiquetas de Loki, sin el prefijo lbl_. Reproducen las que hoy pone el exportador OTLP directo."
  type        = map(string)

  validation {
    condition = alltrue([
      for required in ["service_name", "deployment_environment_name", "service_namespace", "telemetry_source"] :
      contains(keys(var.loki_labels), required)
    ])
    error_message = "loki_labels debe incluir service_name, deployment_environment_name, service_namespace y telemetry_source."
  }

  validation {
    condition     = alltrue([for key in keys(var.loki_labels) : !startswith(key, "lbl_")])
    error_message = "Las claves de loki_labels van sin prefijo: el modulo antepone lbl_ por su cuenta."
  }

  validation {
    condition     = alltrue([for value in values(var.loki_labels) : trimspace(value) != ""])
    error_message = "Ninguna etiqueta de Loki puede quedar vacia; una etiqueta vacia parte el flujo en dos series."
  }
}

variable "retry_duration_seconds" {
  description = "Ventana de reintento del destino HTTP. Es lo que convierte un 429 sostenido en un retraso y no en un hueco."
  type        = number
  default     = 7200

  validation {
    condition     = var.retry_duration_seconds >= 0 && var.retry_duration_seconds <= 7200
    error_message = "retry_duration_seconds debe estar entre 0 y 7200; 7200 es el maximo que admite Firehose."
  }
}

# 60 s es el valor de las plantillas oficiales de Grafana Labs, con su motivo
# escrito al lado: "to keep a low enough latency". Es tambien el minimo que
# admite Firehose.
variable "buffering_interval_seconds" {
  description = "Segundos que Firehose acumula antes de entregar al endpoint HTTP."
  type        = number
  default     = 60

  validation {
    condition     = var.buffering_interval_seconds >= 60 && var.buffering_interval_seconds <= 900
    error_message = "buffering_interval_seconds debe estar entre 60 y 900."
  }
}

# 1 MB es el valor de las plantillas oficiales de Grafana Labs, y el techo no es
# el de Firehose -64 MB- sino el del endpoint: rechaza con HTTP 502 cualquier
# peticion por encima de 5 MiB. Con 1 MB se va holgado incluso antes de
# comprimir; el limite queda escrito aqui para que subirlo sea una decision y no
# un descuido que se paga con un 502 que solo se ve en el log group de Firehose.
variable "buffering_size_mib" {
  description = "MiB acumulados antes de entregar al endpoint HTTP; el endpoint rechaza con 502 por encima de 5 MiB."
  type        = number
  default     = 1

  validation {
    condition     = var.buffering_size_mib >= 1 && var.buffering_size_mib <= 5
    error_message = "buffering_size_mib debe estar entre 1 y 5: el endpoint de Grafana Cloud responde HTTP 502 a las peticiones que superan 5 MiB."
  }
}

variable "backup_buffering_interval_seconds" {
  description = "Segundos que Firehose acumula antes de escribir en el bucket de respaldo."
  type        = number
  default     = 300
}

variable "backup_buffering_size_mib" {
  description = "MiB acumulados antes de escribir en el bucket de respaldo."
  type        = number
  default     = 5
}

variable "backup_bucket_name" {
  description = "Nombre del bucket de respaldo. Vacio lo deriva de name, cuenta y region."
  type        = string
  default     = ""
}

variable "backup_bucket_force_destroy" {
  description = "Permite destruir el bucket de respaldo con objetos dentro; solo tiene sentido en entornos recreables."
  type        = bool
  default     = false
}

variable "backup_retention_days" {
  description = "Dias que sobreviven los registros no entregados en el bucket de respaldo."
  type        = number
  default     = 30

  validation {
    condition     = var.backup_retention_days >= 7
    error_message = "backup_retention_days debe ser al menos 7: por debajo, el respaldo caduca antes de que alguien lo mire."
  }
}

variable "kms_key_arn" {
  description = "CMK del entorno: cifra el bucket de respaldo y el log group operativo del propio Firehose."
  type        = string
}

variable "log_retention_days" {
  description = "Retencion del log group donde Firehose escribe sus propios errores de entrega."
  type        = number
  default     = 14
}

variable "alarm_topic_arn" {
  description = "Topic SNS de advertencias. Vacio deja las alarmas sin accion de notificacion."
  type        = string
  default     = ""
}

variable "critical_alarm_topic_arn" {
  description = "Topic SNS de alarmas criticas. Vacio deja las alarmas sin accion de notificacion."
  type        = string
  default     = ""
}

variable "delivery_freshness_warning_seconds" {
  description = "Antiguedad del registro mas viejo sin entregar que declara a Firehose vivo pero atascado."
  type        = number
  default     = 900

  validation {
    condition     = var.delivery_freshness_warning_seconds > 0
    error_message = "delivery_freshness_warning_seconds debe ser mayor que cero."
  }
}

variable "tags" {
  description = "Etiquetas comunes del entorno."
  type        = map(string)
  default     = {}
}
