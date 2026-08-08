output "alarm_topic_arn" {
  value = length(aws_sns_topic.alarms) > 0 ? aws_sns_topic.alarms[0].arn : null
}

output "critical_alarm_topic_arn" {
  description = "Topic SNS de severidad critica; el candidato natural para enrutar a PagerDuty u Opsgenie cuando exista guardia."
  value       = length(aws_sns_topic.alarms_critical) > 0 ? aws_sns_topic.alarms_critical[0].arn : null
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
    slack_enabled              = local.slack_notifications_enabled
    dedicated_critical_channel = local.dedicated_critical_channel
    ecs_events_enabled         = local.ecs_events_enabled
    database_events_enabled    = local.database_events_enabled
    cache_alarms_enabled       = local.cache_alarms_enabled
    container_insights_alarms  = var.container_insights_enabled

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

output "slack_chat_configuration_arn" {
  description = "ARN de la configuración Amazon Q Developer/Slack cuando está habilitada."
  value       = length(aws_chatbot_slack_channel_configuration.alarms) > 0 ? aws_chatbot_slack_channel_configuration.alarms[0].chat_configuration_arn : null
}
