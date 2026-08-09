# Eventos de ECS.
#
# Dos problemas que las metricas no resuelven:
#
# 1. Contar fallos. "Que avise si el health check falla N veces" necesita una
#    serie temporal, y ECS no publica una. La solucion es archivar los eventos de
#    cambio de estado de tarea en un log group y derivar la metrica con un filtro:
#    a partir de ahi CloudWatch puede contar M de N como con cualquier otra.
#    El log group tambien queda como evidencia forense de cada parada, que es
#    justo lo que se pierde cuando la tarea muere y se lleva sus logs.
#
# 2. Causa raiz. MemoryUtilization al 95% dice que hubo presion; stoppedReason
#    dice "Task failed container health checks" o "OutOfMemoryError: container
#    killed due to memory usage". Lo segundo cierra el diagnostico, lo primero
#    solo lo abre.
#
# Las notificaciones se transforman al esquema de notificaciones personalizadas
# de Amazon Q Developer (version 1.0 / source custom / content.description), de
# modo que Slack recibe un mensaje redactado y no un volcado JSON. Eso evita un
# Lambda intermedio: el input transformer de EventBridge basta.

resource "aws_cloudwatch_log_group" "ecs_task_events" {
  count = local.ecs_events_enabled ? 1 : 0

  # El prefijo /aws/events/ no es cosmetico: es el que habilita el modelo de
  # permisos por resource policy que usa EventBridge para escribir en Logs.
  name              = "/aws/events/${var.name}/ecs-task-state"
  retention_in_days = var.event_log_retention_days
  kms_key_id        = trimspace(var.sns_kms_key_arn) != "" ? var.sns_kms_key_arn : null

  tags = var.tags
}

data "aws_iam_policy_document" "events_to_logs" {
  count = local.ecs_events_enabled ? 1 : 0

  statement {
    sid    = "EventBridgeToCloudWatchLogs"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com", "delivery.logs.amazonaws.com"]
    }

    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.ecs_task_events[0].arn}:*"]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_cloudwatch_log_resource_policy" "events_to_logs" {
  count = local.ecs_events_enabled ? 1 : 0

  policy_name     = "${var.name}-events-to-logs"
  policy_document = data.aws_iam_policy_document.events_to_logs[0].json
}

# La regla del archivo es deliberadamente amplia -toda parada de tarea del
# cluster- y la discriminacion vive en los filtros de metrica. Si manana ECS
# introduce un stopCode nuevo, el evento igual queda archivado en vez de
# perderse por un patron demasiado estrecho.
resource "aws_cloudwatch_event_rule" "ecs_task_stopped" {
  count = local.ecs_events_enabled ? 1 : 0

  name        = "${var.name}-ecs-task-stopped"
  description = "Archiva toda parada de tarea del cluster para contar fallos y conservar la causa."

  event_pattern = jsonencode({
    source        = ["aws.ecs"]
    "detail-type" = ["ECS Task State Change"]
    detail = {
      clusterArn = [var.ecs_cluster_arn]
      lastStatus = ["STOPPED"]
    }
  })

  tags = var.tags
}

resource "aws_cloudwatch_event_target" "ecs_task_stopped_archive" {
  count = local.ecs_events_enabled ? 1 : 0

  rule      = aws_cloudwatch_event_rule.ecs_task_stopped[0].name
  target_id = "archive-to-logs"
  arn       = aws_cloudwatch_log_group.ecs_task_events[0].arn
}

# UserInitiated y ServiceSchedulerInitiated son paradas pedidas: despliegues,
# escalado y el apagado nocturno programado. Contarlas convertiria cada noche en
# un crash loop. SpotInterruption se cuenta aparte porque en dev es rutina.
resource "aws_cloudwatch_log_metric_filter" "unexpected_task_stops" {
  count = local.ecs_events_enabled ? 1 : 0

  name           = "${var.name}-ecs-unexpected-task-stops"
  log_group_name = aws_cloudwatch_log_group.ecs_task_events[0].name
  pattern        = "{ ($.detail.stopCode != \"UserInitiated\") && ($.detail.stopCode != \"ServiceSchedulerInitiated\") && ($.detail.stopCode != \"SpotInterruption\") }"

  metric_transformation {
    name          = "UnexpectedTaskStops"
    namespace     = var.custom_metric_namespace
    value         = "1"
    default_value = "0"
    unit          = "Count"
  }
}

resource "aws_cloudwatch_log_metric_filter" "spot_interruptions" {
  count = local.ecs_events_enabled ? 1 : 0

  name           = "${var.name}-ecs-spot-interruptions"
  log_group_name = aws_cloudwatch_log_group.ecs_task_events[0].name
  pattern        = "{ $.detail.stopCode = \"SpotInterruption\" }"

  metric_transformation {
    name          = "SpotInterruptions"
    namespace     = var.custom_metric_namespace
    value         = "1"
    default_value = "0"
    unit          = "Count"
  }
}

# Regla de notificacion, mas estrecha que la de archivo: a Slack solo van las
# paradas que alguien tiene que mirar.
resource "aws_cloudwatch_event_rule" "ecs_task_failed" {
  count = local.ecs_events_enabled ? 1 : 0

  name        = "${var.name}-ecs-task-failed"
  description = "Parada de tarea por health check fallido, contenedor esencial caido o arranque fallido."

  event_pattern = jsonencode({
    source        = ["aws.ecs"]
    "detail-type" = ["ECS Task State Change"]
    detail = {
      clusterArn = [var.ecs_cluster_arn]
      lastStatus = ["STOPPED"]
      stopCode   = ["EssentialContainerExited", "TaskFailedToStart"]
    }
  })

  tags = var.tags
}

resource "aws_cloudwatch_event_target" "ecs_task_failed_notification" {
  count = local.ecs_events_enabled ? 1 : 0

  rule      = aws_cloudwatch_event_rule.ecs_task_failed[0].name
  target_id = "notify-events"
  arn       = aws_sns_topic.events[0].arn

  input_transformer {
    input_paths = {
      stopCode  = "$.detail.stopCode"
      reason    = "$.detail.stoppedReason"
      taskArn   = "$.detail.taskArn"
      stoppedAt = "$.detail.stoppedAt"
    }

    input_template = replace(replace(jsonencode({
      version = "1.0"
      source  = "custom"
      content = {
        textType    = "client-markdown"
        title       = ":rotating_light: ${var.name} · tarea ECS detenida"
        description = "El servicio `${var.ecs_service_name}` del cluster `${var.ecs_cluster_name}` perdio una tarea.\n*Motivo:* <reason>\n*Codigo:* `<stopCode>`\n*Tarea:* `<taskArn>`\n*Hora:* <stoppedAt>"
        nextSteps = [
          "Revisar los ultimos 15 minutos de `${local.backend_log_group_hint}` en CloudWatch Logs",
          "Si el motivo menciona health check, comparar el tiempo de arranque real contra startPeriod (180 s) antes de tocar el codigo",
          "Si menciona OutOfMemory, contrastar con la alarma ${var.name}-backend-memory-exhausted",
          local.runbook_step,
        ]
        keywords = ["ECS", "critico", var.name]
      }
      metadata = {
        threadId = "${var.name}-ecs-task-stop"
        summary  = "Tarea ECS detenida"
      }
    }), "\\u003c", "<"), "\\u003e", ">")
  }
}

# El circuit breaker del servicio ya reintenta y revierte solo. Que llegue a
# fallar significa que el despliegue no logro estabilizar ni una sola tarea sana.
resource "aws_cloudwatch_event_rule" "ecs_deployment_failed" {
  count = local.ecs_events_enabled ? 1 : 0

  name        = "${var.name}-ecs-deployment-failed"
  description = "Despliegue ECS revertido por el circuit breaker o sin alcanzar estado estable."

  # Los eventos de despliegue no llevan clusterArn dentro de detail: el unico
  # identificador del servicio esta en el array resources de nivel superior.
  event_pattern = jsonencode({
    source        = ["aws.ecs"]
    "detail-type" = ["ECS Deployment State Change"]
    resources     = [var.ecs_service_arn]
    detail = {
      eventName = ["SERVICE_DEPLOYMENT_FAILED"]
    }
  })

  tags = var.tags
}

resource "aws_cloudwatch_event_target" "ecs_deployment_failed_notification" {
  count = local.ecs_events_enabled ? 1 : 0

  rule      = aws_cloudwatch_event_rule.ecs_deployment_failed[0].name
  target_id = "notify-events"
  arn       = aws_sns_topic.events[0].arn

  input_transformer {
    input_paths = {
      reason       = "$.detail.reason"
      deploymentId = "$.detail.deploymentId"
      time         = "$.time"
    }

    input_template = replace(replace(jsonencode({
      version = "1.0"
      source  = "custom"
      content = {
        textType    = "client-markdown"
        title       = ":no_entry: ${var.name} · despliegue ECS fallido"
        description = "El circuit breaker detuvo el despliegue de `${var.ecs_service_name}` y revirtio a la revision anterior.\n*Motivo:* <reason>\n*Despliegue:* `<deploymentId>`\n*Hora:* <time>"
        nextSteps = [
          "La version anterior sigue sirviendo: no hay que revertir a mano",
          "Revisar `${local.backend_log_group_hint}` filtrando por el arranque de la revision nueva",
          local.runbook_step,
        ]
        keywords = ["ECS", "despliegue", "critico", var.name]
      }
      metadata = {
        threadId = "${var.name}-ecs-deployment"
        summary  = "Despliegue ECS fallido"
      }
    }), "\\u003c", "<"), "\\u003e", ">")
  }
}

# SERVICE_TASK_PLACEMENT_FAILURE con capacidad Fargate Spot significa que AWS no
# tiene capacidad Spot que entregar. Es la falla mas probable de dev y no se
# arregla con codigo: se arregla dandole peso a Fargate on-demand.
resource "aws_cloudwatch_event_rule" "ecs_service_impaired" {
  count = local.ecs_events_enabled ? 1 : 0

  name        = "${var.name}-ecs-service-impaired"
  description = "El scheduler de ECS no logra colocar o arrancar tareas del servicio."

  event_pattern = jsonencode({
    source        = ["aws.ecs"]
    "detail-type" = ["ECS Service Action"]
    detail = {
      clusterArn = [var.ecs_cluster_arn]
      eventName = [
        "SERVICE_TASK_PLACEMENT_FAILURE",
        "SERVICE_TASK_START_IMPAIRED",
        "SERVICE_TASK_CONFIGURATION_FAILURE",
        "ECS_OPERATION_THROTTLED",
      ]
    }
  })

  tags = var.tags
}

resource "aws_cloudwatch_event_target" "ecs_service_impaired_notification" {
  count = local.ecs_events_enabled ? 1 : 0

  rule      = aws_cloudwatch_event_rule.ecs_service_impaired[0].name
  target_id = "notify-events"
  arn       = aws_sns_topic.events[0].arn

  input_transformer {
    input_paths = {
      eventName = "$.detail.eventName"
      reason    = "$.detail.reason"
      time      = "$.time"
    }

    input_template = replace(replace(jsonencode({
      version = "1.0"
      source  = "custom"
      content = {
        textType    = "client-markdown"
        title       = ":warning: ${var.name} · el scheduler de ECS no puede levantar el servicio"
        description = "*Evento:* `<eventName>`\n*Causa:* <reason>\n*Servicio:* `${var.ecs_service_name}`\n*Hora:* <time>"
        nextSteps = [
          "Si la causa es RESOURCE:FARGATE, AWS no tiene capacidad Spot disponible: darle peso temporal a Fargate on-demand",
          "Si es un fallo de configuracion, revisar el task role, los secretos referenciados y la subred",
          local.runbook_step,
        ]
        keywords = ["ECS", "capacidad", "critico", var.name]
      }
      metadata = {
        threadId = "${var.name}-ecs-service-action"
        summary  = "Scheduler ECS degradado"
      }
    }), "\\u003c", "<"), "\\u003e", ">")
  }
}
