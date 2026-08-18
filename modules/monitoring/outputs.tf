output "alarm_topic_arn" {
  value = length(aws_sns_topic.alarms) > 0 ? aws_sns_topic.alarms[0].arn : null
}

output "critical_alarm_topic_arn" {
  description = "Topic SNS de severidad critica; el candidato natural para enrutar a PagerDuty u Opsgenie cuando exista guardia."
  value       = length(aws_sns_topic.alarms_critical) > 0 ? aws_sns_topic.alarms_critical[0].arn : null
}

output "events_topic_arn" {
  description = "Topic de eventos: despliegues, apagados y eventos de ECS y RDS."
  value       = length(aws_sns_topic.events) > 0 ? aws_sns_topic.events[0].arn : null
}

output "finops_topic_arn" {
  description = "Topic de costos: informe diario, presupuesto y anomalias."
  value       = length(aws_sns_topic.finops) > 0 ? aws_sns_topic.finops[0].arn : null
}

# Inventario declarativo del contrato de alertas. Sirve para dos cosas: que las
# pruebas afirmen sobre umbrales concretos sin leer cada recurso, y que la
# documentacion se pueda regenerar desde el estado en vez de escribirse a mano y
# quedar desactualizada.
output "alerting" {
  description = "Contrato de alertas del entorno: severidades, umbrales derivados y circuitos activos."
  value = {
    warning_topic_arn          = length(aws_sns_topic.alarms) > 0 ? aws_sns_topic.alarms[0].arn : null
    critical_topic_arn         = length(aws_sns_topic.alarms_critical) > 0 ? aws_sns_topic.alarms_critical[0].arn : null
    events_topic_arn           = length(aws_sns_topic.events) > 0 ? aws_sns_topic.events[0].arn : null
    finops_topic_arn           = length(aws_sns_topic.finops) > 0 ? aws_sns_topic.finops[0].arn : null
    slack_enabled              = local.slack_notifications_enabled
    dedicated_critical_channel = local.dedicated_critical_channel
    ecs_events_enabled         = local.ecs_events_enabled
    database_events_enabled    = local.database_events_enabled
    cache_alarms_enabled       = local.cache_alarms_enabled
    container_insights_alarms  = var.container_insights_enabled

    # Que familia de senal llega a que canal. Es el contrato que hay que revisar
    # cuando alguien dice "esto no me llego": dice si el problema es de ruteo o
    # de entrega.
    channel_routing = local.slack_notifications_enabled ? {
      alerts   = local.alerts_channel
      critical = local.critical_channel
      infra    = local.infra_channel
      finops   = local.finops_channel
    } : {}

    backend = {
      cpu_warning_percent     = var.backend_cpu_warning_percent
      cpu_critical_percent    = var.backend_cpu_critical_percent
      memory_warning_percent  = var.backend_memory_warning_percent
      memory_critical_percent = var.backend_memory_critical_percent
      crash_loop_threshold    = var.backend_crash_loop_threshold
      crash_loop_window_min   = var.backend_crash_loop_window_seconds / 60
    }

    database = {
      cpu_warning_percent            = var.database_cpu_warning_percent
      cpu_critical_percent           = var.database_cpu_critical_percent
      max_connections                = var.database_max_connections
      connections_warning            = local.database_connections_warning_threshold
      connections_critical           = local.database_connections_critical_threshold
      free_storage_warning_bytes     = local.database_free_storage_warning_bytes
      free_storage_critical_bytes    = local.database_free_storage_critical_bytes
      freeable_memory_warning_bytes  = var.database_freeable_memory_threshold_bytes
      freeable_memory_critical_bytes = var.database_freeable_memory_critical_bytes
      swap_warning_bytes             = var.database_swap_warning_bytes
      latency_warning_ms             = var.database_latency_warning_seconds * 1000
    }

    composite_alarm_names = local.notification_topic_enabled ? [
      aws_cloudwatch_composite_alarm.database_saturated[0].alarm_name,
      aws_cloudwatch_composite_alarm.backend_degraded[0].alarm_name,
    ] : []
  }
}

output "cost_anomaly_monitor_arn" {
  description = "ARN del monitor de anomalías por servicio cuando está habilitado."
  value       = length(aws_ce_anomaly_monitor.services) > 0 ? aws_ce_anomaly_monitor.services[0].arn : null
}

output "slack_chat_configuration_arns" {
  description = "ARN de cada configuración Amazon Q Developer/Slack, una por canal."
  value       = [for config in aws_chatbot_slack_channel_configuration.channels : config.chat_configuration_arn]
}

output "telemetry_sidecar_alarm_names" {
  description = "Alarmas del sidecar colector; vacio cuando el sidecar o el ruteo de notificaciones estan apagados."
  value = local.telemetry_alarms_enabled ? [
    aws_cloudwatch_metric_alarm.telemetry_sidecar_stopped[0].alarm_name,
    aws_cloudwatch_metric_alarm.telemetry_sidecar_errors[0].alarm_name,
  ] : []
}
