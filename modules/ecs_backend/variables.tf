variable "name" {
  type = string
}

variable "image_uri" {
  description = "Imagen ECR inmutable del backend fijada por digest sha256."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}\\.dkr\\.ecr\\.[a-z0-9-]+\\.amazonaws\\.com(\\.cn)?/vetsoftware(-dev)?-backend@sha256:[0-9a-f]{64}$", var.image_uri))
    error_message = "image_uri debe usar el repositorio backend de dev o prod fijado con @sha256:<64 hex>."
  }
}

variable "subnet_ids" {
  type = list(string)
}

variable "security_group_ids" {
  type = list(string)
}

variable "container_port" {
  type    = number
  default = 8080
}

variable "health_check_path" {
  description = "Endpoint de readiness usado por Docker y ECS antes de iniciar cloudflared."
  type        = string
  default     = "/api/v1/actuator/health/readiness"

  validation {
    condition     = startswith(var.health_check_path, "/")
    error_message = "health_check_path debe ser una ruta absoluta."
  }
}

variable "cpu" {
  description = "Unidades Fargate: 1024 = 1 vCPU."
  type        = number
  default     = 1024
}

variable "memory" {
  description = "Memoria Fargate en MiB."
  type        = number
  default     = 4096
}

variable "ephemeral_storage_gib" {
  type    = number
  default = 20

  validation {
    condition     = var.ephemeral_storage_gib >= 20 && var.ephemeral_storage_gib <= 200
    error_message = "ephemeral_storage_gib debe estar entre 20 y 200."
  }
}

variable "cpu_architecture" {
  type    = string
  default = "ARM64"

  validation {
    condition     = contains(["ARM64", "X86_64"], var.cpu_architecture)
    error_message = "cpu_architecture debe ser ARM64 o X86_64."
  }
}

variable "desired_count" {
  type    = number
  default = 1
}

variable "min_count" {
  type    = number
  default = 1
}

variable "max_count" {
  type    = number
  default = 4
}

variable "assign_public_ip" {
  description = "Necesario sin NAT para pulls y APIs externas. El SG impide acceso directo."
  type        = bool
  default     = true
}

variable "fargate_spot_weight" {
  description = "Peso de Fargate Spot. Use fargate_base=0 y fargate_weight=0 para ejecutar solo en Spot."
  type        = number
  default     = 0

  validation {
    condition     = var.fargate_spot_weight >= 0
    error_message = "fargate_spot_weight no puede ser negativo."
  }
}

variable "fargate_base" {
  description = "Cantidad base reservada en Fargate On-Demand antes de distribuir por pesos."
  type        = number
  default     = 1

  validation {
    condition     = var.fargate_base >= 0
    error_message = "fargate_base no puede ser negativo."
  }
}

variable "fargate_weight" {
  description = "Peso de Fargate On-Demand en la estrategia de capacidad."
  type        = number
  default     = 1

  validation {
    condition     = var.fargate_weight >= 0
    error_message = "fargate_weight no puede ser negativo."
  }
}

variable "environment_variables" {
  type    = map(string)
  default = {}
}

variable "secrets" {
  description = "Mapa nombre de variable => ARN[:json-key::] de Secrets Manager."
  type        = map(string)
  default     = {}
}

variable "runtime_secret_arns" {
  description = "ARN base de los secretos que ECS puede leer."
  type        = list(string)
}

variable "cloudflare_tunnel_secret_arn" {
  description = "ARN del secreto que contiene el token del tunel remoto Cloudflare."
  type        = string
}

variable "cloudflare_tunnel_image" {
  description = "Imagen cloudflared inmutable y multi-arquitectura."
  type        = string
  default     = "cloudflare/cloudflared@sha256:5e49861633763e8933475477c20bae6039ed47f32c1d267a34babc347f28f0df"

  validation {
    condition     = can(regex("@sha256:[0-9a-f]{64}$", var.cloudflare_tunnel_image))
    error_message = "cloudflare_tunnel_image debe fijarse por digest sha256."
  }
}

variable "cloudflare_tunnel_cpu" {
  type    = number
  default = 64
}

variable "cloudflare_tunnel_memory" {
  description = "Memoria del sidecar cloudflared en MiB."
  type        = number
  default     = 128
}

variable "application_bucket_arn" {
  type = string
}

variable "kms_key_arn" {
  description = "CMK para datos S3 y grupos de logs de la aplicacion."
  type        = string
}

variable "firehose_stream_arn" {
  description = "Firehose opcional. Vacío omite el permiso de auditoría, útil en dev."
  type        = string
  default     = ""
}

variable "database_connect_resource_arns" {
  description = "ARN dbuser autorizados para migrar el cliente a RDS IAM DB Auth."
  type        = list(string)
  default     = []
}

variable "log_retention_days" {
  type    = number
  default = 30
}

# El log group del backend deja de ser solo "los ultimos logs para depurar" y
# pasa a ser la frontera de durabilidad del envio a Grafana Cloud: si Firehose se
# atasca, el original tiene que seguir aqui cuando alguien lo vaya a buscar. Por
# eso se separa de log_retention_days, que comparten flow logs, RDS,
# account_baseline y el informe de costos. Nulo conserva la retencion del
# entorno, asi que ningun entorno cambia sin pedirlo.
variable "backend_log_retention_days" {
  description = "Retencion exclusiva del log group del contenedor backend. Nulo sigue log_retention_days."
  type        = number
  default     = null
}

variable "enable_container_insights" {
  type    = bool
  default = false
}

variable "enable_execute_command" {
  type    = bool
  default = true
}

# Ventana en la que el scheduler ignora los health checks de una tarea recien
# lanzada. Debe cubrir el arranque completo del contenedor; con 120 se quedaba por
# debajo de los 90-120 segundos que tarda la aplicacion.
variable "health_check_grace_period_seconds" {
  type    = number
  default = 300
}

variable "autoscaling_cpu_target" {
  type    = number
  default = 65
}

variable "autoscaling_memory_target" {
  type    = number
  default = 75
}

variable "tags" {
  type    = map(string)
  default = {}
}

# ---------------------------------------------------------------------------
# Sidecar colector de trazas y metricas
#
# Los logs NO pasan por aqui: su durabilidad la resuelve CloudWatch + Firehose
# (modules/log_shipping) fuera de la tarea. Lo que quedaba sin proteger eran las
# trazas y las metricas, que salian por OTLP directo desde la aplicacion con una
# cola en memoria que descarta en silencio cuando el destino no responde. Este
# sidecar pone esa cola en disco.
# ---------------------------------------------------------------------------

variable "telemetry_sidecar_enabled" {
  description = "Anade el contenedor colector de trazas y metricas con cola persistente en disco."
  type        = bool
  default     = false
}

variable "telemetry_sidecar_image" {
  description = "Imagen inmutable del OpenTelemetry Collector contrib fijada por digest del indice multi-arquitectura."
  type        = string
  default     = "otel/opentelemetry-collector-contrib@sha256:1f2c54a30e713fac6b3ae77a1ec84010c2007e29ced8ec666214fc2f6739c1cc"

  validation {
    condition     = can(regex("@sha256:[0-9a-f]{64}$", var.telemetry_sidecar_image))
    error_message = "telemetry_sidecar_image debe fijarse por digest sha256."
  }
}

variable "telemetry_sidecar_cpu" {
  description = "Unidades de CPU reservadas al sidecar colector; se descuentan de las del backend."
  type        = number
  default     = 64

  validation {
    condition     = var.telemetry_sidecar_cpu > 0
    error_message = "telemetry_sidecar_cpu debe ser mayor que cero."
  }
}

variable "telemetry_sidecar_memory" {
  description = "Memoria en MiB reservada al sidecar colector; se descuenta de la del backend."
  type        = number
  default     = 256

  validation {
    condition     = var.telemetry_sidecar_memory >= 128
    error_message = "telemetry_sidecar_memory debe ser al menos 128 MiB."
  }
}

# El memory_limiter tiene que quedar por debajo de la reserva del contenedor. Si
# se iguala, quien corta es el kernel: el contenedor muere por OOM sin escribir
# una linea y la cola en disco se queda sin nadie que la drene. Con margen, quien
# corta es el colector, que rechaza en la entrada y lo deja contabilizado en
# otelcol_receiver_refused_*.
variable "telemetry_sidecar_memory_limit_mib" {
  description = "Limite del procesador memory_limiter del colector, por debajo de la memoria reservada al contenedor."
  type        = number
  default     = 160
}

variable "telemetry_sidecar_memory_spike_limit_mib" {
  description = "Margen de pico del memory_limiter del colector, en MiB."
  type        = number
  default     = 32
}

variable "telemetry_otlp_endpoint" {
  description = "Base OTLP de Grafana Cloud a la que reenvia el sidecar; otlphttp le anade /v1/traces y /v1/metrics."
  type        = string
  default     = ""
}

variable "telemetry_credentials_secret_arn" {
  description = "ARN del secreto con OTLP_USERNAME y OTLP_API_KEY que el sidecar presenta a Grafana Cloud."
  type        = string
  default     = ""
}

variable "telemetry_queue_size" {
  description = "Numero de lotes que la cola persistente del exportador puede retener antes de rechazar."
  type        = number
  default     = 2000
}

variable "telemetry_queue_consumers" {
  description = "Consumidores concurrentes que drenan la cola persistente del exportador."
  type        = number
  default     = 4
}

variable "telemetry_retry_max_elapsed_time" {
  description = "Ventana total de reintento del exportador antes de dar un lote por perdido."
  type        = string
  default     = "30m"
}

variable "telemetry_self_metrics_interval_ms" {
  description = "Periodo de exportacion de las metricas internas del colector, en milisegundos."
  type        = number
  default     = 60000
}

variable "telemetry_environment_name" {
  description = "Valor de deployment.environment.name en las metricas internas del colector."
  type        = string
  default     = ""
}

# Bedrock. La lista vacia es el estado normal y es lo que separa a los dos
# entornos: el modulo es identico, y el que no reciba ARN no gana el permiso.
#
# Los ARN NO se escriben aqui. Los compone el root porque el del perfil de
# inferencia lleva dentro el account-id -y dev y prod son cuentas distintas- y
# el de cada modelo base lleva la region de destino. Cablearlos en el modulo es
# la forma exacta de que prod acabe apuntando al perfil de dev.
variable "bedrock_model_arns" {
  description = "ARN de perfiles de inferencia y modelos base que el rol de tarea puede invocar. Vacio no genera ningun statement y el rol no gana ningun permiso de Bedrock."
  type        = list(string)
  default     = []
}

variable "bedrock_streaming_enabled" {
  description = "Anade bedrock:InvokeModelWithResponseStream al rol de tarea. El caso de uso actual devuelve la respuesta entera, asi que concederla hoy solo amplia la superficie."
  type        = bool
  default     = false
}
