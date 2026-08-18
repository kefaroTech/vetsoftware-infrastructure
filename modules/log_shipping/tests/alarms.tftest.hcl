# Contrato de las alarmas del envio de logs.
#
# Las tres propiedades que se afirman aqui son las que se rompieron una vez y no
# se notan mirando la consola: el hueco de metrica tratado como OK, el aviso de
# recuperacion en un canal humano y la severidad escrita dentro de un texto que
# viaja igual en los dos sentidos. Ninguna se ve en un plan leido por encima.

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
      arn        = "arn:aws:iam::123456789012:user/terraform-test"
      user_id    = "AIDATEST"
    }
  }

  mock_data "aws_region" {
    defaults = {
      region = "us-east-1"
    }
  }

  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
}

variables {
  name                  = "vetsoftware-dev"
  source_log_group_name = "/ecs/vetsoftware-dev-backend/backend"
  source_log_group_arn  = "arn:aws:logs:us-east-1:123456789012:log-group:/ecs/vetsoftware-dev-backend/backend"
  endpoint_url          = "https://aws-logs-prod-042.grafana.net/aws-logs/api/v1/push"
  access_key_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:vetsoftware-dev/grafana-cloud-logs-AbCdEf"
  kms_key_arn           = "arn:aws:kms:us-east-1:123456789012:key/11111111-2222-3333-4444-555555555555"

  loki_labels = {
    service_name                = "vetsoftware"
    service_namespace           = "mainvet"
    deployment_environment_name = "dev"
    telemetry_source            = "firehose"
  }

  alarm_topic_arn          = "arn:aws:sns:us-east-1:123456789012:vetsoftware-dev-alarms"
  critical_alarm_topic_arn = "arn:aws:sns:us-east-1:123456789012:vetsoftware-dev-alarms-critical"

  tags = {
    Environment = "dev"
    ManagedBy   = "terraform"
  }
}

# Es la razon de ser del recurso: un stream muerto no publica metrica, y con
# notBreaching esa ausencia se leeria como salud. Sobre volumen y con el hueco
# tratado como falla, el silencio es la senal.
run "el_silencio_de_firehose_se_lee_como_falla" {
  command = plan

  assert {
    condition = (
      aws_cloudwatch_metric_alarm.no_delivery.metric_name == "DeliveryToHttpEndpoint.Records" &&
      aws_cloudwatch_metric_alarm.no_delivery.statistic == "Sum" &&
      aws_cloudwatch_metric_alarm.no_delivery.comparison_operator == "LessThanThreshold" &&
      aws_cloudwatch_metric_alarm.no_delivery.threshold == 1 &&
      aws_cloudwatch_metric_alarm.no_delivery.treat_missing_data == "breaching"
    )
    error_message = "La alarma de volumen debe medir Records con Sum y tratar la ausencia de datos como falla; con notBreaching o con una metrica de proporcion vuelve el punto ciego."
  }

  assert {
    condition     = !aws_cloudwatch_metric_alarm.no_delivery.actions_enabled
    error_message = "La alarma de volumen no puede notificar por su cuenta: sonaria cada noche durante el apagado programado."
  }
}

# La senal de entorno vivo. Se mide sobre el log group de origen y no sobre ECS
# porque Container Insights esta desactivado en dev y RunningTaskCount no existe
# en el namespace AWS/ECS.
run "la_senal_de_entorno_vivo_cierra_antes_de_que_abra_la_de_volumen" {
  command = plan

  assert {
    condition = (
      aws_cloudwatch_metric_alarm.source_active.namespace == "AWS/Logs" &&
      aws_cloudwatch_metric_alarm.source_active.metric_name == "IncomingLogEvents" &&
      aws_cloudwatch_metric_alarm.source_active.comparison_operator == "GreaterThanOrEqualToThreshold" &&
      aws_cloudwatch_metric_alarm.source_active.dimensions["LogGroupName"] == var.source_log_group_name
    )
    error_message = "La senal de entorno vivo debe leer IncomingLogEvents del log group de origen."
  }

  assert {
    condition     = !aws_cloudwatch_metric_alarm.source_active.actions_enabled
    error_message = "La senal de entorno vivo esta invertida -en ALARM significa sano- y no puede notificar."
  }

  # El invariante de tiempos. Si la senal de actividad tardara mas en volver a OK
  # que la de volumen en entrar en ALARM, las 20:00 de cada dia laboral
  # producirian un aviso.
  assert {
    condition = (
      output.shipping.dead_mans_switch.liveness_evaluation_range <
      output.shipping.dead_mans_switch.volume_evaluation_range
    )
    error_message = "La ventana de la senal de actividad debe ser mas corta que la de volumen: si no, la compuesta grita durante el apagado nocturno."
  }
}

run "la_compuesta_exige_las_dos_senales" {
  command = plan

  assert {
    condition = (
      strcontains(aws_cloudwatch_composite_alarm.not_shipping.alarm_rule, aws_cloudwatch_metric_alarm.no_delivery.alarm_name) &&
      strcontains(aws_cloudwatch_composite_alarm.not_shipping.alarm_rule, aws_cloudwatch_metric_alarm.source_active.alarm_name) &&
      strcontains(aws_cloudwatch_composite_alarm.not_shipping.alarm_rule, " AND ")
    )
    error_message = "La compuesta debe combinar las dos senales con AND: sin la de actividad avisa durante el apagado, sin la de volumen no avisa nunca."
  }

  assert {
    condition = (
      aws_cloudwatch_composite_alarm.not_shipping.actions_enabled &&
      contains(aws_cloudwatch_composite_alarm.not_shipping.alarm_actions, var.critical_alarm_topic_arn)
    )
    error_message = "La compuesta es la unica pieza del interruptor que notifica, y lo hace al topic critico."
  }
}

# Un canal que lee una persona no tiene estado de incidente que cerrar. Es el
# mismo criterio que el send_resolved = false por defecto de Alertmanager para
# Slack y correo.
run "ninguna_alarma_notifica_la_recuperacion" {
  command = plan

  assert {
    condition     = output.shipping.ok_actions_configured == 0
    error_message = "Ninguna alarma del modulo puede tener ok_actions mientras el destino sea un canal humano."
  }
}

# AlarmDescription no admite plantillas: el mismo texto viaja en el disparo y en
# la recuperacion. Escribir la severidad dentro produce el aviso verde que dice
# CRITICO.
run "las_descripciones_son_neutras_respecto_al_estado" {
  command = plan

  assert {
    condition = alltrue([
      for description in output.shipping.alarm_descriptions : (
        !strcontains(upper(description), "CRITICO") &&
        !strcontains(upper(description), "ADVERTENCIA") &&
        !strcontains(upper(description), "WARNING")
      )
    ])
    error_message = "Las descripciones no pueden afirmar severidad: el texto viaja identico en el disparo y en la recuperacion. La severidad va en tags.Severity y en la eleccion de topic."
  }

  assert {
    condition = alltrue([
      for description in [
        aws_cloudwatch_metric_alarm.delivery_failing.alarm_description,
        aws_cloudwatch_metric_alarm.records_in_error_prefix.alarm_description,
        aws_cloudwatch_metric_alarm.delivery_stalled.alarm_description,
        aws_cloudwatch_composite_alarm.not_shipping.alarm_description,
      ] : strcontains(description, "Donde mirar")
    ])
    error_message = "Cada alarma que notifica debe decir donde mirar: quien la recibe no deberia tener que interpretar el dominio de alertas."
  }
}

run "el_inventario_de_alarmas_incluye_las_senales_internas" {
  command = plan

  assert {
    condition = (
      length(output.alarm_names) == 6 &&
      contains(output.alarm_names, "vetsoftware-dev-logs-delivery-failing") &&
      contains(output.alarm_names, "vetsoftware-dev-logs-in-error-bucket") &&
      contains(output.alarm_names, "vetsoftware-dev-logs-delivery-stalled") &&
      contains(output.alarm_names, "vetsoftware-dev-logs-no-delivery") &&
      contains(output.alarm_names, "vetsoftware-dev-logs-source-active") &&
      contains(output.alarm_names, "vetsoftware-dev-logs-not-shipping")
    )
    error_message = "alarm_names debe listar las seis: silenciar solo la compuesta deja a sus hijas cambiando de estado por debajo."
  }

  assert {
    condition = (
      output.composite_alarm_names == ["vetsoftware-dev-logs-not-shipping"] &&
      output.shipping.alarm_names == output.alarm_names
    )
    error_message = "El inventario del output shipping y el de alarm_names deben ser el mismo."
  }
}

run "las_alarmas_que_notifican_van_al_topic_de_su_severidad" {
  command = plan

  assert {
    condition = (
      contains(aws_cloudwatch_metric_alarm.delivery_failing.alarm_actions, var.critical_alarm_topic_arn) &&
      contains(aws_cloudwatch_metric_alarm.records_in_error_prefix.alarm_actions, var.critical_alarm_topic_arn) &&
      contains(aws_cloudwatch_metric_alarm.delivery_stalled.alarm_actions, var.alarm_topic_arn)
    )
    error_message = "Cada alarma publica en el topic de su severidad; la de retraso es advertencia y no debe ir al critico."
  }
}
