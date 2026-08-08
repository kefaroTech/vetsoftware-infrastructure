mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
      arn        = "arn:aws:iam::123456789012:user/terraform-test"
      user_id    = "AIDATEST"
    }
  }

  mock_data "aws_partition" {
    defaults = {
      partition = "aws"
    }
  }

  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
}

# El ARN de un topic solo existe despues del apply, y el contrato que se quiere
# verificar -que cada alarma publique en el topic de su severidad- se resuelve en
# plan. Fijar los ARN durante el plan permite afirmar sobre el ruteo sin crear
# nada en AWS.
override_resource {
  target          = aws_sns_topic.alarms[0]
  override_during = plan

  values = {
    arn = "arn:aws:sns:us-east-1:123456789012:vetsoftware-dev-alarms"
  }
}

override_resource {
  target          = aws_sns_topic.alarms_critical[0]
  override_during = plan

  values = {
    arn = "arn:aws:sns:us-east-1:123456789012:vetsoftware-dev-alarms-critical"
  }
}

override_resource {
  target          = aws_sns_topic.events[0]
  override_during = plan

  values = {
    arn = "arn:aws:sns:us-east-1:123456789012:vetsoftware-dev-events"
  }
}

override_resource {
  target          = aws_sns_topic.finops[0]
  override_during = plan

  values = {
    arn = "arn:aws:sns:us-east-1:123456789012:vetsoftware-dev-finops"
  }
}

variables {
  name                             = "vetsoftware-dev"
  aws_region                       = "us-east-1"
  alarm_email                      = "sre@example.test"
  slack_workspace_id               = "T0123456789"
  slack_channel_id                 = "C0123456789"
  slack_alerts_channel_id          = "C0ALERTS000"
  slack_infra_channel_id           = "C0INFRA0000"
  ecs_cluster_name                 = "vetsoftware-dev-backend"
  ecs_cluster_arn                  = "arn:aws:ecs:us-east-1:123456789012:cluster/vetsoftware-dev-backend"
  ecs_service_name                 = "backend"
  ecs_service_arn                  = "arn:aws:ecs:us-east-1:123456789012:service/vetsoftware-dev-backend/backend"
  ecs_events_enabled               = true
  cloudflare_tunnel_log_group_name = "/ecs/vetsoftware-dev-backend/cloudflare-tunnel"
  database_identifier              = "vetsoftware-dev-mysql"
  database_arn                     = "arn:aws:rds:us-east-1:123456789012:db:vetsoftware-dev-mysql"
  database_events_enabled          = true
  cache_alarms_enabled             = true
  cache_name                       = "vetsoftware-dev-valkey"
  cache_maximum_data_storage_gb    = 1
  cache_maximum_ecpu_per_second    = 1000
  alloy_instance_ids               = []
}

// La autorizacion de publicacion de los topics se verifica en
// sns_publish_authorization.tftest.hcl: mock_provider sustituye el JSON de
// aws_iam_policy_document por un documento vacio, asi que aqui no hay politica
// real sobre la que afirmar.

run "severity_routing_is_separated" {
  command = plan

  assert {
    condition     = aws_sns_topic.alarms_critical[0].name == "vetsoftware-dev-alarms-critical"
    error_message = "Lo critico debe tener su propio topic para poder enrutarse aparte cuando exista guardia."
  }

  # Con canales separados debe haber una configuracion por canal, nunca dos
  # apuntando al mismo: Amazon Q asocia la configuracion al canal y se pisarian.
  assert {
    condition = (
      length(aws_chatbot_slack_channel_configuration.channels) == 3 &&
      length(distinct([for c in aws_chatbot_slack_channel_configuration.channels : c.slack_channel_id])) == 3
    )
    error_message = "Debe crearse exactamente una configuracion de Amazon Q por canal distinto."
  }

  # El reparto por tipo de senal es el contrato: alarmas a un canal, eventos a
  # otro, costos al tercero. Si un topic se cuela en el canal equivocado, la
  # familia mas frecuente entierra a la mas importante.
  assert {
    condition = alltrue([
      length(aws_chatbot_slack_channel_configuration.channels["C0ALERTS000"].sns_topic_arns) == 2,
      contains(aws_chatbot_slack_channel_configuration.channels["C0ALERTS000"].sns_topic_arns, aws_sns_topic.alarms[0].arn),
      contains(aws_chatbot_slack_channel_configuration.channels["C0ALERTS000"].sns_topic_arns, aws_sns_topic.alarms_critical[0].arn),
      aws_chatbot_slack_channel_configuration.channels["C0INFRA0000"].sns_topic_arns == toset([aws_sns_topic.events[0].arn]),
      aws_chatbot_slack_channel_configuration.channels["C0123456789"].sns_topic_arns == toset([aws_sns_topic.finops[0].arn]),
    ])
    error_message = "Cada canal debe recibir solo los topics de su familia: alarmas, eventos y costos por separado."
  }

  assert {
    condition = (
      aws_cloudwatch_metric_alarm.backend_memory_critical.alarm_actions == toset([aws_sns_topic.alarms_critical[0].arn]) &&
      aws_cloudwatch_metric_alarm.backend_memory.alarm_actions == toset([aws_sns_topic.alarms[0].arn])
    )
    error_message = "Cada alarma debe publicar en el topic de su severidad; mezclarlos anula el ruteo."
  }
}

# Regresion concreta: la alarma de memoria de RDS trataba la ausencia de datos
# como falla. El apagado programado detiene la instancia cada noche entre
# semana, asi que esa configuracion disparaba una alerta diaria a las 20:15 y
# entrenaba al equipo a ignorar el canal.
run "scheduled_shutdown_does_not_page" {
  command = plan

  assert {
    condition = alltrue([
      aws_cloudwatch_metric_alarm.database_memory.treat_missing_data == "notBreaching",
      aws_cloudwatch_metric_alarm.database_memory_critical.treat_missing_data == "notBreaching",
      aws_cloudwatch_metric_alarm.database_cpu.treat_missing_data == "notBreaching",
      aws_cloudwatch_metric_alarm.database_storage_critical.treat_missing_data == "notBreaching",
      aws_cloudwatch_metric_alarm.database_connections_critical.treat_missing_data == "notBreaching",
      aws_cloudwatch_metric_alarm.backend_memory_critical.treat_missing_data == "notBreaching",
    ])
    error_message = "Ninguna alarma puede tratar la falta de datos como falla: el entorno se apaga cada noche a proposito."
  }
}

run "thresholds_match_the_failure_they_predict" {
  command = plan

  # Un OOM no avisa diez minutos antes. Promediar cinco minutos suaviza justo el
  # pico que mata al contenedor, asi que la alarma critica de memoria mide
  # maximos por minuto.
  assert {
    condition = (
      aws_cloudwatch_metric_alarm.backend_memory_critical.statistic == "Maximum" &&
      aws_cloudwatch_metric_alarm.backend_memory_critical.period == 60 &&
      aws_cloudwatch_metric_alarm.backend_memory_critical.datapoints_to_alarm == 3
    )
    error_message = "La alarma critica de memoria debe medir maximos por minuto: el promedio de cinco minutos esconde el pico que causa el OOM."
  }

  assert {
    condition = (
      aws_cloudwatch_metric_alarm.database_connections.threshold == 42 &&
      aws_cloudwatch_metric_alarm.database_connections_critical.threshold == 54
    )
    error_message = "Los umbrales de conexiones deben salir de max_connections, no escribirse a mano."
  }

  assert {
    condition = (
      aws_cloudwatch_metric_alarm.backend_crash_loop[0].threshold == 3 &&
      aws_cloudwatch_metric_alarm.backend_crash_loop[0].period == 900
    )
    error_message = "El crash loop debe declararse con 3 paradas inesperadas en 15 minutos."
  }

  # El filtro es el unico punto donde se separa una parada pedida de una falla.
  # Si deja de excluir ServiceSchedulerInitiated, cada despliegue y cada apagado
  # nocturno cuentan como crash.
  assert {
    condition = alltrue([
      strcontains(aws_cloudwatch_log_metric_filter.unexpected_task_stops[0].pattern, "UserInitiated"),
      strcontains(aws_cloudwatch_log_metric_filter.unexpected_task_stops[0].pattern, "ServiceSchedulerInitiated"),
      strcontains(aws_cloudwatch_log_metric_filter.unexpected_task_stops[0].pattern, "SpotInterruption"),
    ])
    error_message = "El filtro de paradas inesperadas debe excluir las paradas pedidas y las recuperaciones de Spot."
  }
}

run "composite_alarms_correlate_instead_of_repeating" {
  command = plan

  # El valor de la compuesta esta en el AND. Un OR seria solo un duplicado de
  # avisos que las hijas ya mandan por su cuenta.
  assert {
    condition = (
      strcontains(aws_cloudwatch_composite_alarm.database_saturated[0].alarm_rule, "AND") &&
      aws_cloudwatch_composite_alarm.database_saturated[0].alarm_actions == toset([aws_sns_topic.alarms_critical[0].arn])
    )
    error_message = "La compuesta de saturacion debe correlacionar señales con AND y escalar al topic critico."
  }

  assert {
    condition     = strcontains(aws_cloudwatch_composite_alarm.backend_degraded[0].alarm_rule, "AND")
    error_message = "La compuesta del backend debe exigir CPU y memoria altas a la vez, no cualquiera de las dos."
  }
}

run "event_rules_are_scoped_to_this_environment" {
  command = plan

  # Los eventos de despliegue no llevan clusterArn dentro de detail: el unico
  # identificador esta en resources. Filtrar por cluster ahi no coincide nunca y
  # la alerta jamas llega.
  assert {
    condition     = strcontains(aws_cloudwatch_event_rule.ecs_deployment_failed[0].event_pattern, "arn:aws:ecs:us-east-1:123456789012:service/vetsoftware-dev-backend/backend")
    error_message = "La regla de despliegue debe filtrar por el ARN del servicio en resources."
  }

  assert {
    condition = (
      strcontains(aws_cloudwatch_event_rule.ecs_task_failed[0].event_pattern, "EssentialContainerExited") &&
      strcontains(aws_cloudwatch_event_rule.ecs_task_failed[0].event_pattern, "TaskFailedToStart")
    )
    error_message = "La notificacion de tarea detenida debe cubrir contenedor esencial caido y arranque fallido."
  }

  # RDS-EVENT-0221 es la base apagada por disco lleno y 0419 la instancia
  # inaccesible por KMS: ninguna de las dos se ve venir en una metrica.
  assert {
    condition = (
      strcontains(aws_cloudwatch_event_rule.database_critical[0].event_pattern, "RDS-EVENT-0221") &&
      strcontains(aws_cloudwatch_event_rule.database_critical[0].event_pattern, "RDS-EVENT-0419") &&
      strcontains(aws_cloudwatch_event_rule.database_critical[0].event_pattern, "arn:aws:rds:us-east-1:123456789012:db:vetsoftware-dev-mysql")
    )
    error_message = "Los eventos criticos de RDS deben incluir storage-full y clave KMS inaccesible, acotados a esta instancia."
  }

  # RDS-EVENT-0403 es el crash loop por memoria que la db.t4g.micro de dev sufre
  # a diario. El apagado y el reinicio que vienen despues son indistinguibles del
  # apagado programado; este evento no.
  assert {
    condition     = strcontains(aws_cloudwatch_event_rule.database_critical[0].event_pattern, "RDS-EVENT-0403")
    error_message = "El aviso de memoria criticamente baja de RDS debe ser critico: es el sintoma temprano del crash loop conocido de dev."
  }

  # El apagado y el reinicio de RDS son el apagado programado de cada noche.
  assert {
    condition = !anytrue([
      strcontains(aws_cloudwatch_event_rule.database_critical[0].event_pattern, "RDS-EVENT-0004"),
      strcontains(aws_cloudwatch_event_rule.database_warning[0].event_pattern, "RDS-EVENT-0004"),
      strcontains(aws_cloudwatch_event_rule.database_critical[0].event_pattern, "RDS-EVENT-0087"),
    ])
    error_message = "Ninguna regla puede notificar el apagado o el arranque de RDS: es el apagado programado de dev."
  }
}

run "notifications_render_in_slack_instead_of_dumping_json" {
  command = plan

  # Amazon Q Developer solo formatea el mensaje si trae version 1.0, source
  # custom y content.description. Sin ese envoltorio, Slack muestra el JSON
  # crudo del evento y nadie lo lee.
  assert {
    condition = alltrue([
      strcontains(aws_cloudwatch_event_target.ecs_task_failed_notification[0].input_transformer[0].input_template, "\"version\":\"1.0\""),
      strcontains(aws_cloudwatch_event_target.ecs_task_failed_notification[0].input_transformer[0].input_template, "\"source\":\"custom\""),
      strcontains(aws_cloudwatch_event_target.database_critical_notification[0].input_transformer[0].input_template, "\"description\""),
    ])
    error_message = "Las notificaciones de eventos deben usar el esquema de notificacion personalizada de Amazon Q Developer."
  }

  # Todo evento sale por el topic de eventos, sin importar su gravedad: un
  # evento cuenta lo que paso y va al canal de infra. Si uno se cuela en el
  # topic de alarmas, aterriza en el canal que debe estar reservado a lo que
  # exige accion.
  assert {
    condition = alltrue([
      aws_cloudwatch_event_target.database_warning_notification[0].arn == aws_sns_topic.events[0].arn,
      aws_cloudwatch_event_target.database_critical_notification[0].arn == aws_sns_topic.events[0].arn,
      aws_cloudwatch_event_target.ecs_task_failed_notification[0].arn == aws_sns_topic.events[0].arn,
      aws_cloudwatch_event_target.ecs_deployment_failed_notification[0].arn == aws_sns_topic.events[0].arn,
      aws_cloudwatch_event_target.ecs_service_impaired_notification[0].arn == aws_sns_topic.events[0].arn,
    ])
    error_message = "Los eventos de ECS y RDS deben publicarse en el topic de eventos, no en los de alarmas."
  }
}

run "cache_alarms_derive_from_the_configured_limits" {
  command = plan

  # ElastiCacheProcessingUnits se acumula por periodo y el limite del cache es
  # por segundo: 1.000 ECPU/s al 80% sobre 300 s son 240.000 por periodo.
  assert {
    condition = (
      aws_cloudwatch_metric_alarm.cache_ecpu[0].threshold == 240000 &&
      aws_cloudwatch_metric_alarm.cache_data_storage[0].threshold == 858993459
    )
    error_message = "Los umbrales del cache deben derivarse de sus limites, convirtiendo ECPU por segundo a ECPU por periodo."
  }

  # Serverless usa clusterId; CacheClusterId es la dimension de los clusters por
  # nodos y dejaria la alarma sin datos para siempre.
  assert {
    condition     = aws_cloudwatch_metric_alarm.cache_throttled[0].dimensions["clusterId"] == "vetsoftware-dev-valkey"
    error_message = "Las alarmas del cache serverless deben usar la dimension clusterId."
  }
}
