# Silencio programado de las ventanas de mantenimiento.
#
# El problema que resuelve: hasta ahora el silencio del apagado nocturno se
# compraba con `treat_missing_data = "notBreaching"` en casi todas las alarmas.
# Ese ajuste no silencia una ventana: silencia la ausencia de datos las 24 horas.
# Una alarma que trata la ausencia como buena no distingue "todo bien" de
# "muerto", y ese es el precio que se venia pagando todo el dia para no recibir
# una notificacion a las 20:15.
#
# `aws_cloudwatch_alarm_mute_rule` separa las dos cosas: la alarma sigue
# evaluando y cambiando de estado -se ve en el panel y en el historial-, pero no
# ejecuta sus acciones dentro de la ventana. Al cerrarse la ventana CloudWatch
# re-evalua y re-notifica lo que siga mal, asi que nada se pierde por haber
# callado.
#
# Limite del servicio: 100 alarmas por regla. El inventario completo de dev
# -monitoreo mas log_shipping- ronda las 35, con holgura de sobra.
#
# Lo que NO se silencia: `alloy_recovery`. Su accion no es una notificacion, es
# `arn:aws:automate:...:ec2:recover`. Silenciar una alarma que dispara una
# remediacion automatica no calla un mensaje, cancela la remediacion. Es la misma
# distincion que separa un canal que lee una persona de un sistema que actua.
#
# Y tampoco `bedrock_invocation_surge`, por un motivo distinto. Las demas alarmas
# de esta lista miden el entorno, y el entorno se apaga a las 20:00: su ruido
# nocturno es esperado. El gasto de Bedrock no lo produce el entorno sino quien
# manda peticiones a un endpoint publico, y sigue siendo posible con el backend
# apagado -bastan unas credenciales filtradas-. Un pico de gasto a las 21:00, sin
# nadie mirando, es exactamente el que hay que oir. Anadirla aqui "por
# coherencia" es la forma barata de dejar de verlo; el contrato
# `bedrock_cost_controls.muted_by_maintenance_window` lo afirma en las pruebas.

locals {
  # Nombres, no ARNs: la API de mute rules referencia alarmas por nombre. Todos
  # se derivan de var.name, asi que son conocidos en plan y la regla se puede
  # revisar entera en el PR.
  muted_alarm_candidates = concat(
    [
      aws_cloudwatch_metric_alarm.database_cpu.alarm_name,
      aws_cloudwatch_metric_alarm.database_cpu_critical.alarm_name,
      aws_cloudwatch_metric_alarm.database_connections.alarm_name,
      aws_cloudwatch_metric_alarm.database_connections_critical.alarm_name,
      aws_cloudwatch_metric_alarm.database_storage.alarm_name,
      aws_cloudwatch_metric_alarm.database_storage_critical.alarm_name,
      aws_cloudwatch_metric_alarm.database_memory.alarm_name,
      aws_cloudwatch_metric_alarm.database_memory_critical.alarm_name,
      aws_cloudwatch_metric_alarm.database_swap.alarm_name,
      aws_cloudwatch_metric_alarm.database_disk_queue.alarm_name,
      aws_cloudwatch_metric_alarm.database_cpu_credits.alarm_name,
      aws_cloudwatch_metric_alarm.backend_cpu.alarm_name,
      aws_cloudwatch_metric_alarm.backend_cpu_critical.alarm_name,
      aws_cloudwatch_metric_alarm.backend_memory.alarm_name,
      aws_cloudwatch_metric_alarm.backend_memory_critical.alarm_name,
      aws_cloudwatch_metric_alarm.cloudflare_tunnel_errors.alarm_name,
    ],
    [for alarm in aws_cloudwatch_metric_alarm.database_latency : alarm.alarm_name],
    [for alarm in aws_cloudwatch_metric_alarm.database_ebs_balance : alarm.alarm_name],
    [for alarm in aws_cloudwatch_metric_alarm.alloy_status : alarm.alarm_name],
    aws_cloudwatch_metric_alarm.backend_task_restarts[*].alarm_name,
    aws_cloudwatch_metric_alarm.backend_crash_loop[*].alarm_name,
    aws_cloudwatch_metric_alarm.backend_spot_interruptions[*].alarm_name,
    aws_cloudwatch_metric_alarm.backend_no_running_tasks[*].alarm_name,
    aws_cloudwatch_metric_alarm.backend_tasks_wanted[*].alarm_name,
    aws_cloudwatch_metric_alarm.cache_data_storage[*].alarm_name,
    aws_cloudwatch_metric_alarm.cache_ecpu[*].alarm_name,
    aws_cloudwatch_metric_alarm.cache_throttled[*].alarm_name,
    aws_cloudwatch_metric_alarm.cache_authentication_failures[*].alarm_name,
    aws_cloudwatch_metric_alarm.telemetry_sidecar_stopped[*].alarm_name,
    aws_cloudwatch_metric_alarm.telemetry_sidecar_errors[*].alarm_name,
    aws_cloudwatch_composite_alarm.database_saturated[*].alarm_name,
    aws_cloudwatch_composite_alarm.backend_degraded[*].alarm_name,
    aws_cloudwatch_composite_alarm.backend_service_down[*].alarm_name,
    var.additional_muted_alarm_names,
  )

  muted_alarm_names = sort(distinct(compact(local.muted_alarm_candidates)))

  maintenance_mute_enabled = length(var.maintenance_mute_windows) > 0 && length(local.muted_alarm_names) > 0
}

resource "aws_cloudwatch_alarm_mute_rule" "maintenance" {
  for_each = local.maintenance_mute_enabled ? var.maintenance_mute_windows : {}

  name = "${var.name}-mute-${each.key}"
  description = trimspace(each.value.description) != "" ? each.value.description : (
    "Ventana de mantenimiento planificado del entorno ${var.name}."
  )

  mute_targets {
    alarm_names = local.muted_alarm_names
  }

  rule {
    schedule {
      expression = each.value.expression
      duration   = each.value.duration
      # Sin zona horaria explicita la ventana se evalua en UTC y en Bogota se
      # correria cinco horas: silenciaria de 15:00 a 03:00, o sea justo la
      # jornada laboral y nada del apagado.
      timezone = var.maintenance_mute_timezone
    }
  }

  tags = merge(var.tags, { Signal = "maintenance-window" })
}
