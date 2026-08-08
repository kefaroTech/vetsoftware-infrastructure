# Alarmas compuestas.
#
# No duplican avisos: sus hijas son todas de severidad advertencia y solo
# publican en el topico normal. Lo que aportan es la correlacion, que es
# exactamente la pregunta que el negocio hizo -"la base esta con sobreconsumo y
# se puede caer"- y que ninguna metrica sola responde. CPU al 80% no es un
# incidente; CPU al 80% con el pool de conexiones lleno y la memoria libre en el
# piso es una base que se cae en los proximos minutos.
#
# Por eso escalan al topico critico aunque cada hija por separado no lo haga.

resource "aws_cloudwatch_composite_alarm" "database_saturated" {
  count = local.notification_topic_enabled ? 1 : 0

  alarm_name        = "${var.name}-database-saturated"
  alarm_description = "CRITICO · Correlacion de saturacion en RDS: dos o mas señales de agotamiento activas a la vez. La base no esta lenta, esta a punto de caerse."

  alarm_rule = join(" OR ", [
    "(ALARM(\"${aws_cloudwatch_metric_alarm.database_cpu.alarm_name}\") AND ALARM(\"${aws_cloudwatch_metric_alarm.database_connections.alarm_name}\"))",
    "(ALARM(\"${aws_cloudwatch_metric_alarm.database_cpu.alarm_name}\") AND ALARM(\"${aws_cloudwatch_metric_alarm.database_memory.alarm_name}\"))",
    "(ALARM(\"${aws_cloudwatch_metric_alarm.database_connections.alarm_name}\") AND ALARM(\"${aws_cloudwatch_metric_alarm.database_memory.alarm_name}\"))",
    "(ALARM(\"${aws_cloudwatch_metric_alarm.database_memory.alarm_name}\") AND ALARM(\"${aws_cloudwatch_metric_alarm.database_swap.alarm_name}\"))",
  ])

  actions_enabled = true
  alarm_actions   = local.critical_actions
  ok_actions      = local.critical_actions

  tags = merge(var.tags, { Severity = "critical" })
}

# El servicio corre con una sola tarea y max_count = 1: no hay a donde escalar.
# CPU y memoria altas al mismo tiempo sobre una unica tarea sin holgura no es
# carga, es la antesala del OOM.
resource "aws_cloudwatch_composite_alarm" "backend_degraded" {
  count = local.notification_topic_enabled ? 1 : 0

  alarm_name        = "${var.name}-backend-degraded"
  alarm_description = "CRITICO · CPU y memoria del backend altas a la vez sobre una unica tarea sin capacidad de escalar. El siguiente pico no lo absorbe nadie."

  alarm_rule = "ALARM(\"${aws_cloudwatch_metric_alarm.backend_cpu.alarm_name}\") AND ALARM(\"${aws_cloudwatch_metric_alarm.backend_memory.alarm_name}\")"

  actions_enabled = true
  alarm_actions   = local.critical_actions
  ok_actions      = local.critical_actions

  tags = merge(var.tags, { Severity = "critical" })
}
