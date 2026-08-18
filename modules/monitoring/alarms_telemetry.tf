# Alarmas del sidecar colector de trazas y metricas.
#
# El sidecar es `essential = false`. Esa bandera es deliberada -si el colector
# cae, la API sigue en pie- pero tiene un precio exacto: ECS no reemplaza la
# tarea, no emite una parada y nadie se entera. La telemetria simplemente deja de
# llegar y el primero en notarlo es quien va a mirar un panel dos dias despues.
# Sin lo que sigue, `essential = false` seria una forma silenciosa de perder
# trazas.
#
# Se cubren las dos formas en que este tramo falla:
#
#   1. Muerto. El contenedor salio y el resto de la tarea siguio corriendo.
#   2. Vivo pero roto. Arranca, se queja y no exporta -credenciales, endpoint,
#      un path que `readonlyRootFilesystem` no le deja escribir-.
#
# La tercera forma, "vivo, sin errores y sin entregar", NO se puede ver desde
# CloudWatch: las series que lo demuestran -otelcol_exporter_send_failed_spans,
# otelcol_exporter_enqueue_failed_spans, otelcol_exporter_queue_size- son
# metricas internas del colector y viajan a Grafana Cloud por el mismo pipeline
# durable que todo lo demas. Sus expresiones exactas estan en
# docs/ALERTAS_OPERATIVAS.md y viven como reglas de Grafana Cloud, no aqui.
#
# treat_missing_data es "notBreaching" en las dos, como en el resto del entorno:
# dev se apaga cada noche y una alarma que lea "sin datos" como falla se
# convierte en una pagina diaria que nadie atiende.

locals {
  telemetry_alarms_enabled = (
    var.telemetry_sidecar_enabled &&
    local.notification_topic_enabled &&
    trimspace(var.telemetry_sidecar_log_group_name) != ""
  )

  # Un contenedor parado dentro de una tarea que sigue RUNNING solo puede ser el
  # sidecar: el backend y cloudflared son `essential`, y su muerte para la tarea
  # entera -con lo que el evento ya no cumpliria el patron de la regla-. Se
  # recorren todas las posiciones del array porque EventBridge y los filtros de
  # metrica no garantizan el orden de `containers`, y comprobarlas todas hace que
  # el orden deje de importar.
  telemetry_stopped_pattern = format(
    "{ %s }",
    join(" || ", [
      for index in range(var.telemetry_task_container_count) :
      "($.detail.containers[${index}].lastStatus = \"STOPPED\")"
    ])
  )
}

resource "aws_cloudwatch_log_group" "telemetry_container_events" {
  count = local.telemetry_alarms_enabled ? 1 : 0

  # El prefijo /aws/events/ no es cosmetico: es el que habilita el modelo de
  # permisos por resource policy que usa EventBridge para escribir en Logs.
  name              = "/aws/events/${var.name}/telemetry-container-state"
  retention_in_days = var.event_log_retention_days
  kms_key_id        = trimspace(var.sns_kms_key_arn) != "" ? var.sns_kms_key_arn : null

  tags = var.tags
}

data "aws_iam_policy_document" "telemetry_events_to_logs" {
  count = local.telemetry_alarms_enabled ? 1 : 0

  statement {
    sid    = "EventBridgeToCloudWatchLogs"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com", "delivery.logs.amazonaws.com"]
    }

    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.telemetry_container_events[0].arn}:*"]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_cloudwatch_log_resource_policy" "telemetry_events_to_logs" {
  count = local.telemetry_alarms_enabled ? 1 : 0

  policy_name     = "${var.name}-telemetry-events-to-logs"
  policy_document = data.aws_iam_policy_document.telemetry_events_to_logs[0].json
}

# Deliberadamente distinta de la regla de `events_ecs.tf`: aquella archiva
# paradas de TAREA -lastStatus STOPPED- y por definicion nunca vera morir a un
# contenedor no esencial, porque en ese caso la tarea sigue RUNNING. Esta archiva
# el caso contrario: tarea viva, contenido cambiando por dentro.
resource "aws_cloudwatch_event_rule" "telemetry_container_state" {
  count = local.telemetry_alarms_enabled ? 1 : 0

  name        = "${var.name}-telemetry-container-state"
  description = "Archiva los cambios de contenedor dentro de tareas que siguen corriendo, unica forma de ver morir un sidecar no esencial."

  event_pattern = jsonencode({
    source        = ["aws.ecs"]
    "detail-type" = ["ECS Task State Change"]
    detail = {
      clusterArn    = [var.ecs_cluster_arn]
      lastStatus    = ["RUNNING"]
      desiredStatus = ["RUNNING"]
    }
  })

  tags = var.tags
}

resource "aws_cloudwatch_event_target" "telemetry_container_state_archive" {
  count = local.telemetry_alarms_enabled ? 1 : 0

  rule      = aws_cloudwatch_event_rule.telemetry_container_state[0].name
  target_id = "archive-to-logs"
  arn       = aws_cloudwatch_log_group.telemetry_container_events[0].arn
}

resource "aws_cloudwatch_log_metric_filter" "telemetry_sidecar_stopped" {
  count = local.telemetry_alarms_enabled ? 1 : 0

  name           = "${var.name}-telemetry-sidecar-stopped"
  log_group_name = aws_cloudwatch_log_group.telemetry_container_events[0].name
  pattern        = local.telemetry_stopped_pattern

  metric_transformation {
    name          = "TelemetrySidecarStopped"
    namespace     = var.custom_metric_namespace
    value         = "1"
    default_value = "0"
    unit          = "Count"
  }
}

resource "aws_cloudwatch_metric_alarm" "telemetry_sidecar_stopped" {
  count = local.telemetry_alarms_enabled ? 1 : 0

  alarm_name          = "${var.name}-telemetry-sidecar-stopped"
  alarm_description   = "CRITICO · El sidecar colector se detuvo con la tarea todavia corriendo. Las trazas y metricas dejaron de tener cola durable y ECS no va a reemplazarlo: hay que forzar un despliegue. La causa esta en ${var.telemetry_sidecar_log_group_name}."
  namespace           = var.custom_metric_namespace
  metric_name         = "TelemetrySidecarStopped"
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

# El colector escribe sus propios logs en JSON -se fuerza con
# service.telemetry.logs.encoding en la plantilla- justamente para que este
# filtro pueda consultar $.level. Con el encoder de consola por defecto no
# habria campo que consultar y este filtro no encontraria nada nunca.
resource "aws_cloudwatch_log_metric_filter" "telemetry_sidecar_errors" {
  count = local.telemetry_alarms_enabled ? 1 : 0

  name           = "${var.name}-telemetry-sidecar-errors"
  log_group_name = var.telemetry_sidecar_log_group_name
  pattern        = "{ ($.level = \"error\") || ($.level = \"fatal\") || ($.level = \"dpanic\") || ($.level = \"panic\") }"

  metric_transformation {
    name          = "TelemetrySidecarErrors"
    namespace     = var.custom_metric_namespace
    value         = "1"
    default_value = "0"
    unit          = "Count"
  }
}

# Advertencia y no critico: un error aislado del exportador ya no significa
# perdida desde que hay `retry_on_failure` -significa un reintento-. Lo que hace
# sonar esto es que el error sea sostenido, que es cuando la cola en disco esta
# creciendo hacia su limite. Es el mismo criterio que las reglas
# VetSoftwareOtelTraceExportFailing del stack de contenedores.
resource "aws_cloudwatch_metric_alarm" "telemetry_sidecar_errors" {
  count = local.telemetry_alarms_enabled ? 1 : 0

  alarm_name          = "${var.name}-telemetry-sidecar-errors"
  alarm_description   = "ADVERTENCIA · El sidecar colector lleva ${var.telemetry_sidecar_error_threshold} o mas errores en diez minutos. Sigue vivo y reintentando, pero la cola en disco esta creciendo: revise ${var.telemetry_sidecar_log_group_name}."
  namespace           = var.custom_metric_namespace
  metric_name         = "TelemetrySidecarErrors"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  threshold           = var.telemetry_sidecar_error_threshold
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions

  tags = merge(var.tags, { Severity = "warning" })
}
