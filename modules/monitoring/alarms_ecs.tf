# Alarmas del servicio ECS.
#
# CPUUtilization y MemoryUtilization del namespace AWS/ECS son metricas de
# servicio y se publican sin Container Insights, que en dev esta apagado por
# costo. Todo lo que dependa de ECS/ContainerInsights -RunningTaskCount, memoria
# por contenedor- queda detras de container_insights_enabled.
#
# treat_missing_data es "notBreaching" en todas: el entorno se apaga cada noche y
# una alarma que interpreta "sin datos" como falla convierte el apagado
# programado en una pagina diaria que nadie va a atender.

resource "aws_cloudwatch_metric_alarm" "backend_cpu" {
  alarm_name          = "${var.name}-backend-high-cpu"
  alarm_description   = "ADVERTENCIA · CPU del servicio ECS por encima de ${var.backend_cpu_warning_percent}% durante 10 minutos."
  namespace           = "AWS/ECS"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  threshold           = var.backend_cpu_warning_percent
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions

  dimensions = {
    ClusterName = var.ecs_cluster_name
    ServiceName = var.ecs_service_name
  }

  tags = merge(var.tags, { Severity = "warning" })
}

resource "aws_cloudwatch_metric_alarm" "backend_cpu_critical" {
  alarm_name          = "${var.name}-backend-cpu-saturated"
  alarm_description   = "CRITICO · CPU del servicio ECS por encima de ${var.backend_cpu_critical_percent}% durante 15 minutos: las peticiones se estan encolando."
  namespace           = "AWS/ECS"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  datapoints_to_alarm = 3
  threshold           = var.backend_cpu_critical_percent
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.critical_actions
  ok_actions          = local.critical_actions

  dimensions = {
    ClusterName = var.ecs_cluster_name
    ServiceName = var.ecs_service_name
  }

  tags = merge(var.tags, { Severity = "critical" })
}

resource "aws_cloudwatch_metric_alarm" "backend_memory" {
  alarm_name          = "${var.name}-backend-high-memory"
  alarm_description   = "ADVERTENCIA · Memoria del servicio ECS por encima de ${var.backend_memory_warning_percent}% durante 10 minutos."
  namespace           = "AWS/ECS"
  metric_name         = "MemoryUtilization"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  threshold           = var.backend_memory_warning_percent
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions

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
  alarm_description   = "CRITICO · Memoria del servicio ECS por encima de ${var.backend_memory_critical_percent}%: la JVM esta a un pico de que el kernel mate la tarea."
  namespace           = "AWS/ECS"
  metric_name         = "MemoryUtilization"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 5
  datapoints_to_alarm = 3
  threshold           = var.backend_memory_critical_percent
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.critical_actions
  ok_actions          = local.critical_actions

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
resource "aws_cloudwatch_metric_alarm" "cloudflare_tunnel_errors" {
  alarm_name          = "${var.name}-cloudflare-tunnel-errors"
  alarm_description   = "CRITICO · El conector Cloudflare Tunnel reporto errores: la API publica de ${var.name} puede estar inalcanzable."
  namespace           = "VetSoftware/CloudflareTunnel"
  metric_name         = "ConnectorErrors"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.critical_actions
  ok_actions          = local.critical_actions

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
  alarm_description   = "ADVERTENCIA · Una tarea del backend se detuvo sin que nadie lo pidiera: health check fallido, arranque fallido o contenedor esencial caido."
  namespace           = var.custom_metric_namespace
  metric_name         = "UnexpectedTaskStops"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions

  tags = merge(var.tags, { Severity = "warning" })
}

resource "aws_cloudwatch_metric_alarm" "backend_crash_loop" {
  count = local.ecs_events_enabled ? 1 : 0

  alarm_name          = "${var.name}-backend-crash-loop"
  alarm_description   = "CRITICO · ${var.backend_crash_loop_threshold} o mas paradas inesperadas de tarea en ${var.backend_crash_loop_window_seconds / 60} minutos: el backend no logra sostenerse arriba."
  namespace           = var.custom_metric_namespace
  metric_name         = "UnexpectedTaskStops"
  statistic           = "Sum"
  period              = var.backend_crash_loop_window_seconds
  evaluation_periods  = 1
  threshold           = var.backend_crash_loop_threshold
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.critical_actions
  ok_actions          = local.critical_actions

  tags = merge(var.tags, { Severity = "critical" })
}

# Fargate Spot es la unica capacidad de dev. Perder la tarea por una recuperacion
# de Spot es esperable y no es un incidente, pero verlo en Slack evita que se
# investigue como si lo fuera.
resource "aws_cloudwatch_metric_alarm" "backend_spot_interruptions" {
  count = local.ecs_events_enabled ? 1 : 0

  alarm_name          = "${var.name}-backend-spot-interruptions"
  alarm_description   = "ADVERTENCIA · AWS recupero capacidad Fargate Spot y detuvo la tarea. Es el precio del descuento de dev, no una falla del backend."
  namespace           = var.custom_metric_namespace
  metric_name         = "SpotInterruptions"
  statistic           = "Sum"
  period              = 900
  evaluation_periods  = 1
  threshold           = 2
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions

  tags = merge(var.tags, { Severity = "warning" })
}

# Solo con Container Insights: RunningTaskCount no existe en AWS/ECS.
# treat_missing_data se queda en notBreaching para no gritar durante el apagado
# nocturno, cuando el servicio baja a cero deliberadamente.
resource "aws_cloudwatch_metric_alarm" "backend_no_running_tasks" {
  count = var.container_insights_enabled ? 1 : 0

  alarm_name          = "${var.name}-backend-no-running-tasks"
  alarm_description   = "CRITICO · El servicio ECS no tiene ninguna tarea corriendo mientras el conteo deseado es mayor que cero."
  namespace           = "ECS/ContainerInsights"
  metric_name         = "RunningTaskCount"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 5
  datapoints_to_alarm = 5
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.critical_actions
  ok_actions          = local.critical_actions

  dimensions = {
    ClusterName = var.ecs_cluster_name
    ServiceName = var.ecs_service_name
  }

  tags = merge(var.tags, { Severity = "critical" })
}
