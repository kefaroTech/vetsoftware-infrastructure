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

  # Las mismas dos ventanas que cablea environments/dev. Sin ellas la regla de
  # silencio no se crea y las afirmaciones de higiene no verificarian nada.
  maintenance_mute_windows = {
    nightly = {
      expression = "cron(55 19 ? * * *)"
      duration   = "PT12H10M"
    }
    weekend = {
      expression = "cron(0 8 ? * SAT,SUN *)"
      duration   = "PT12H"
    }
  }

  # Las tres alarmas de log_shipping, que vigilan el mismo entorno que se apaga.
  additional_muted_alarm_names = [
    "vetsoftware-dev-logs-delivery-failing",
    "vetsoftware-dev-logs-in-error-bucket",
    "vetsoftware-dev-logs-delivery-stalled",
  ]
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
#
# El silencio de esa ventana ya NO se compra con treat_missing_data: lo compra
# una mute rule. Lo que este run sigue impidiendo es que alguien mueva a
# "breaching" una alarma de metrica continua sin resolver antes el problema de
# fondo, que es que dev tambien pasa horas habiles apagado -el arranque es
# manual- y ninguna ventana programada puede preverlo.
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
    error_message = "Ninguna alarma de metrica continua puede tratar la falta de datos como falla mientras dev pueda estar apagado fuera de una ventana silenciada."
  }

  # La de creditos de CPU es la excepcion deliberada. Parar la instancia borra el
  # saldo, asi que con notBreaching el apagado nocturno producia el efecto
  # contrario al de arriba: un OK falso en Slack -bastaba un datapoint faltante
  # de los 3 que exige datapoints_to_alarm- con el saldo real cerca de cero.
  assert {
    condition     = aws_cloudwatch_metric_alarm.database_cpu_credits.treat_missing_data == "ignore"
    error_message = "La alarma de creditos de CPU debe usar ignore: con notBreaching el apagado nocturno la resuelve en falso."
  }

  # Las metricas que solo existen cuando hay error no dependen de la variable:
  # es el criterio literal de AWS para ellas y no debe poder cambiarse desde el
  # root por accidente.
  assert {
    condition = alltrue([
      aws_cloudwatch_metric_alarm.cloudflare_tunnel_errors.treat_missing_data == "notBreaching",
      aws_cloudwatch_metric_alarm.backend_task_restarts[0].treat_missing_data == "notBreaching",
      aws_cloudwatch_metric_alarm.backend_crash_loop[0].treat_missing_data == "notBreaching",
      aws_cloudwatch_metric_alarm.backend_spot_interruptions[0].treat_missing_data == "notBreaching",
      aws_cloudwatch_metric_alarm.cache_throttled[0].treat_missing_data == "notBreaching",
      aws_cloudwatch_metric_alarm.cache_authentication_failures[0].treat_missing_data == "notBreaching",
    ])
    error_message = "Las metricas que por diseno solo existen cuando hay error deben quedar fijas en notBreaching."
  }
}

# Higiene de alertas. Las tres reglas de esta seccion son las que se degradan
# solas: se copia un recurso existente y con el viajan el ok_actions y el
# prefijo de severidad.
run "recovery_is_not_notified_and_severity_is_not_in_the_text" {
  command = plan

  # CloudWatch no tiene plantillas: AlarmDescription viaja identico en el disparo
  # y en la recuperacion. Un texto que empieza por "CRITICO ·" produce un ✅ que
  # dice CRITICO, que es lo que llego a Slack. La severidad viaja en el tag y en
  # la eleccion de topic, que es lo unico que enruta.
  assert {
    condition = !anytrue([
      for description in [
        aws_cloudwatch_metric_alarm.database_cpu.alarm_description,
        aws_cloudwatch_metric_alarm.database_cpu_critical.alarm_description,
        aws_cloudwatch_metric_alarm.database_memory_critical.alarm_description,
        aws_cloudwatch_metric_alarm.database_cpu_credits.alarm_description,
        aws_cloudwatch_metric_alarm.backend_memory_critical.alarm_description,
        aws_cloudwatch_metric_alarm.cloudflare_tunnel_errors.alarm_description,
        aws_cloudwatch_metric_alarm.backend_crash_loop[0].alarm_description,
        aws_cloudwatch_metric_alarm.cache_throttled[0].alarm_description,
        aws_cloudwatch_composite_alarm.database_saturated[0].alarm_description,
        aws_cloudwatch_composite_alarm.backend_degraded[0].alarm_description,
        ] : anytrue([
          strcontains(description, "CRITICO"),
          strcontains(description, "ADVERTENCIA"),
      ])
    ])
    error_message = "El texto de una alarma no puede llevar severidad: viaja identico en el OK y produce un ✅ que dice CRITICO."
  }

  # La severidad sigue existiendo, solo que donde si se puede leer por separado.
  assert {
    condition = (
      aws_cloudwatch_metric_alarm.database_cpu_critical.tags["Severity"] == "critical" &&
      aws_cloudwatch_metric_alarm.database_cpu.tags["Severity"] == "warning"
    )
    error_message = "La severidad debe seguir viajando en tags.Severity, que es lo que no se confunde con el estado."
  }

  # A los canales que lee una persona no se manda la recuperacion: es el default
  # de Alertmanager para Slack y correo, y en la taxonomia de Google la
  # recuperacion es Logging, no Alert. El OK sigue en el historial y en el panel.
  assert {
    condition = alltrue([
      try(length(aws_cloudwatch_metric_alarm.database_cpu.ok_actions), 0) == 0,
      try(length(aws_cloudwatch_metric_alarm.database_memory_critical.ok_actions), 0) == 0,
      try(length(aws_cloudwatch_metric_alarm.database_cpu_credits.ok_actions), 0) == 0,
      try(length(aws_cloudwatch_metric_alarm.backend_memory_critical.ok_actions), 0) == 0,
      try(length(aws_cloudwatch_metric_alarm.cloudflare_tunnel_errors.ok_actions), 0) == 0,
      try(length(aws_cloudwatch_metric_alarm.backend_crash_loop[0].ok_actions), 0) == 0,
      try(length(aws_cloudwatch_metric_alarm.cache_authentication_failures[0].ok_actions), 0) == 0,
      try(length(aws_cloudwatch_composite_alarm.database_saturated[0].ok_actions), 0) == 0,
      try(length(aws_cloudwatch_composite_alarm.backend_degraded[0].ok_actions), 0) == 0,
    ])
    error_message = "Ninguna alarma puede notificar su recuperacion a un canal que lee una persona."
  }

  assert {
    condition     = output.alerting.notify_on_recovery == false
    error_message = "El contrato debe declarar que la recuperacion no se notifica."
  }
}

# El silencio del apagado deja de ser un efecto colateral de treat_missing_data y
# pasa a ser una ventana explicita. Lo que hay que impedir es que la ventana se
# quede corta: una alarma nueva fuera de la regla vuelve a producir el ruido
# nocturno, y una alarma de log_shipping fuera de la regla lo produce desde un
# modulo que nadie mira al revisar este.
run "maintenance_window_silences_the_whole_environment" {
  command = plan

  assert {
    condition = (
      length(aws_cloudwatch_alarm_mute_rule.maintenance) == 2 &&
      aws_cloudwatch_alarm_mute_rule.maintenance["nightly"].name == "vetsoftware-dev-mute-nightly" &&
      aws_cloudwatch_alarm_mute_rule.maintenance["weekend"].name == "vetsoftware-dev-mute-weekend"
    )
    error_message = "Deben existir las dos ventanas: la nocturna y la del fin de semana, que la nocturna no cubre."
  }

  # Sin zona horaria la ventana se evalua en UTC y en Bogota silenciaria de 15:00
  # a 03:00: justo la jornada laboral y nada del apagado.
  assert {
    condition = alltrue([
      for rule in aws_cloudwatch_alarm_mute_rule.maintenance :
      rule.rule[0].schedule[0].timezone == "America/Bogota"
    ])
    error_message = "Las ventanas deben declarar America/Bogota; en UTC silencian la jornada laboral y no el apagado."
  }

  # La alarma de recuperacion de EC2 dispara arn:aws:automate:...:ec2:recover.
  # Silenciarla no callaria un mensaje: cancelaria la remediacion.
  assert {
    condition = alltrue([
      contains(tolist(aws_cloudwatch_alarm_mute_rule.maintenance["nightly"].mute_targets[0].alarm_names), "vetsoftware-dev-database-memory-exhausted"),
      contains(tolist(aws_cloudwatch_alarm_mute_rule.maintenance["nightly"].mute_targets[0].alarm_names), "vetsoftware-dev-backend-crash-loop"),
      contains(tolist(aws_cloudwatch_alarm_mute_rule.maintenance["nightly"].mute_targets[0].alarm_names), "vetsoftware-dev-database-saturated"),
      contains(tolist(aws_cloudwatch_alarm_mute_rule.maintenance["nightly"].mute_targets[0].alarm_names), "vetsoftware-dev-logs-delivery-failing"),
      !contains(tolist(aws_cloudwatch_alarm_mute_rule.maintenance["nightly"].mute_targets[0].alarm_names), "vetsoftware-dev-alloy-0-system-recovery"),
    ])
    error_message = "La ventana debe cubrir alarmas, compuestas y las de log_shipping, y dejar fuera la que dispara la recuperacion automatica de EC2."
  }

  # Limite duro del servicio. Pasarlo no se ve en plan, se ve en el apply.
  assert {
    condition     = output.alerting.maintenance_mute.muted_alarms <= 100
    error_message = "Una mute rule admite como maximo 100 alarmas; hay que partirla en varias reglas antes de llegar ahi."
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

  # Los eventos se reparten por SEVERIDAD, no por familia. Antes salian los cinco
  # por el topic de eventos, que aterriza en el canal de infra, y el resultado era
  # que un ":rotating_light: evento critico de RDS" llegaba al canal de menor
  # prioridad mientras una advertencia de reinicio de tarea -alarma, no evento-
  # llegaba al de alertas: la severidad quedaba invertida entre las dos familias.
  # Paso el 9 de agosto de 2026, cuando las dos notificaciones que llevaban la
  # causa raiz de un encendido fallido fueron a parar a infra.
  assert {
    condition = alltrue([
      aws_cloudwatch_event_target.database_critical_notification[0].arn == aws_sns_topic.alarms_critical[0].arn,
      aws_cloudwatch_event_target.ecs_task_failed_notification[0].arn == aws_sns_topic.alarms_critical[0].arn,
      aws_cloudwatch_event_target.ecs_service_impaired_notification[0].arn == aws_sns_topic.alarms_critical[0].arn,
    ])
    error_message = "RDS critico, tarea muerta y scheduler sin capacidad son incidentes: van al topic critico, no al de eventos."
  }

  # Lo informativo se queda en infra, o el canal de alertas se llena de ruido y
  # deja de leerse, que es el fallo que la separacion original venia a evitar. El
  # despliegue revertido entra aqui a proposito: el circuit breaker ya actuo y la
  # version anterior sigue sirviendo, asi que no hay nada caido que atender.
  assert {
    condition = alltrue([
      aws_cloudwatch_event_target.database_warning_notification[0].arn == aws_sns_topic.events[0].arn,
      aws_cloudwatch_event_target.ecs_deployment_failed_notification[0].arn == aws_sns_topic.events[0].arn,
    ])
    error_message = "La advertencia de RDS y el despliegue revertido son informativos: se quedan en el topic de eventos."
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

# El interruptor de hombre muerto del backend vive detras de Container Insights,
# que en dev y en prod esta apagado por costo. Es decir: hoy no se crea, y sin un
# run que lo encienda explicitamente nada verificaria que esta bien construido.
#
# Importa mas de lo normal porque su version anterior era una sola alarma sobre
# RunningTaskCount con treat_missing_data = "breaching", que habria sonado cada
# vez que alguien apaga dev a mano -algo deliberado y frecuente-. Estaba inerte y
# por eso no dolia; encender la bandera la habria convertido en ruido diario.
run "the_backend_dead_mans_switch_ignores_a_deliberate_shutdown" {
  command = plan

  variables {
    container_insights_enabled = true
  }

  # Ninguna de las dos senales notifica por su cuenta. Si alguien le devuelve las
  # acciones a la de tareas corriendo, cada apagado vuelve a sonar.
  assert {
    condition = (
      aws_cloudwatch_metric_alarm.backend_no_running_tasks[0].actions_enabled == false &&
      aws_cloudwatch_metric_alarm.backend_tasks_wanted[0].actions_enabled == false &&
      aws_cloudwatch_composite_alarm.backend_service_down[0].actions_enabled == true
    )
    error_message = "Solo la compuesta puede notificar: sus dos hijas por separado confundirian un apagado deliberado con una caida."
  }

  # La oposicion de los dos treat_missing_data ES el mecanismo. El hueco de
  # tareas corriendo significa "no hay backend"; el de tareas pedidas significa
  # "nadie las esta pidiendo", que es exactamente lo que pasa en un apagado.
  assert {
    condition = (
      aws_cloudwatch_metric_alarm.backend_no_running_tasks[0].treat_missing_data == "breaching" &&
      aws_cloudwatch_metric_alarm.backend_tasks_wanted[0].treat_missing_data == "notBreaching" &&
      aws_cloudwatch_metric_alarm.backend_tasks_wanted[0].metric_name == "DesiredTaskCount"
    )
    error_message = "El interruptor exige que el hueco de tareas corriendo sea falla y el de tareas pedidas sea calma; invertirlos hace sonar cada apagado."
  }

  # La compuerta tiene que cerrarse ANTES de que se abra la senal de falla, o el
  # apagado produce un aviso en la transicion. Dos periodos contra cinco dejan
  # tres minutos de margen. Si algun dia llega ese aviso, la correccion es
  # ampliar la senal de falla, nunca alargar la compuerta.
  assert {
    condition = (
      output.alerting.backend_dead_mans_switch.wanted_range_seconds <
      output.alerting.backend_dead_mans_switch.running_range_seconds
    )
    error_message = "La ventana de la compuerta debe ser mas corta que la de la senal de falla o el apagado produce un aviso en la transicion."
  }

  assert {
    condition = (
      strcontains(aws_cloudwatch_composite_alarm.backend_service_down[0].alarm_rule, "AND") &&
      strcontains(aws_cloudwatch_composite_alarm.backend_service_down[0].alarm_rule, "vetsoftware-dev-backend-no-running-tasks") &&
      strcontains(aws_cloudwatch_composite_alarm.backend_service_down[0].alarm_rule, "vetsoftware-dev-backend-tasks-wanted")
    )
    error_message = "La compuesta debe exigir las dos senales con AND: sin la compuerta vuelve a ser una alarma sobre la ausencia."
  }

  # Las tres entran en la ventana de mantenimiento. La compuerta ya las callaria
  # sola durante el apagado programado, pero una ventana que las omitiera dejaria
  # a las hijas cambiando de estado por debajo.
  assert {
    condition = alltrue([
      for alarm in [
        "vetsoftware-dev-backend-no-running-tasks",
        "vetsoftware-dev-backend-tasks-wanted",
        "vetsoftware-dev-backend-service-down",
      ] : contains(tolist(aws_cloudwatch_alarm_mute_rule.maintenance["nightly"].mute_targets[0].alarm_names), alarm)
    ])
    error_message = "Las tres piezas del interruptor deben entrar en la ventana de mantenimiento."
  }
}
