# Alarmas del servicio ECS.
#
# CPUUtilization y MemoryUtilization del namespace AWS/ECS son metricas de
# servicio y se publican sin Container Insights, que en dev esta apagado por
# costo. Todo lo que dependa de ECS/ContainerInsights -RunningTaskCount, memoria
# por contenedor- queda detras de container_insights_enabled.
#
# Ninguna alarma de este fichero tiene `ok_actions` ni severidad en el texto: ver
# la cabecera de alarms_database.tf.
#
# El tratamiento de la ausencia de datos se decide por familia de metrica, no en
# bloque:
#
#   - CPU y memoria del servicio fluyen mientras el servicio existe, asi que
#     siguen `continuous_metric_missing_data`.
#   - UnexpectedTaskStops, SpotInterruptions y ConnectorErrors solo se publican
#     cuando pasa lo que cuentan. Es el caso que AWS documenta como propio de
#     `notBreaching` -su ejemplo es ThrottledRequests de DynamoDB- y por eso
#     estan fijas ahi.
#   - RunningTaskCount y DesiredTaskCount son senales internas de un interruptor
#     de hombre muerto: la primera trata el hueco como falla y la segunda como
#     calma, y solo la compuesta que las combina notifica. Ver el bloque final.

resource "aws_cloudwatch_metric_alarm" "backend_cpu" {
  alarm_name          = "${var.name}-backend-high-cpu"
  alarm_description   = "CPUUtilization del servicio ${var.ecs_service_name} por encima de ${var.backend_cpu_warning_percent}% durante 10 minutos. Mirar ${local.backend_log_group_hint} y las trazas del intervalo en Grafana."
  namespace           = "AWS/ECS"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  threshold           = var.backend_cpu_warning_percent
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = var.continuous_metric_missing_data
  alarm_actions       = local.alarm_actions

  dimensions = {
    ClusterName = var.ecs_cluster_name
    ServiceName = var.ecs_service_name
  }

  tags = merge(var.tags, { Severity = "warning" })
}

resource "aws_cloudwatch_metric_alarm" "backend_cpu_critical" {
  alarm_name          = "${var.name}-backend-cpu-saturated"
  alarm_description   = "CPUUtilization del servicio ${var.ecs_service_name} por encima de ${var.backend_cpu_critical_percent}% durante 15 minutos: las peticiones se encolan. Mirar ${local.backend_log_group_hint} y las trazas del intervalo en Grafana."
  namespace           = "AWS/ECS"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  datapoints_to_alarm = 3
  threshold           = var.backend_cpu_critical_percent
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = var.continuous_metric_missing_data
  alarm_actions       = local.critical_actions

  dimensions = {
    ClusterName = var.ecs_cluster_name
    ServiceName = var.ecs_service_name
  }

  tags = merge(var.tags, { Severity = "critical" })
}

resource "aws_cloudwatch_metric_alarm" "backend_memory" {
  alarm_name          = "${var.name}-backend-high-memory"
  alarm_description   = "MemoryUtilization del servicio ${var.ecs_service_name} por encima de ${var.backend_memory_warning_percent}% durante 10 minutos. Mirar el GC de la JVM en Grafana y ${local.backend_log_group_hint}."
  namespace           = "AWS/ECS"
  metric_name         = "MemoryUtilization"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  threshold           = var.backend_memory_warning_percent
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = var.continuous_metric_missing_data
  alarm_actions       = local.alarm_actions

  dimensions = {
    ClusterName = var.ecs_cluster_name
    ServiceName = var.ecs_service_name
  }

  tags = merge(var.tags, { Severity = "warning" })
}

# La que pidio el negocio: memoria que puede tumbar la tarea. Se evalua con
# periodo de 60 segundos y 3 de 5 datapoints porque un OOM no avisa diez minutos
# antes; con periodo de 5 minutos el promedio suaviza justo el pico que mata al
# contenedor. Maximum en vez de Average por la misma razon.
resource "aws_cloudwatch_metric_alarm" "backend_memory_critical" {
  alarm_name          = "${var.name}-backend-memory-exhausted"
  alarm_description   = "MemoryUtilization maxima por minuto del servicio ${var.ecs_service_name} por encima de ${var.backend_memory_critical_percent}%: la JVM esta a un pico de que el kernel mate la tarea. Mirar ${local.backend_log_group_hint} y el GC en Grafana."
  namespace           = "AWS/ECS"
  metric_name         = "MemoryUtilization"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 5
  datapoints_to_alarm = 3
  threshold           = var.backend_memory_critical_percent
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = var.continuous_metric_missing_data
  alarm_actions       = local.critical_actions

  dimensions = {
    ClusterName = var.ecs_cluster_name
    ServiceName = var.ecs_service_name
  }

  tags = merge(var.tags, { Severity = "critical" })
}

resource "aws_cloudwatch_log_metric_filter" "cloudflare_tunnel_errors" {
  name           = "${var.name}-cloudflare-tunnel-errors"
  pattern        = "{ $.level = \"error\" }"
  log_group_name = var.cloudflare_tunnel_log_group_name

  metric_transformation {
    name          = "ConnectorErrors"
    namespace     = "VetSoftware/CloudflareTunnel"
    value         = "1"
    default_value = "0"
    unit          = "Count"
  }
}

# El tunel es el unico camino publico hacia dev: no hay ALB que lo respalde. Si
# el conector falla, la API esta caida aunque la tarea siga viva y sana.
#
# ConnectorErrors solo existe cuando el conector escribe un error: notBreaching
# fijo, por el criterio de AWS para metricas de error.
resource "aws_cloudwatch_metric_alarm" "cloudflare_tunnel_errors" {
  alarm_name          = "${var.name}-cloudflare-tunnel-errors"
  alarm_description   = "El conector Cloudflare Tunnel registro errores; es el unico camino publico hacia ${var.name}, asi que la API puede estar inalcanzable con la tarea sana. Mirar ${var.cloudflare_tunnel_log_group_name}."
  namespace           = "VetSoftware/CloudflareTunnel"
  metric_name         = "ConnectorErrors"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.critical_actions

  tags = merge(var.tags, { Severity = "critical" })
}

# "Si un health check falla determinado numero de veces": el health check del
# contenedor ya reintenta 3 veces cada 30 segundos antes de declarar UNHEALTHY, y
# ECS entonces mata la tarea. Esta alarma cuenta cuantas veces ocurre eso -mas
# los arranques fallidos- en la ventana, que es lo que distingue una tarea
# reemplazada de un servicio que no logra levantar.
resource "aws_cloudwatch_metric_alarm" "backend_task_restarts" {
  count = local.ecs_events_enabled ? 1 : 0

  alarm_name          = "${var.name}-backend-task-restart"
  alarm_description   = "Una tarea del backend se detuvo sin que nadie lo pidiera: health check fallido, arranque fallido o contenedor esencial caido. Mirar stoppedReason en /aws/events/${var.name}/ecs-task-state."
  namespace           = var.custom_metric_namespace
  metric_name         = "UnexpectedTaskStops"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions

  tags = merge(var.tags, { Severity = "warning" })
}

resource "aws_cloudwatch_metric_alarm" "backend_crash_loop" {
  count = local.ecs_events_enabled ? 1 : 0

  alarm_name          = "${var.name}-backend-crash-loop"
  alarm_description   = "${var.backend_crash_loop_threshold} o mas paradas inesperadas de tarea en ${var.backend_crash_loop_window_seconds / 60} minutos: el backend no logra sostenerse arriba. Mirar stoppedReason en /aws/events/${var.name}/ecs-task-state y el arranque en ${local.backend_log_group_hint}."
  namespace           = var.custom_metric_namespace
  metric_name         = "UnexpectedTaskStops"
  statistic           = "Sum"
  period              = var.backend_crash_loop_window_seconds
  evaluation_periods  = 1
  threshold           = var.backend_crash_loop_threshold
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.critical_actions

  tags = merge(var.tags, { Severity = "critical" })
}

# Fargate Spot es la unica capacidad de dev. Perder la tarea por una recuperacion
# de Spot es esperable y no es un incidente, pero verlo en Slack evita que se
# investigue como si lo fuera.
resource "aws_cloudwatch_metric_alarm" "backend_spot_interruptions" {
  count = local.ecs_events_enabled ? 1 : 0

  alarm_name          = "${var.name}-backend-spot-interruptions"
  alarm_description   = "AWS recupero capacidad Fargate Spot y detuvo la tarea. Es el precio del descuento de dev, no una falla del backend. Mirar el historial de despliegues del servicio ${var.ecs_service_name}."
  namespace           = var.custom_metric_namespace
  metric_name         = "SpotInterruptions"
  statistic           = "Sum"
  period              = 900
  evaluation_periods  = 1
  threshold           = 2
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions

  tags = merge(var.tags, { Severity = "warning" })
}

# El interruptor de hombre muerto del backend, en dos senales internas y una
# compuesta. Solo con Container Insights: ni RunningTaskCount ni DesiredTaskCount
# existen en AWS/ECS.
#
# La version anterior de esto era una sola alarma sobre RunningTaskCount con
# treat_missing_data = "breaching", razonando que su proposito es detectar
# ausencia. El razonamiento era correcto y la construccion no: dev se apaga a
# voluntad en horario habil, no solo por el schedule de las 20:00, asi que esa
# alarma habria sonado cada vez que alguien hace algo deliberado y normal. Una
# ventana de mantenimiento no lo arregla, porque un apagado manual no tiene hora.
#
# La forma correcta no es alarmar sobre la ausencia sino usarla como COMPUERTA,
# igual que el interruptor de log_shipping:
#
#   ALARM(no hay tareas corriendo) AND ALARM(ECS quiere tareas)
#
# Un apagado -programado o manual- pone desired en 0, la compuerta se cierra sola
# y no suena nada. Un fallo real -imagen rota, sin capacidad Spot, crash loop en
# el arranque- deja desired > 0 con running en 0, y ahi si hay incidente.

# Senal 1: no hay tareas. "breaching" es correcto aqui y ya no es peligroso,
# porque esta alarma no notifica: si Container Insights deja de publicar, el
# hueco tiene que contar como "no hay tareas" o el interruptor se queda ciego
# exactamente igual que antes.
resource "aws_cloudwatch_metric_alarm" "backend_no_running_tasks" {
  count = var.container_insights_enabled ? 1 : 0

  alarm_name          = "${var.name}-backend-no-running-tasks"
  alarm_description   = "Cuenta las tareas en ejecucion del servicio ${var.ecs_service_name} (RunningTaskCount), tratando la ausencia de metrica como cero. Senal interna: no notifica por si sola, alimenta la compuesta ${var.name}-backend-service-down. Donde mirar: los eventos del servicio y stoppedReason en /aws/events/${var.name}/ecs-task-state."
  namespace           = "ECS/ContainerInsights"
  metric_name         = "RunningTaskCount"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 5
  datapoints_to_alarm = 5
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"

  # No notifica: sonaria en cada apagado, y el apagado de dev es deliberado y
  # frecuente. La decision de avisar la toma la compuesta, que ademas sabe si
  # ECS queria tareas.
  actions_enabled = false

  dimensions = {
    ClusterName = var.ecs_cluster_name
    ServiceName = var.ecs_service_name
  }

  tags = merge(var.tags, { Severity = "internal" })
}

# Senal 2: la compuerta. En ALARM significa "ECS quiere al menos una tarea", que
# es una inversion deliberada del sentido habitual, porque una compuesta solo
# sabe combinar estados de alarma.
#
# La ventana es MAS CORTA que la de la senal 1, y eso es lo que hay que conservar
# si alguien toca los periodos: al apagar, esta debe volver a OK -y cerrar la
# compuerta- antes de que la senal 1 entre en ALARM. Con dos periodos aqui y
# cinco alla quedan tres minutos de margen. Si algun dia llega un aviso justo
# despues de un apagado, la correccion es ampliar la senal 1, nunca alargar esta:
# alargarla retrasa tambien la deteccion del fallo real.
#
# notBreaching es lo correcto para el hueco: un servicio que dejo de publicar
# DesiredTaskCount no esta pidiendo tareas, y con el ambiente entero apagado no
# hay nada que exigir. El caso que esto deja descubierto -el servicio ECS borrado
# por completo- no es una caida del backend sino una destruccion de
# infraestructura, y lo delata el plan, no una alarma.
resource "aws_cloudwatch_metric_alarm" "backend_tasks_wanted" {
  count = var.container_insights_enabled ? 1 : 0

  alarm_name          = "${var.name}-backend-tasks-wanted"
  alarm_description   = "Cuenta las tareas que el servicio ${var.ecs_service_name} pide tener (DesiredTaskCount). Senal interna e invertida: en ALARM significa que ECS quiere tareas y por tanto un servicio vacio seria un incidente. No notifica; habilita la compuesta ${var.name}-backend-service-down fuera de los apagados, programados o manuales."
  namespace           = "ECS/ContainerInsights"
  metric_name         = "DesiredTaskCount"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  actions_enabled     = false

  dimensions = {
    ClusterName = var.ecs_cluster_name
    ServiceName = var.ecs_service_name
  }

  tags = merge(var.tags, { Severity = "internal" })
}

# La compuesta: ECS quiere tareas y no las tiene. Es la unica de las tres que
# notifica, y la unica formulacion de "el backend no esta" que no confunde un
# apagado deliberado con una caida.
resource "aws_cloudwatch_composite_alarm" "backend_service_down" {
  count = var.container_insights_enabled && local.notification_topic_enabled ? 1 : 0

  alarm_name        = "${var.name}-backend-service-down"
  alarm_description = "El servicio ${var.ecs_service_name} no tiene ninguna tarea corriendo mientras ECS si esta pidiendo tareas. Donde mirar: los eventos del servicio -si menciona RESOURCE:FARGATE es falta de capacidad Spot-, stoppedReason en /aws/events/${var.name}/ecs-task-state y el arranque en ${local.backend_log_group_hint}."

  alarm_rule = join(" AND ", [
    "ALARM(\"${aws_cloudwatch_metric_alarm.backend_no_running_tasks[0].alarm_name}\")",
    "ALARM(\"${aws_cloudwatch_metric_alarm.backend_tasks_wanted[0].alarm_name}\")",
  ])

  actions_enabled = true
  alarm_actions   = local.critical_actions

  tags = merge(var.tags, { Severity = "critical" })
}
