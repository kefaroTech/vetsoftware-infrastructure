output "alarm_topic_arn" {
  description = "Topic SNS de advertencias; es el destino por defecto de todo lo que no sea critico."
  value       = length(aws_sns_topic.alarms) > 0 ? aws_sns_topic.alarms[0].arn : null
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

    composite_alarm_names = concat(
      local.notification_topic_enabled ? [
        aws_cloudwatch_composite_alarm.database_saturated[0].alarm_name,
        aws_cloudwatch_composite_alarm.backend_degraded[0].alarm_name,
      ] : [],
      aws_cloudwatch_composite_alarm.backend_service_down[*].alarm_name,
    )

    # Higiene de alertas. Se publica en el contrato porque es exactamente lo que
    # se degrada solo: alguien vuelve a pegar un `ok_actions`, alguien escribe
    # "CRITICO" en un `alarm_description`, o alguien crea una alarma nueva que la
    # ventana de mantenimiento no cubre. Con esto las pruebas lo afirman sin
    # tener que leer recurso por recurso.
    notify_on_recovery = false

    maintenance_mute = {
      enabled  = local.maintenance_mute_enabled
      timezone = var.maintenance_mute_timezone
      windows = {
        for key, window in var.maintenance_mute_windows :
        key => "${window.expression} durante ${window.duration}"
      }
      muted_alarms = length(local.muted_alarm_names)

      # Excluida a proposito: su accion no es una notificacion sino
      # arn:aws:automate:...:ec2:recover. Silenciarla cancelaria la remediacion.
      excluded_alarms = [for alarm in aws_cloudwatch_metric_alarm.alloy_recovery : alarm.alarm_name]
    }

    missing_data = {
      continuous_metrics = var.continuous_metric_missing_data
      cpu_credits        = aws_cloudwatch_metric_alarm.database_cpu_credits.treat_missing_data
    }

    # Interruptor de hombre muerto del backend, afirmable en plan. Los dos
    # treat_missing_data son opuestos a proposito y esa oposicion ES el
    # mecanismo: el hueco de tareas corriendo significa "no hay backend", el
    # hueco de tareas pedidas significa "nadie las esta pidiendo". Invertir
    # cualquiera de los dos hace que un apagado deliberado vuelva a sonar.
    #
    # Nulo mientras Container Insights siga apagado: ni RunningTaskCount ni
    # DesiredTaskCount existen en el namespace AWS/ECS.
    backend_dead_mans_switch = var.container_insights_enabled ? {
      running_alarm_name    = aws_cloudwatch_metric_alarm.backend_no_running_tasks[0].alarm_name
      running_missing_data  = aws_cloudwatch_metric_alarm.backend_no_running_tasks[0].treat_missing_data
      running_notifies      = aws_cloudwatch_metric_alarm.backend_no_running_tasks[0].actions_enabled
      running_range_seconds = aws_cloudwatch_metric_alarm.backend_no_running_tasks[0].evaluation_periods * aws_cloudwatch_metric_alarm.backend_no_running_tasks[0].period
      wanted_alarm_name     = aws_cloudwatch_metric_alarm.backend_tasks_wanted[0].alarm_name
      wanted_metric         = aws_cloudwatch_metric_alarm.backend_tasks_wanted[0].metric_name
      wanted_missing_data   = aws_cloudwatch_metric_alarm.backend_tasks_wanted[0].treat_missing_data
      wanted_notifies       = aws_cloudwatch_metric_alarm.backend_tasks_wanted[0].actions_enabled
      wanted_range_seconds  = aws_cloudwatch_metric_alarm.backend_tasks_wanted[0].evaluation_periods * aws_cloudwatch_metric_alarm.backend_tasks_wanted[0].period
      composite_alarm_names = aws_cloudwatch_composite_alarm.backend_service_down[*].alarm_name
      composite_alarm_rules = aws_cloudwatch_composite_alarm.backend_service_down[*].alarm_rule
    } : null
  }
}

# Inventario plano de todo lo que este modulo puede silenciar. Lo consume el
# root para verificar que la ventana de mantenimiento cubre el entorno entero, y
# sirve de base si algun dia hay que enrutar a una guardia.
output "muted_alarm_names" {
  description = "Alarmas cubiertas por las ventanas de mantenimiento, incluidas las recibidas de otros modulos."
  value       = local.muted_alarm_names
}

output "maintenance_mute_rule_arns" {
  description = "ARN de cada regla de silencio programado; vacio cuando no hay ventanas declaradas."
  value       = { for key, rule in aws_cloudwatch_alarm_mute_rule.maintenance : key => rule.arn }
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
