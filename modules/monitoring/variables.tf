variable "name" {
  type = string
}

variable "aws_region" {
  type = string
}

variable "sns_kms_key_arn" {
  description = "CMK usada para cifrar el topic SNS de alertas; se recomienda reutilizar la clave de datos del entorno."
  type        = string
  default     = ""
}

# El circuito de imagen y el informe diario de costos avisan a Slack por el mismo
# topic que ya escucha Amazon Q. Se autoriza por policy del topic y no en la policy
# del rol: las inline policies de los roles de GitHub estan cerca del limite de
# 10.240 caracteres, y una autorizacion nombrada aca se aplica con el mismo
# `Terraform apply dev` que crea el topic, sin volver a correr el bootstrap.
variable "notification_publisher_role_arns" {
  description = "Roles autorizados a publicar avisos en el topic de alertas."
  type        = list(string)
  default     = []
}

variable "alarm_email" {
  description = "Correo opcional. La suscripción SNS requiere confirmación."
  type        = string
  default     = ""
}

variable "monthly_budget_usd" {
  description = "Cero deshabilita AWS Budgets."
  type        = number
  default     = 180
}

variable "budget_sns_notifications_enabled" {
  description = "Publica las alertas de AWS Budgets en el topic SNS compartido."
  type        = bool
  default     = false
}

variable "cost_anomaly_detection_enabled" {
  description = "Crea un monitor por servicio y una suscripción inmediata de Cost Anomaly Detection."
  type        = bool
  default     = false
}

variable "cost_anomaly_threshold_usd" {
  description = "Impacto absoluto mínimo en USD para notificar una anomalía."
  type        = number
  default     = 10

  validation {
    condition     = var.cost_anomaly_threshold_usd > 0
    error_message = "cost_anomaly_threshold_usd debe ser mayor que cero."
  }
}

variable "slack_workspace_id" {
  description = "ID del workspace Slack autorizado en Amazon Q Developer; vacío junto con slack_channel_id deshabilita Slack."
  type        = string
  default     = ""

  validation {
    condition = (
      (trimspace(var.slack_workspace_id) == "" && trimspace(var.slack_channel_id) == "") ||
      (
        can(regex("^T[A-Z0-9]+$", var.slack_workspace_id)) &&
        can(regex("^[CG][A-Z0-9]+$", var.slack_channel_id))
      )
    )
    error_message = "slack_workspace_id y slack_channel_id deben configurarse juntos con IDs válidos de Slack."
  }
}

# Canal base: recibe todo lo que no tenga canal propio, y es donde aterrizan los
# avisos de costo. Vacio junto con slack_workspace_id deshabilita Slack.
variable "slack_channel_id" {
  description = "Canal Slack base. Recibe los avisos de costo y cualquier familia sin canal propio."
  type        = string
  default     = ""
}

# Los canales se separan por tipo de senal: una alarma dice que algo esta mal,
# un evento dice que algo paso. Cada uno vacio cae al canal base, asi que
# configurar de menos nunca deja una senal sin destino.
variable "slack_alerts_channel_id" {
  description = "Canal Slack de alarmas -criticas y advertencias-. Vacio reutiliza slack_channel_id."
  type        = string
  default     = ""

  validation {
    condition = (
      trimspace(var.slack_alerts_channel_id) == "" ||
      can(regex("^[CG][A-Z0-9]+$", var.slack_alerts_channel_id))
    )
    error_message = "slack_alerts_channel_id debe ser un ID de canal Slack valido."
  }
}

variable "slack_infra_channel_id" {
  description = "Canal Slack de eventos: despliegues, apagados y eventos de ECS y RDS. Vacio reutiliza slack_channel_id."
  type        = string
  default     = ""

  validation {
    condition = (
      trimspace(var.slack_infra_channel_id) == "" ||
      can(regex("^[CG][A-Z0-9]+$", var.slack_infra_channel_id))
    )
    error_message = "slack_infra_channel_id debe ser un ID de canal Slack valido."
  }
}

# Solo hace falta el dia que exista guardia. Vacio deja lo critico junto a las
# advertencias en el canal de alarmas, que es donde tiene sentido mientras las
# dos las atienda la misma persona en el mismo horario.
variable "slack_critical_channel_id" {
  description = "Canal Slack dedicado a alarmas criticas. Vacio las deja en el canal de alarmas."
  type        = string
  default     = ""

  validation {
    condition = (
      trimspace(var.slack_critical_channel_id) == "" ||
      can(regex("^[CG][A-Z0-9]+$", var.slack_critical_channel_id))
    )
    error_message = "slack_critical_channel_id debe ser un ID de canal Slack valido."
  }
}

variable "runbook_url" {
  description = "URL del runbook que se adjunta a cada notificacion enviada a Slack."
  type        = string
  default     = ""
}

variable "custom_metric_namespace" {
  description = "Namespace CloudWatch de las metricas derivadas de logs y eventos."
  type        = string
  default     = "VetSoftware/Platform"
}

variable "event_log_retention_days" {
  description = "Retencion del log group que archiva los eventos de EventBridge usados para contar fallos."
  type        = number
  default     = 7
}

variable "ecs_cluster_name" {
  type = string
}

variable "ecs_service_name" {
  type = string
}

# Bandera y no "el ARN viene lleno": el ARN del cluster solo se conoce despues
# del apply, y un count que dependa de el hace el plan indecidible.
variable "ecs_events_enabled" {
  description = "Crea el circuito de eventos ECS: archivo en Logs, metricas de fallo y notificaciones a Slack."
  type        = bool
  default     = false
}

# Acota el patron de EventBridge a este cluster; sin el, la regla avisaria de
# cualquier tarea de la cuenta.
variable "ecs_cluster_arn" {
  description = "ARN del cluster ECS observado por las reglas de EventBridge."
  type        = string
  default     = ""
}

variable "ecs_service_arn" {
  description = "ARN del servicio ECS. Los eventos de despliegue no llevan clusterArn, solo el servicio en resources."
  type        = string
  default     = ""
}

variable "backend_log_group_name" {
  description = "Log group de la aplicacion citado en las notificaciones para acortar el diagnostico."
  type        = string
  default     = ""
}

variable "cloudflare_tunnel_log_group_name" {
  description = "Log group JSON del sidecar cloudflared usado para detectar errores del conector."
  type        = string
}

# RunningTaskCount y las metricas por tarea viven en ECS/ContainerInsights, no en
# AWS/ECS. Sin Container Insights encendido esa alarma se quedaria en
# INSUFFICIENT_DATA para siempre, asi que se crea solo cuando hay de donde leer.
variable "container_insights_enabled" {
  description = "Habilita las alarmas que dependen del namespace ECS/ContainerInsights."
  type        = bool
  default     = false
}

variable "backend_cpu_warning_percent" {
  description = "CPU del servicio ECS que abre una advertencia."
  type        = number
  default     = 85
}

variable "backend_cpu_critical_percent" {
  description = "CPU del servicio ECS sostenida que se considera saturacion."
  type        = number
  default     = 95
}

variable "backend_memory_warning_percent" {
  description = "Memoria del servicio ECS que abre una advertencia."
  type        = number
  default     = 85
}

# El backend arranca con -XX:MaxRAMPercentage=70 y -XX:+ExitOnOutOfMemoryError:
# el heap maximo mas metaspace, hilos y memoria directa aterrizan alrededor del
# 90% de la memoria de la tarea. Pasado ese punto el siguiente pico no lo absorbe
# el GC, lo mata el kernel, asi que 92 es el ultimo momento util para avisar.
variable "backend_memory_critical_percent" {
  description = "Memoria del servicio ECS a partir de la cual la tarea muere por OOM."
  type        = number
  default     = 92
}

variable "backend_crash_loop_threshold" {
  description = "Paradas inesperadas de tarea dentro de la ventana que confirman un crash loop."
  type        = number
  default     = 3

  validation {
    condition     = var.backend_crash_loop_threshold >= 2
    error_message = "backend_crash_loop_threshold debe ser al menos 2; con 1 la alarma duplica el aviso por evento."
  }
}

# Cada ciclo fallido de la tarea cuesta arranque de ENI, pull de imagen y los 180
# segundos de startPeriod del health check. Quince minutos alcanzan para tres
# ciclos completos: menos ventana confunde un despliegue lento con un crash loop.
variable "backend_crash_loop_window_seconds" {
  description = "Ventana en la que se cuentan las paradas inesperadas de tarea."
  type        = number
  default     = 900

  validation {
    condition     = contains([60, 300, 900, 3600], var.backend_crash_loop_window_seconds)
    error_message = "backend_crash_loop_window_seconds debe ser un periodo estandar de CloudWatch: 60, 300, 900 o 3600."
  }
}

variable "database_identifier" {
  type = string
}

variable "database_events_enabled" {
  description = "Crea las reglas de EventBridge que notifican los eventos de RDS."
  type        = bool
  default     = false
}

variable "database_arn" {
  description = "ARN de la instancia RDS observada por EventBridge."
  type        = string
  default     = ""
}

# Es margen absoluto hasta el swap, no un porcentaje de la RAM instalada: MySQL
# dimensiona el buffer pool como fraccion de DBInstanceClassMemory y se expande
# hasta ocupar la memoria que le den, asi que la memoria libre en reposo no se
# duplica al doblar la clase. Por eso este umbral no se escalo al pasar dev de
# db.t4g.micro a db.t4g.small: escalarlo lo habria dejado sonando siempre.
variable "database_freeable_memory_threshold_bytes" {
  description = "Umbral de memoria libre de RDS; margen absoluto hasta el swap, no proporcion de la RAM."
  type        = number
  default     = 268435456
}

# Por debajo de esta marca la instancia ya no tiene con que atender un pico: el
# InnoDB buffer pool empieza a competir con las conexiones y el siguiente paso es
# swap, no lentitud. Validado con datos reales: durante la crisis de memoria de
# dev el minimo de FreeableMemory fue 71,9 MB, o sea que la alarma disparo antes
# del reinicio del motor.
variable "database_freeable_memory_critical_bytes" {
  description = "Memoria libre de RDS que anticipa swap y caida del motor."
  type        = number
  default     = 100663296
}

variable "database_cpu_warning_percent" {
  description = "CPU de RDS que abre una advertencia."
  type        = number
  default     = 80
}

variable "database_cpu_critical_percent" {
  description = "CPU de RDS sostenida que se considera saturacion."
  type        = number
  default     = 95
}

# RDS para MySQL calcula max_connections como {DBInstanceClassMemory/12582880}.
# AWS documenta que en clases micro la memoria reservada deja el resultado en
# unas 60 conexiones. Verificar con SHOW GLOBAL VARIABLES LIKE 'max_connections'
# antes de cambiar de clase de instancia.
variable "database_max_connections" {
  description = "max_connections efectivo del motor; los umbrales de conexiones se derivan de este valor."
  type        = number
  default     = 60

  validation {
    condition     = var.database_max_connections > 0
    error_message = "database_max_connections debe ser mayor que cero."
  }
}

variable "database_connections_warning_percent" {
  description = "Porcentaje de max_connections que abre una advertencia."
  type        = number
  default     = 70
}

variable "database_connections_critical_percent" {
  description = "Porcentaje de max_connections a partir del cual el proximo cliente recibe Too many connections."
  type        = number
  default     = 90
}

variable "database_allocated_storage_gib" {
  description = "Almacenamiento asignado a RDS; los umbrales de disco se derivan de este valor."
  type        = number
  default     = 20

  validation {
    condition     = var.database_allocated_storage_gib > 0
    error_message = "database_allocated_storage_gib debe ser mayor que cero."
  }
}

variable "database_free_storage_warning_percent" {
  description = "Porcentaje de disco libre que abre una advertencia."
  type        = number
  default     = 25
}

# RDS para MySQL emite RDS-EVENT-0222 por debajo del 10% y apaga la base antes de
# corromperla. Avisar en ese mismo punto da margen para ampliar el volumen.
variable "database_free_storage_critical_percent" {
  description = "Porcentaje de disco libre en el que RDS apaga la instancia para no corromper datos."
  type        = number
  default     = 10
}

# A diferencia de FreeableMemory, este umbral si depende del tamano: en una
# instancia holgada el swap sostenido no deberia existir, asi que cuanto mas RAM
# tenga la clase, mas grave es cualquier swap y mas bajo conviene el umbral. Dev
# lo baja a 64 MiB desde su root; este default es el de una clase justa de
# memoria.
variable "database_swap_warning_bytes" {
  description = "Swap sostenido de RDS que confirma presion de memoria."
  type        = number
  default     = 134217728
}

variable "database_latency_warning_seconds" {
  description = "Latencia de lectura o escritura de RDS considerada degradada para carga transaccional."
  type        = number
  default     = 0.02
}

variable "database_disk_queue_warning" {
  description = "Profundidad de cola de disco sostenida que indica saturacion de E/S."
  type        = number
  default     = 5
}

# EBSIOBalance% y EBSByteBalance% solo se publican en clases con ancho de banda
# EBS por rafagas -toda la familia t-. Agotar el credito no da error: baja el
# throughput a la linea base y la base parece lenta sin causa visible.
variable "database_ebs_balance_warning_percent" {
  description = "Credito EBS restante en clases burstable que anticipa throttling de E/S."
  type        = number
  default     = 20
}

variable "database_cpu_credit_warning_balance" {
  description = "Creditos de CPU restantes en clases burstable antes de caer a la linea base."
  type        = number
  default     = 30
}

variable "database_critical_event_ids" {
  description = "Event IDs de RDS que exigen intervencion inmediata."
  type        = list(string)
  default = [
    "RDS-EVENT-0007", # almacenamiento asignado agotado
    "RDS-EVENT-0221", # storage-full: la base fue apagada
    "RDS-EVENT-0222", # disco libre por debajo del 10% en MySQL
    "RDS-EVENT-0330", # volumen dedicado de log de transacciones sin espacio
    "RDS-EVENT-0031", # instancia en estado incompatible, requiere PITR
    "RDS-EVENT-0035", # parametros invalidos: incompatible-parameters
    "RDS-EVENT-0036", # red incompatible
    "RDS-EVENT-0022", # error al reiniciar MySQL
    "RDS-EVENT-0418", # RDS no puede acceder a la clave KMS
    "RDS-EVENT-0419", # instancia inaccesible por la clave KMS

    # "critically low on memory": RDS baja innodb_buffer_pool_size por su cuenta
    # para no morir. No es teorico en dev -paso el 5, 6 y 7 de agosto de 2026,
    # siempre cerca de las 12:34 UTC, con la instancia encadenando shutdown,
    # recovery y restart-. Es el aviso mas temprano y mas inequivoco del crash
    # loop por memoria de la db.t4g.micro: llega antes de que el motor se caiga y
    # dice la causa, mientras que el apagado y el reinicio que vienen despues son
    # indistinguibles del apagado programado de cada noche.
    "RDS-EVENT-0403",
  ]
}

variable "database_warning_event_ids" {
  description = "Event IDs de RDS que se notifican sin exigir intervencion inmediata."
  type        = list(string)
  default = [
    "RDS-EVENT-0089", # disco libre por debajo del 10% del aprovisionado
    "RDS-EVENT-0013", # failover Multi-AZ iniciado
    "RDS-EVENT-0015", # failover Multi-AZ completado
    "RDS-EVENT-0049", # failover de instancia completado
    "RDS-EVENT-0223", # storage autoscaling no pudo escalar
    "RDS-EVENT-0224", # storage autoscaling alcanzara el limite maximo
    "RDS-EVENT-0026", # parches offline en curso, instancia no disponible
    "RDS-EVENT-0155", # hay upgrade menor de motor disponible
  ]
}

variable "cache_alarms_enabled" {
  description = "Crea las alarmas del cache serverless de ElastiCache."
  type        = bool
  default     = false
}

variable "cache_name" {
  description = "Nombre del cache serverless; es el valor de la dimension clusterId en AWS/ElastiCache."
  type        = string
  default     = ""
}

variable "cache_maximum_data_storage_gb" {
  description = "Limite de almacenamiento del cache serverless usado para derivar el umbral de ocupacion."
  type        = number
  default     = 0
}

variable "cache_maximum_ecpu_per_second" {
  description = "Limite de ECPU por segundo del cache serverless usado para derivar el umbral de consumo."
  type        = number
  default     = 0
}

variable "cache_utilization_warning_percent" {
  description = "Porcentaje de los limites del cache serverless que abre una advertencia."
  type        = number
  default     = 80
}

variable "alloy_instance_ids" {
  type = list(string)
}

variable "tags" {
  type    = map(string)
  default = {}
}

# ---------------------------------------------------------------------------
# Sidecar colector de trazas y metricas
# ---------------------------------------------------------------------------

variable "telemetry_sidecar_enabled" {
  description = "Crea las alarmas del sidecar colector de trazas y metricas del backend."
  type        = bool
  default     = false
}

variable "telemetry_sidecar_log_group_name" {
  description = "Log group del contenedor colector; de ahi sale el conteo de errores del sidecar."
  type        = string
  default     = ""
}

# El filtro comprueba todas las posiciones del array de contenedores para no
# depender de un orden que ECS no garantiza. Es el numero de contenedores de la
# definicion de tarea, no una preferencia.
variable "telemetry_task_container_count" {
  description = "Contenedores de la definicion de tarea que recorre el filtro de sidecar detenido."
  type        = number
  default     = 3

  validation {
    condition     = var.telemetry_task_container_count >= 1 && var.telemetry_task_container_count <= 10
    error_message = "telemetry_task_container_count debe estar entre 1 y 10."
  }
}

variable "telemetry_sidecar_error_threshold" {
  description = "Errores del colector en una ventana de cinco minutos, sostenidos dos ventanas, que hacen sonar la advertencia."
  type        = number
  default     = 5

  validation {
    condition     = var.telemetry_sidecar_error_threshold >= 1
    error_message = "telemetry_sidecar_error_threshold debe ser al menos 1."
  }
}
