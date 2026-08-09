# Eventos de RDS.
#
# Hay fallas de base de datos que ninguna metrica anuncia. RDS-EVENT-0221 -"la
# instancia alcanzo el umbral de storage-full y la base fue apagada"- llega como
# evento, no como serie temporal; para cuando FreeStorageSpace muestre el
# desplome, la base ya lleva minutos abajo. Lo mismo con la clave KMS
# inaccesible, los parametros incompatibles y el fallo al reiniciar el motor.
#
# Se enrutan por EventBridge y no con aws_db_event_subscription porque asi el
# input transformer puede convertirlos al formato de notificacion personalizada
# de Amazon Q Developer. Una suscripcion directa publicaria el JSON crudo de RDS,
# que Slack muestra sin formato ni pasos siguientes.
#
# La lista de EventIDs es explicita a proposito. Suscribirse a la categoria
# completa "availability" traeria tambien RDS-EVENT-0004 y 0006 -apagado y
# reinicio-, que en dev son el apagado programado de cada noche.
#
# El replace() sobre jsonencode no es cosmetico. jsonencode convierte los signos
# de menor y mayor a su forma unicode escapada -lo hereda de encoding/json de
# Go- y EventBridge busca el marcador en el TEXTO de la plantilla, no en el JSON
# ya parseado. Escapado no lo encuentra, no sustituye nada, y el mensaje llega con
# los marcadores crudos. Paso el 9 de agosto de 2026 con RDS-EVENT-0403: la
# alerta llego diciendo "Evento: <eventId>" y hubo que ir al CLI a averiguar
# cual habia sido.

resource "aws_cloudwatch_event_rule" "database_critical" {
  count = local.database_events_enabled ? 1 : 0

  name        = "${var.name}-database-critical-events"
  description = "Eventos de RDS que dejan la base fuera de servicio o a punto de estarlo."

  event_pattern = jsonencode({
    source        = ["aws.rds"]
    "detail-type" = ["RDS DB Instance Event"]
    resources     = [var.database_arn]
    detail = {
      EventID = var.database_critical_event_ids
    }
  })

  tags = var.tags
}

resource "aws_cloudwatch_event_target" "database_critical_notification" {
  count = local.database_events_enabled ? 1 : 0

  rule      = aws_cloudwatch_event_rule.database_critical[0].name
  target_id = "notify-events"
  arn       = aws_sns_topic.events[0].arn

  input_transformer {
    input_paths = {
      eventId = "$.detail.EventID"
      message = "$.detail.Message"
      time    = "$.time"
    }

    input_template = replace(replace(jsonencode({
      version = "1.0"
      source  = "custom"
      content = {
        textType    = "client-markdown"
        title       = ":rotating_light: ${var.name} · evento critico de RDS"
        description = "*Instancia:* `${var.database_identifier}`\n*Evento:* `<eventId>`\n*Mensaje:* <message>\n*Hora:* <time>"
        nextSteps = [
          "Si el evento es de almacenamiento, ampliar allocated_storage: en dev el autoescalado esta apagado a proposito",
          "Si la instancia quedo en estado incompatible, RDS recomienda restaurar a un punto en el tiempo antes de tocar nada",
          "Confirmar el estado real con la consola de RDS antes de reiniciar: un reinicio a ciegas puede perder el diagnostico",
          local.runbook_step,
        ]
        keywords = ["RDS", "critico", var.name]
      }
      metadata = {
        threadId = "${var.name}-rds-events"
        summary  = "Evento critico de RDS"
      }
    }), "\\u003c", "<"), "\\u003e", ">")
  }
}

resource "aws_cloudwatch_event_rule" "database_warning" {
  count = local.database_events_enabled ? 1 : 0

  name        = "${var.name}-database-warning-events"
  description = "Eventos de RDS que conviene conocer sin interrumpir a nadie."

  event_pattern = jsonencode({
    source        = ["aws.rds"]
    "detail-type" = ["RDS DB Instance Event"]
    resources     = [var.database_arn]
    detail = {
      EventID = var.database_warning_event_ids
    }
  })

  tags = var.tags
}

resource "aws_cloudwatch_event_target" "database_warning_notification" {
  count = local.database_events_enabled ? 1 : 0

  rule      = aws_cloudwatch_event_rule.database_warning[0].name
  target_id = "notify-events"
  arn       = aws_sns_topic.events[0].arn

  input_transformer {
    input_paths = {
      eventId = "$.detail.EventID"
      message = "$.detail.Message"
      time    = "$.time"
    }

    input_template = replace(replace(jsonencode({
      version = "1.0"
      source  = "custom"
      content = {
        textType    = "client-markdown"
        title       = ":large_yellow_circle: ${var.name} · evento de RDS"
        description = "*Instancia:* `${var.database_identifier}`\n*Evento:* `<eventId>`\n*Mensaje:* <message>\n*Hora:* <time>"
        keywords    = ["RDS", "advertencia", var.name]
      }
      metadata = {
        threadId = "${var.name}-rds-events"
        summary  = "Evento de RDS"
      }
    }), "\\u003c", "<"), "\\u003e", ">")
  }
}
