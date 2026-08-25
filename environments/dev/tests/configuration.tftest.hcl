mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
      arn        = "arn:aws:iam::123456789012:user/terraform-test"
      user_id    = "AIDATEST"
    }
  }

  mock_data "aws_availability_zones" {
    defaults = {
      names = ["us-east-1a", "us-east-1b", "us-east-1c"]
    }
  }

  mock_data "aws_region" {
    defaults = {
      name   = "us-east-1"
      region = "us-east-1"
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

# El ARN del monitor de anomalías solo existe después del apply, y el contrato de
# dev se valida con plan. Un mock no alcanza -se aplica en la fase de apply-, así
# que el valor se fuerza durante el plan y la aserción puede resolverse.
override_resource {
  target          = module.monitoring.aws_ce_anomaly_monitor.services[0]
  override_during = plan

  values = {
    arn = "arn:aws:ce::123456789012:anomalymonitor/11111111-2222-3333-4444-555555555555"
  }
}

# Mismo motivo que el monitor de anomalías: el ARN de un topic SNS no existe
# hasta el apply, y lo que se quiere verificar -que el ruteo por severidad esté
# cableado- se decide en plan.
override_resource {
  target          = module.monitoring.aws_sns_topic.alarms[0]
  override_during = plan

  values = {
    arn = "arn:aws:sns:us-east-1:123456789012:vetsoftware-dev-alarms"
  }
}

override_resource {
  target          = module.monitoring.aws_sns_topic.alarms_critical[0]
  override_during = plan

  values = {
    arn = "arn:aws:sns:us-east-1:123456789012:vetsoftware-dev-alarms-critical"
  }
}

override_resource {
  target          = module.monitoring.aws_sns_topic.events[0]
  override_during = plan

  values = {
    arn = "arn:aws:sns:us-east-1:123456789012:vetsoftware-dev-events"
  }
}

override_resource {
  target          = module.monitoring.aws_sns_topic.finops[0]
  override_during = plan

  values = {
    arn = "arn:aws:sns:us-east-1:123456789012:vetsoftware-dev-finops"
  }
}

# El ARN de la CMK tampoco existe hasta el apply, y sin el no se puede comprobar
# en plan que los log groups de RDS la usen en lugar de la clave de AWS.
override_resource {
  target          = module.kms.aws_kms_key.this
  override_during = plan

  values = {
    arn = "arn:aws:kms:us-east-1:123456789012:key/11111111-2222-3333-4444-555555555555"
  }
}

run "development_cost_profile_plans" {
  command = plan

  variables {
    backend_image_uri = "123456789012.dkr.ecr.us-east-1.amazonaws.com/vetsoftware-dev-backend@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

    jwt_secret                 = "test-only-jwt-secret-with-sufficient-length"
    resend_api_key             = "test-only-resend-key"
    recaptcha_secret           = "test-only-recaptcha-key"
    dian_enc_key               = "MDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDA="
    otlp_username              = "test-only-user"
    otlp_api_key               = "test-only-api-key"
    otel_exporter_otlp_headers = "Authorization=Basic dGVzdDp0ZXN0"

    cloudflare_tunnel_token = "test-only-cloudflare-tunnel-token-with-sufficient-length"
    grafana_logs_access_key = "1706326:glc_test-only-logs-write-token"

    grafana_otlp_endpoint                 = "https://otlp.example.test/otlp"
    cors_allowed_origins                  = ["https://dev.example.test"]
    email_from                            = "VetSoftware Dev <noreply@example.test>"
    registration_verification_url         = "https://dev.example.test/verify"
    password_reset_url                    = "https://dev.example.test/reset"
    login_url                             = "https://dev.example.test/login"
    platform_approver_email               = "plataforma@example.test"
    platform_access_review_base_url       = "https://dev-admin.example.test/aprobar-acceso"
    platform_invitation_base_url          = "https://dev-admin.example.test/aceptar-invitacion"
    platform_access_login_url             = "https://dev-admin.example.test/login"
    platform_access_request_template_id   = "11111111-1111-4111-8111-111111111111"
    platform_access_approved_template_id  = "22222222-2222-4222-8222-222222222222"
    platform_access_rejected_template_id  = "33333333-3333-4333-8333-333333333333"
    platform_access_welcome_template_id   = "44444444-4444-4444-8444-444444444444"
    registration_verification_template_id = "55555555-5555-4555-8555-555555555555"
    password_reset_template_id            = "66666666-6666-4666-8666-666666666666"
    employee_invitation_template_id       = "77777777-7777-4777-8777-777777777777"
    appointment_confirmation_template_id  = "88888888-8888-4888-8888-888888888888"
    api_domain_name                       = "dev-api.example.test"
    alarm_email                           = "finops@example.test"
    slack_workspace_id                    = "T0123456789"
    slack_channel_id                      = "C0123456789"
    slack_alerts_channel_id               = "C0ALERTS000"
    slack_infra_channel_id                = "C0INFRA0000"
  }

  # 3072 y no 2048: la tarea creció para alojar el sidecar colector sin quitarle
  # memoria al backend, que pasa de 1920 a 2688 MiB efectivos. La CPU no se
  # mueve. El contrato sigue congelando los dos valores para que cualquier
  # subida posterior vuelva a ser una decisión explícita de costo.
  assert {
    condition     = output.cost_profile.backend_cpu_mib == 512 && output.cost_profile.backend_memory_mib == 3072
    error_message = "Dev debe conservar 512 CPU y 3072 MiB de tarea."
  }

  assert {
    condition     = output.cost_profile.fargate_spot_only && output.cost_profile.backend_min_tasks == 0 && output.cost_profile.backend_max_tasks == 1
    error_message = "Dev debe usar solo Fargate Spot y limitar el servicio entre cero y una tarea."
  }

  # db.t4g.small es el escalon posterior a la crisis de memoria de la db.t4g.micro
  # (RDS-EVENT-0403 repetido). El contrato sigue congelando la clase: cualquier
  # subida posterior vuelve a ser una decision explicita de costo, no un descuido.
  assert {
    condition     = output.cost_profile.database_class == "db.t4g.small" && output.cost_profile.database_backup_days == 7
    error_message = "RDS dev debe conservar db.t4g.small y siete dias de backup."
  }

  assert {
    condition = (
      output.cost_profile.database_hardening.deletion_protection &&
      output.cost_profile.database_hardening.iam_database_authentication_enabled &&
      !output.cost_profile.database_hardening.skip_final_snapshot
    )
    error_message = "RDS dev debe conservar IAM DB Auth, deletion protection y snapshot final."
  }

  # Dev comparte la base con datos reales de pruebas, asi que el log general esta
  # igual de prohibido que en prod; la retencion sigue la del entorno, tres dias.
  assert {
    condition = (
      !contains(output.cost_profile.database_logging.exports, "general") &&
      output.cost_profile.database_logging.retention_in_days == 3 &&
      output.cost_profile.database_logging.all_encrypted_with_cmk &&
      length(output.cost_profile.database_logging.log_group_names) == 2
    )
    error_message = "Los logs de RDS dev deben excluir general, caducar a tres dias y cifrarse con la CMK del entorno."
  }

  # INF-49: la cuenta tiene que registrar quien hizo que. Dev tambien, porque su
  # base lleva datos de prueba con forma de datos reales.
  assert {
    condition = (
      output.traceability.multi_region &&
      output.traceability.global_service_events &&
      output.traceability.log_file_validation &&
      output.traceability.encrypted_with_cmk &&
      output.traceability.evidence_object_lock == "COMPLIANCE" &&
      output.traceability.access_analyzer_enabled
    )
    error_message = "Dev debe tener el rastro multi-region, con digests firmados, cifrado con la CMK y su evidencia bajo Object Lock COMPLIANCE."
  }

  # La restriccion de coste es parte del contrato, no una intencion: si alguien
  # enciende GuardDuty o los data events, el gate lo dice antes del apply.
  assert {
    condition = (
      !output.traceability.guardduty_enabled &&
      !output.traceability.s3_data_events
    )
    error_message = "Ni GuardDuty ni los data events pueden encenderse sin decidirlo: los dos se facturan."
  }

  # El informe salio del cron de GitHub porque llegaba entre dos y seis horas
  # tarde. Si el reloj vuelve a aflojarse -zona equivocada o ventana flexible- el
  # cambio pierde su unico motivo.
  assert {
    condition = (
      output.cost_reporting.timezone == "America/Bogota" &&
      output.cost_reporting.flexible_window == "OFF" &&
      output.cost_reporting.enabled
    )
    error_message = "El informe de costos debe dispararse a hora exacta de Bogota; una ventana flexible devuelve el retraso que se venia a eliminar."
  }

  // Que la CMK autorice a cloudtrail.amazonaws.com no se puede afirmar aqui:
  // mock_provider sustituye todo aws_iam_policy_document por un documento vacio,
  // igual que en sns_publish_authorization del modulo de monitoreo. El output
  // cmk_authorized_services existe y sirve para inspeccionarlo con terraform
  // output, pero fijarlo exige que modules/kms deje de usar
  // data.aws_caller_identity y pueda contrastarse con proveedor real, como ya
  // hicieron github_iac_roles y account_baseline.

  assert {
    condition     = output.cost_profile.valkey_storage_gb == 1 && output.cost_profile.valkey_ecpu_per_second == 1000
    error_message = "Valkey dev debe mantener los límites mínimos."
  }

  assert {
    condition     = output.cost_profile.log_retention_days == 3 && output.cost_profile.load_balancer_count == 0 && !output.cost_profile.dedicated_alloy
    error_message = "Dev debe retener logs tres días y operar sin ALB ni Alloy dedicado."
  }

  # La retención del backend se separó de la del entorno cuando su log group pasó
  # a ser la frontera de durabilidad del envío a Grafana Cloud. Las dos van en la
  # misma aserción a propósito: si alguien "unifica" las retenciones, o el backend
  # pierde su margen para reenviar, o RDS y los flow logs se encarecen en
  # silencio. El contrato de RDS en tres días ya se afirma más arriba.
  assert {
    condition = (
      output.cost_profile.backend_log_retention_days == 14 &&
      output.cost_profile.log_retention_days == 3
    )
    error_message = "El log group del backend debe retener catorce días sin arrastrar consigo la retención general del entorno."
  }

  assert {
    condition     = output.cost_profile.dedicated_vpc && output.vpc_cidr == "10.50.0.0/16"
    error_message = "Dev debe crear su propia VPC y no depender de la red de otro entorno."
  }

  assert {
    condition     = output.cloudflare_tunnel_origin_url == "http://localhost:8080"
    error_message = "El hostname dev de Cloudflare Tunnel debe apuntar al backend local de la misma tarea."
  }

  assert {
    condition = (
      output.cost_profile.assign_public_ip &&
      output.cost_profile.interface_endpoints == 0 &&
      output.cost_profile.public_https_cidr == "0.0.0.0/0" &&
      output.cost_profile.public_https_port == 443
    )
    error_message = "Dev debe usar Fargate con IP publica, cero Interface Endpoints y salida HTTPS publica explicita."
  }

  assert {
    condition = (
      length(output.scheduled_shutdown_names) == 3 &&
      contains(output.scheduled_shutdown_names, "vetsoftware-dev-backend-stop") &&
      contains(output.scheduled_shutdown_names, "vetsoftware-dev-database-stop") &&
      contains(output.scheduled_shutdown_names, "vetsoftware-dev-stop-notice")
    )
    error_message = "El apagado programado debe crear dos acciones ordenadas -ECS y despues RDS-, avisar en Slack al detener, y ninguna de encendido."
  }

  # El ruteo por severidad tiene que existir aunque nadie configure un canal
  # aparte: sin topico critico, una tarea muerta y un aviso de presupuesto
  # llegan con el mismo peso.
  assert {
    condition = (
      output.alerting.critical_topic_arn != null &&
      output.alerting.warning_topic_arn != null &&
      output.alerting.slack_enabled &&
      !output.alerting.dedicated_critical_channel
    )
    error_message = "Dev debe crear los dos topicos de severidad y enrutarlos a Slack; sin canal critico dedicado ambos entran por el canal existente."
  }

  # El reparto por tipo de senal: alarmas a su canal, eventos al de infra y
  # costos al canal base. Si una familia cambia de destino sin querer, la mas
  # frecuente entierra a la mas importante y nadie lo nota hasta que hace falta.
  assert {
    condition = (
      output.alerting.channel_routing.alerts == "C0ALERTS000" &&
      output.alerting.channel_routing.critical == "C0ALERTS000" &&
      output.alerting.channel_routing.infra == "C0INFRA0000" &&
      output.alerting.channel_routing.finops == "C0123456789"
    )
    error_message = "Alarmas, eventos y costos deben repartirse en tres canales; sin canal critico dedicado, lo critico acompana a las advertencias."
  }

  assert {
    condition = (
      output.alerting.events_topic_arn != null &&
      output.alerting.finops_topic_arn != null &&
      output.finops_alerts.topic_arn == output.alerting.finops_topic_arn
    )
    error_message = "El informe de costos debe publicar en el topic de costos, no en el de alarmas."
  }

  assert {
    condition = (
      output.alerting.ecs_events_enabled &&
      output.alerting.database_events_enabled &&
      output.alerting.cache_alarms_enabled &&
      !output.alerting.container_insights_alarms
    )
    error_message = "Dev debe observar eventos de ECS y RDS y alarmas de cache, y omitir las que dependen de Container Insights mientras siga apagado."
  }

  # Los umbrales se derivan de max_connections y del volumen: si alguien cambia
  # la clase de instancia sin actualizar database_max_connections, esta asercion
  # es la que lo detiene antes de que las alarmas avisen tarde. 120 es el valor
  # declarado para db.t4g.small y sigue siendo provisional hasta medirlo con
  # SHOW GLOBAL VARIABLES LIKE 'max_connections' contra la instancia arrancada.
  assert {
    condition = (
      output.alerting.database.max_connections == 120 &&
      output.alerting.database.connections_warning == 84 &&
      output.alerting.database.connections_critical == 108
    )
    error_message = "Los umbrales de conexiones deben derivarse de max_connections: 70% advertencia y 90% critico sobre 120 conexiones."
  }

  # La subida a db.t4g.small cambia que significa cada senal de memoria. Los dos
  # umbrales de FreeableMemory se quedan donde estaban porque miden margen
  # absoluto hasta el swap, no un porcentaje de la RAM instalada; el de swap baja
  # a 64 MiB porque con 2 GiB el swap sostenido deja de ser normal.
  assert {
    condition = (
      output.alerting.database.freeable_memory_warning_bytes == 268435456 &&
      output.alerting.database.freeable_memory_critical_bytes == 100663296 &&
      output.alerting.database.swap_warning_bytes == 67108864
    )
    error_message = "Dev debe conservar los umbrales de memoria libre en 256 MiB y 96 MiB y endurecer el de swap a 64 MiB."
  }

  assert {
    condition = (
      output.alerting.database.free_storage_warning_bytes == 5368709120 &&
      output.alerting.database.free_storage_critical_bytes == 2147483648
    )
    error_message = "El disco libre debe alertar al 25% y escalar al 10% de los 20 GiB asignados, que es donde RDS apaga la instancia."
  }

  assert {
    condition = (
      output.alerting.backend.memory_warning_percent == 85 &&
      output.alerting.backend.memory_critical_percent == 92 &&
      output.alerting.backend.crash_loop_threshold == 3 &&
      output.alerting.backend.crash_loop_window_min == 15
    )
    error_message = "El backend debe advertir memoria al 85%, escalar al 92% -antes del OOM de la JVM- y declarar crash loop con 3 paradas en 15 minutos."
  }

  assert {
    condition = alltrue([
      for alarm in [
        "vetsoftware-dev-database-saturated",
        "vetsoftware-dev-backend-degraded",
      ] : contains(output.alerting.composite_alarm_names, alarm)
    ])
    error_message = "Deben existir las alarmas compuestas que correlacionan señales sueltas en un incidente."
  }

  # El interruptor de hombre muerto del backend vive detras de Container
  # Insights, apagado por costo. Mientras lo siga estando, dev no tiene ninguna
  # compuerta de vivacidad y las 16 alarmas que suponen el entorno presente
  # siguen ciegas a su ausencia. Es deuda conocida, no un descuido: ver §9 de
  # docs/ALERTAS_OPERATIVAS.md.
  assert {
    condition     = output.alerting.backend_dead_mans_switch == null
    error_message = "Con Container Insights apagado no puede existir el interruptor del backend; si se enciende, hay que revisar la ventana de mantenimiento y esta asercion."
  }

  # La recuperacion no se notifica. CloudWatch manda el mismo AlarmDescription en
  # el disparo y en el OK, asi que un ok_actions apuntando a Slack producia un ✅
  # con el texto del incidente -y con la palabra CRITICO dentro-.
  assert {
    condition     = output.alerting.notify_on_recovery == false
    error_message = "Dev no debe notificar la recuperacion a Slack: el canal no tiene estado de incidente que cerrar."
  }

  # El silencio del apagado programado es una ventana explicita, no un efecto
  # colateral de treat_missing_data. La ventana tiene que cubrir el entorno
  # entero, incluidas las tres alarmas de log_shipping: una alarma fuera de la
  # regla devuelve el ruido nocturno desde un modulo que nadie revisa al mirar el
  # de monitoreo.
  assert {
    condition = (
      output.maintenance_mute.enabled &&
      output.maintenance_mute.timezone == "America/Bogota" &&
      length(output.maintenance_mute.rule_arns) == 2
    )
    error_message = "Dev debe declarar las dos ventanas de silencio -nocturna y fin de semana- en America/Bogota."
  }

  assert {
    condition = alltrue([
      for alarm in output.maintenance_mute.log_shipping :
      contains(output.maintenance_mute.alarm_names, alarm)
    ])
    error_message = "Las alarmas de log_shipping vigilan el mismo entorno que se apaga: tienen que entrar en la misma ventana."
  }

  # Limite duro del servicio: 100 alarmas por regla. Pasarlo no se ve en plan.
  assert {
    condition     = output.maintenance_mute.muted_alarms <= 100
    error_message = "Una mute rule admite como maximo 100 alarmas; hay que partirla antes de llegar ahi."
  }

  # La ceguera que quedaba: mientras dev pueda estar apagado en horario habil
  # -el arranque es manual- las metricas de flujo continuo no pueden tratar la
  # ausencia como falla. La ventana cubre el apagado programado, no el manual.
  assert {
    condition     = output.alerting.missing_data.continuous_metrics == "notBreaching"
    error_message = "Dev no puede tratar la ausencia de datos como falla mientras su encendido siga siendo manual."
  }

  assert {
    condition = (
      output.finops_alerts.monthly_budget_usd == 35 &&
      output.finops_alerts.forecast_threshold_usd == 28 &&
      output.finops_alerts.actual_threshold_usd == 35 &&
      output.finops_alerts.anomaly_threshold_usd == 3 &&
      output.finops_alerts.email_enabled &&
      output.finops_alerts.slack_enabled &&
      output.finops_alerts.anomaly_monitor_arn != null
    )
    error_message = "Dev debe alertar por correo y Slack al forecast USD 28 y real USD 35, con el monitor de anomalías encendido ahora que Cost Explorer está habilitado."
  }
}

# El envío durable de logs. Estas aserciones existen porque el modo de fallo de
# este tramo no es ruidoso: los logs siguen llegando, pero a un sitio donde nadie
# los busca, o dejan de llegar sin que nada cambie de color.
run "durable_log_shipping_contract" {
  command = plan

  variables {
    backend_image_uri = "123456789012.dkr.ecr.us-east-1.amazonaws.com/vetsoftware-dev-backend@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

    jwt_secret                 = "test-only-jwt-secret-with-sufficient-length"
    resend_api_key             = "test-only-resend-key"
    recaptcha_secret           = "test-only-recaptcha-key"
    dian_enc_key               = "MDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDA="
    otlp_username              = "test-only-user"
    otlp_api_key               = "test-only-api-key"
    otel_exporter_otlp_headers = "Authorization=Basic dGVzdDp0ZXN0"

    cloudflare_tunnel_token = "test-only-cloudflare-tunnel-token-with-sufficient-length"
    grafana_logs_access_key = "1706326:glc_test-only-logs-write-token"

    grafana_otlp_endpoint                 = "https://otlp.example.test/otlp"
    cors_allowed_origins                  = ["https://dev.example.test"]
    email_from                            = "VetSoftware Dev <noreply@example.test>"
    registration_verification_url         = "https://dev.example.test/verify"
    password_reset_url                    = "https://dev.example.test/reset"
    login_url                             = "https://dev.example.test/login"
    platform_approver_email               = "plataforma@example.test"
    platform_access_review_base_url       = "https://dev-admin.example.test/aprobar-acceso"
    platform_invitation_base_url          = "https://dev-admin.example.test/aceptar-invitacion"
    platform_access_login_url             = "https://dev-admin.example.test/login"
    platform_access_request_template_id   = "11111111-1111-4111-8111-111111111111"
    platform_access_approved_template_id  = "22222222-2222-4222-8222-222222222222"
    platform_access_rejected_template_id  = "33333333-3333-4333-8333-333333333333"
    platform_access_welcome_template_id   = "44444444-4444-4444-8444-444444444444"
    registration_verification_template_id = "55555555-5555-4555-8555-555555555555"
    password_reset_template_id            = "66666666-6666-4666-8666-666666666666"
    employee_invitation_template_id       = "77777777-7777-4777-8777-777777777777"
    appointment_confirmation_template_id  = "88888888-8888-4888-8888-888888888888"
    api_domain_name                       = "dev-api.example.test"
    alarm_email                           = "finops@example.test"
    slack_workspace_id                    = "T0123456789"
    slack_channel_id                      = "C0123456789"
  }

  # Lo crítico y lo que más fácil se rompe. Grafana quita el prefijo `lbl_` al
  # almacenar, así que `lbl_service_name` aterriza en Loki como `service_name`:
  # sin estos cuatro atributos los logs entran con la etiqueta por defecto del
  # endpoint -{job="cloud/aws"}- y ninguna consulta actual los encuentra. Los tres
  # primeros reproducen lo que hoy pone el exportador OTLP directo
  # (spring.opentelemetry.resource-attributes en application-dev.yml).
  assert {
    condition = (
      output.log_shipping.loki_labels["lbl_service_name"] == "vetsoftware" &&
      output.log_shipping.loki_labels["lbl_service_namespace"] == "mainvet" &&
      output.log_shipping.loki_labels["lbl_deployment_environment_name"] == "dev"
    )
    error_message = "Las etiquetas lbl_ deben reproducir service_name, service_namespace y deployment_environment_name del exportador OTLP; sin ellas las consultas existentes dejan de encontrar los logs."
  }

  # Mientras convivan las dos rutas hacia Loki hay que poder compararlas. Sin esta
  # etiqueta no se puede afirmar que la nueva no se deja nada antes de apagar la
  # vieja: los dos flujos serían indistinguibles en la misma serie.
  assert {
    condition     = output.log_shipping.loki_labels["lbl_telemetry_source"] == "firehose"
    error_message = "Falta la etiqueta que distingue el origen; sin ella no se pueden comparar la ruta OTLP y la ruta Firehose."
  }

  # Todas las etiquetas van prefijadas. Un atributo sin `lbl_` no falla: se ignora
  # en silencio y la etiqueta simplemente no existe en Loki.
  assert {
    condition     = alltrue([for name in keys(output.log_shipping.loki_labels) : startswith(name, "lbl_")])
    error_message = "Todo common attribute que deba convertirse en etiqueta de Loki tiene que llevar el prefijo lbl_."
  }

  # El motivo entero del cambio: dos horas de reintento y respaldo en S3. Con la
  # cola en memoria del BatchLogRecordProcessor un 429 sostenido abrió un hueco de
  # 50 minutos; con esta ventana se absorbe, y lo que no se absorba queda en el
  # bucket en vez de desaparecer.
  assert {
    condition = (
      output.log_shipping.retry_duration_seconds == 7200 &&
      output.log_shipping.s3_backup_mode == "FailedDataOnly" &&
      output.log_shipping.error_output_prefix != "" &&
      output.log_shipping.backup_retention_days >= 7
    )
    error_message = "El envío debe reintentar el máximo de 7200 s y respaldar en S3 lo que no logre entregar."
  }

  assert {
    condition = (
      output.log_shipping.filter_pattern == "" &&
      output.log_shipping.content_encoding == "GZIP" &&
      output.log_shipping.buffering_interval_seconds == 60 &&
      output.log_shipping.distribution == "ByLogStream" &&
      output.log_shipping.cloudwatch_logging
    )
    error_message = "La suscripción debe enviar todos los eventos comprimidos, agrupados por flujo, con buffering de un minuto y los errores del propio Firehose visibles en CloudWatch."
  }

  # El endpoint responde HTTP 502 a cualquier petición por encima de 5 MiB, y ese
  # rechazo solo se ve en el log group de Firehose. Las plantillas oficiales de
  # Grafana usan 1 MB; el contrato lo fija para que subirlo sea una decisión.
  assert {
    condition     = output.log_shipping.buffering_size_mib <= 5
    error_message = "El buffer de entrega no puede superar 5 MiB: el endpoint de Grafana Cloud rechaza con HTTP 502 las peticiones más grandes."
  }

  # La clave de acceso vive en un secreto propio, no como una clave más dentro del
  # que comparten OTLP y el sidecar. AWS solo documenta que Firehose "falla al
  # conectar si el secreto no tiene el formato JSON correcto", sin aclarar si
  # tolera claves hermanas, y ese fallo es silencioso y en tiempo de entrega.
  assert {
    condition     = output.log_shipping.access_key_secret_name == "vetsoftware-dev/grafana-cloud-logs"
    error_message = "El envío de logs debe leer de su secreto dedicado, no del secreto compartido de Grafana Cloud."
  }

  assert {
    condition = (
      output.log_shipping.delivery_stream_name == "vetsoftware-dev-logs" &&
      output.log_shipping.source_log_group == "/ecs/vetsoftware-dev-backend/backend" &&
      output.log_shipping.backup_bucket_name == "vetsoftware-dev-logs-backup-123456789012-us-east-1"
    )
    error_message = "El stream debe leer del log group del backend y respaldar en el bucket del entorno."
  }

  # El endpoint es específico del stack: aws-logs-prod-042. Este entorno ya
  # arrastró una vez tres endpoints distintos entre el plan, el apply y la
  # documentación, y esa clase de deriva no da error, solo silencio en Loki.
  assert {
    condition     = output.log_shipping.endpoint_url == "https://aws-logs-prod-042.grafana.net/aws-logs/api/v1/push"
    error_message = "El endpoint de Firehose debe apuntar al stack aws-logs-prod-042 de Grafana Cloud."
  }

  # Las alarmas son la mitad del valor del cambio: el fallo tiene que dejar de ser
  # invisible.
  #
  # Se afirma por NOMBRE y no con un contador. Un `length(...) == n` se rompe cada
  # vez que alguien anade una alarma legitima -paso al incorporar el interruptor
  # de hombre muerto- y no dice nada sobre si las que importan siguen ahi. Lo que
  # hay que fijar es que ninguna de las seis desaparezca.
  assert {
    condition = alltrue([
      for alarm in [
        # Las tres del tramo de entrega.
        "vetsoftware-dev-logs-delivery-failing",
        "vetsoftware-dev-logs-in-error-bucket",
        "vetsoftware-dev-logs-delivery-stalled",
        # Las dos senales internas del interruptor de hombre muerto. No notifican
        # por si solas, pero sin ellas la compuesta no puede activarse nunca.
        "vetsoftware-dev-logs-no-delivery",
        "vetsoftware-dev-logs-source-active",
        # La compuesta, unica de las tres ultimas que avisa.
        "vetsoftware-dev-logs-not-shipping",
      ] : contains(output.log_shipping.alarm_names, alarm)
    ])
    error_message = "Faltan alarmas del tramo de logs: las tres de entrega, las dos senales internas y la compuesta que las correlaciona."
  }

  # El aviso sale de la compuesta, nunca de sus hijas. Si alguien le devuelve las
  # acciones a la senal de volumen, dev recibe un aviso cada noche a las 20:00 y
  # el canal se vuelve a perder.
  assert {
    condition = (
      length(output.log_shipping.composite_alarm_names) == 1 &&
      contains(output.log_shipping.composite_alarm_names, "vetsoftware-dev-logs-not-shipping")
    )
    error_message = "El aviso del interruptor de hombre muerto debe salir de la compuesta, nunca de sus hijas por separado."
  }

  # Invariante de tiempos del interruptor de hombre muerto. Durante el apagado la
  # senal de vivacidad tiene que volver a OK -y cerrar la compuerta- ANTES de que
  # la de volumen entre en ALARM. Con 1x5 min contra 2x5 min quedan cinco minutos
  # de margen; si se invierte, dev recibe un aviso diario a las 20:10.
  #
  # La correccion, si algun dia llega ese aviso, es ampliar la de volumen a tres
  # periodos, nunca alargar la vivacidad: alargarla retrasa tambien la deteccion
  # del fallo real.
  assert {
    condition = (
      output.log_shipping.dead_mans_switch.liveness_evaluation_range <
      output.log_shipping.dead_mans_switch.volume_evaluation_range
    )
    error_message = "La ventana de la senal de vivacidad debe ser mas corta que la de volumen o el apagado programado produce un aviso diario."
  }

  # Los dos treat_missing_data del interruptor son opuestos a proposito y esa
  # oposicion ES el mecanismo: el hueco de volumen significa falla, el hueco de
  # actividad significa calma. Invertir cualquiera de los dos devuelve el punto
  # ciego sin que nada mas cambie.
  assert {
    condition = (
      output.log_shipping.dead_mans_switch.volume_missing_data == "breaching" &&
      output.log_shipping.dead_mans_switch.liveness_missing_data == "notBreaching" &&
      output.log_shipping.dead_mans_switch.liveness_metric == "IncomingLogEvents"
    )
    error_message = "El interruptor exige que el hueco de volumen sea falla y el de actividad del origen sea calma; invertirlos devuelve el punto ciego."
  }

  # El token de la Cloud Access Policy no se declara en Terraform: Firehose lo
  # resuelve contra Secrets Manager en cada entrega. Si algún día alguien lo pasa
  # por `access_key`, acaba en el state.
  assert {
    condition     = !output.log_shipping.access_key_in_state
    error_message = "La clave de acceso del endpoint no puede viajar en la configuración del stream ni quedar en el state."
  }

  assert {
    condition     = output.log_shipping.encrypted_with_cmk == "arn:aws:kms:us-east-1:123456789012:key/11111111-2222-3333-4444-555555555555"
    error_message = "El respaldo en S3 y el log group operativo de Firehose deben cifrarse con la CMK del entorno."
  }
}

# El error probable, convertido en fallo del plan.
#
# La clave de acceso NO es el token: la plantilla oficial de CloudFormation de
# Grafana Labs la compone como '${LogsInstanceID}:${LogsWriteToken}'. Pegar solo
# el `glc_...` —que es lo que devuelve la consola al crear la Cloud Access
# Policy, y por tanto lo que uno tiene en el portapapeles— produce un apply
# verde, un stream creado y cero entregas. No hay excepción, no hay alarma de
# infraestructura: solo Loki vacío por esa ruta.
#
# Por eso el contrato exige el prefijo numérico, y no simplemente "no vacío".
run "la_clave_de_acceso_exige_el_instance_id_delante" {
  command = plan

  expect_failures = [var.grafana_logs_access_key]

  variables {
    log_shipping_enabled = true

    # El token tal cual sale de la consola de Grafana, sin el `1706326:` delante.
    grafana_logs_access_key = "glc_test-only-logs-write-token"

    backend_image_uri = "123456789012.dkr.ecr.us-east-1.amazonaws.com/vetsoftware-dev-backend@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

    jwt_secret                 = "test-only-jwt-secret-with-sufficient-length"
    resend_api_key             = "test-only-resend-key"
    recaptcha_secret           = "test-only-recaptcha-key"
    dian_enc_key               = "MDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDA="
    otlp_username              = "test-only-user"
    otlp_api_key               = "test-only-api-key"
    otel_exporter_otlp_headers = "Authorization=Basic dGVzdDp0ZXN0"

    cloudflare_tunnel_token = "test-only-cloudflare-tunnel-token-with-sufficient-length"

    grafana_otlp_endpoint                 = "https://otlp.example.test/otlp"
    cors_allowed_origins                  = ["https://dev.example.test"]
    email_from                            = "VetSoftware Dev <noreply@example.test>"
    registration_verification_url         = "https://dev.example.test/verify"
    password_reset_url                    = "https://dev.example.test/reset"
    login_url                             = "https://dev.example.test/login"
    platform_approver_email               = "plataforma@example.test"
    platform_access_review_base_url       = "https://dev-admin.example.test/aprobar-acceso"
    platform_invitation_base_url          = "https://dev-admin.example.test/aceptar-invitacion"
    platform_access_login_url             = "https://dev-admin.example.test/login"
    platform_access_request_template_id   = "11111111-1111-4111-8111-111111111111"
    platform_access_approved_template_id  = "22222222-2222-4222-8222-222222222222"
    platform_access_rejected_template_id  = "33333333-3333-4333-8333-333333333333"
    platform_access_welcome_template_id   = "44444444-4444-4444-8444-444444444444"
    registration_verification_template_id = "55555555-5555-4555-8555-555555555555"
    password_reset_template_id            = "66666666-6666-4666-8666-666666666666"
    employee_invitation_template_id       = "77777777-7777-4777-8777-777777777777"
    appointment_confirmation_template_id  = "88888888-8888-4888-8888-888888888888"
    api_domain_name                       = "dev-api.example.test"
  }
}

# El sidecar de trazas y métricas, con el interruptor APAGADO.
#
# Este run es el importante de los dos. Un intento anterior dejó
# OTEL_EXPORTER_OTLP_{TRACES,METRICS}_ENDPOINT fijos a localhost, y eso convirtió
# `telemetry_sidecar_enabled = false` en una forma de cortar la telemetría en
# silencio: la aplicación seguía exportando, pero contra un colector que no
# existía en la tarea. Apagar el interruptor tiene que devolver el sistema
# exactamente al comportamiento anterior a este cambio, no dejarlo peor.
run "el_sidecar_apagado_devuelve_la_exportacion_directa" {
  command = plan

  variables {
    telemetry_sidecar_enabled = false

    backend_image_uri = "123456789012.dkr.ecr.us-east-1.amazonaws.com/vetsoftware-dev-backend@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

    jwt_secret                 = "test-only-jwt-secret-with-sufficient-length"
    resend_api_key             = "test-only-resend-key"
    recaptcha_secret           = "test-only-recaptcha-key"
    dian_enc_key               = "MDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDA="
    otlp_username              = "test-only-user"
    otlp_api_key               = "test-only-api-key"
    otel_exporter_otlp_headers = "Authorization=Basic dGVzdDp0ZXN0"

    cloudflare_tunnel_token = "test-only-cloudflare-tunnel-token-with-sufficient-length"
    grafana_logs_access_key = "1706326:glc_test-only-logs-write-token"

    grafana_otlp_endpoint                 = "https://otlp.example.test/otlp"
    cors_allowed_origins                  = ["https://dev.example.test"]
    email_from                            = "VetSoftware Dev <noreply@example.test>"
    registration_verification_url         = "https://dev.example.test/verify"
    password_reset_url                    = "https://dev.example.test/reset"
    login_url                             = "https://dev.example.test/login"
    platform_approver_email               = "plataforma@example.test"
    platform_access_review_base_url       = "https://dev-admin.example.test/aprobar-acceso"
    platform_invitation_base_url          = "https://dev-admin.example.test/aceptar-invitacion"
    platform_access_login_url             = "https://dev-admin.example.test/login"
    platform_access_request_template_id   = "11111111-1111-4111-8111-111111111111"
    platform_access_approved_template_id  = "22222222-2222-4222-8222-222222222222"
    platform_access_rejected_template_id  = "33333333-3333-4333-8333-333333333333"
    platform_access_welcome_template_id   = "44444444-4444-4444-8444-444444444444"
    registration_verification_template_id = "55555555-5555-4555-8555-555555555555"
    password_reset_template_id            = "66666666-6666-4666-8666-666666666666"
    employee_invitation_template_id       = "77777777-7777-4777-8777-777777777777"
    appointment_confirmation_template_id  = "88888888-8888-4888-8888-888888888888"
    api_domain_name                       = "dev-api.example.test"
    alarm_email                           = "finops@example.test"
    slack_workspace_id                    = "T0123456789"
    slack_channel_id                      = "C0123456789"
  }

  # Las tres señales salen directas al gateway de Grafana Cloud. Ninguna apunta a
  # localhost: sin sidecar, localhost es un puerto cerrado.
  assert {
    condition = (
      output.telemetry.otlp_endpoints.traces == "https://otlp.example.test/otlp/v1/traces" &&
      output.telemetry.otlp_endpoints.metrics == "https://otlp.example.test/otlp/v1/metrics" &&
      output.telemetry.otlp_endpoints.logs == "https://otlp.example.test/otlp/v1/logs"
    )
    error_message = "Con el sidecar apagado los tres endpoints OTLP deben volver al gateway de Grafana Cloud; dejar localhost cableado corta la telemetría en silencio."
  }

  # Sin destino remoto autenticado no hay exportación posible, y además
  # RemoteConnectionValidator se niega a arrancar la aplicación sin esta variable.
  assert {
    condition     = output.telemetry.otlp_headers_from_secret
    error_message = "OTEL_EXPORTER_OTLP_HEADERS debe seguir viniendo de backend_secrets con el sidecar apagado."
  }

  # Ni contenedor, ni volumen, ni log group, ni alarmas: apagado es apagado.
  assert {
    condition = (
      !output.telemetry.sidecar.enabled &&
      output.telemetry.sidecar.cpu == 0 &&
      output.telemetry.sidecar.memory == 0 &&
      length(output.telemetry.sidecar.pipelines) == 0 &&
      length(output.telemetry.alarm_names) == 0
    )
    error_message = "Con el interruptor apagado no debe quedar ningún resto del sidecar en la tarea ni en las alarmas."
  }

  # La tarea creció aunque el sidecar no esté: el backend se queda con toda la
  # memoria nueva menos la de cloudflared.
  assert {
    condition     = output.telemetry.sidecar.backend_memory == 2944
    error_message = "Sin sidecar el backend debe recibir 3072 - 128 = 2944 MiB."
  }
}

# El mismo entorno con el interruptor ENCENDIDO. Aquí se afirma lo que distingue
# a este sidecar de un colector cualquiera: qué señales procesa, cuáles no, y por
# qué la pérdida deja de ser silenciosa.
run "el_sidecar_encendido_pone_la_cola_en_disco_sin_tocar_los_logs" {
  command = plan

  variables {
    telemetry_sidecar_enabled = true

    backend_image_uri = "123456789012.dkr.ecr.us-east-1.amazonaws.com/vetsoftware-dev-backend@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

    jwt_secret                 = "test-only-jwt-secret-with-sufficient-length"
    resend_api_key             = "test-only-resend-key"
    recaptcha_secret           = "test-only-recaptcha-key"
    dian_enc_key               = "MDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDA="
    otlp_username              = "test-only-user"
    otlp_api_key               = "test-only-api-key"
    otel_exporter_otlp_headers = "Authorization=Basic dGVzdDp0ZXN0"

    cloudflare_tunnel_token = "test-only-cloudflare-tunnel-token-with-sufficient-length"
    grafana_logs_access_key = "1706326:glc_test-only-logs-write-token"

    grafana_otlp_endpoint                 = "https://otlp.example.test/otlp"
    cors_allowed_origins                  = ["https://dev.example.test"]
    email_from                            = "VetSoftware Dev <noreply@example.test>"
    registration_verification_url         = "https://dev.example.test/verify"
    password_reset_url                    = "https://dev.example.test/reset"
    login_url                             = "https://dev.example.test/login"
    platform_approver_email               = "plataforma@example.test"
    platform_access_review_base_url       = "https://dev-admin.example.test/aprobar-acceso"
    platform_invitation_base_url          = "https://dev-admin.example.test/aceptar-invitacion"
    platform_access_login_url             = "https://dev-admin.example.test/login"
    platform_access_request_template_id   = "11111111-1111-4111-8111-111111111111"
    platform_access_approved_template_id  = "22222222-2222-4222-8222-222222222222"
    platform_access_rejected_template_id  = "33333333-3333-4333-8333-333333333333"
    platform_access_welcome_template_id   = "44444444-4444-4444-8444-444444444444"
    registration_verification_template_id = "55555555-5555-4555-8555-555555555555"
    password_reset_template_id            = "66666666-6666-4666-8666-666666666666"
    employee_invitation_template_id       = "77777777-7777-4777-8777-777777777777"
    appointment_confirmation_template_id  = "88888888-8888-4888-8888-888888888888"
    api_domain_name                       = "dev-api.example.test"
    alarm_email                           = "finops@example.test"
    slack_workspace_id                    = "T0123456789"
    slack_channel_id                      = "C0123456789"
  }

  # Trazas y métricas al colector local; los logs NO. Su durabilidad ya está
  # resuelta por CloudWatch y Firehose fuera de la tarea, y el sidecar no declara
  # pipeline de logs: apuntarlos aquí daría 404 en /v1/logs.
  assert {
    condition = (
      output.telemetry.otlp_endpoints.traces == "http://localhost:4318/v1/traces" &&
      output.telemetry.otlp_endpoints.metrics == "http://localhost:4318/v1/metrics" &&
      output.telemetry.otlp_endpoints.logs == "https://otlp.example.test/otlp/v1/logs"
    )
    error_message = "Con el sidecar activo trazas y métricas van al colector local, pero los logs siguen yendo directos al gateway: su durabilidad vive fuera de la tarea."
  }

  # Las dos ausencias deliberadas, escritas como contrato porque un cambio
  # distraído las revertiría sin ruido. tail_sampling sería incorrecto en cuanto
  # haya más de una tarea: los spans de una traza se repartirían entre tasks y
  # cada colector decidiría con información parcial.
  assert {
    condition = (
      length(output.telemetry.sidecar.pipelines) == 2 &&
      contains(output.telemetry.sidecar.pipelines, "traces") &&
      contains(output.telemetry.sidecar.pipelines, "metrics") &&
      !output.telemetry.sidecar.processes_logs &&
      !output.telemetry.sidecar.tail_sampling
    )
    error_message = "El sidecar debe tener exactamente los pipelines de trazas y métricas, sin logs y sin tail_sampling."
  }

  # El motivo entero del cambio: cola en disco y media hora de reintento en vez
  # de una cola en memoria que descarta en silencio.
  assert {
    condition = (
      output.telemetry.sidecar.retry_max_elapsed_time == "30m" &&
      output.telemetry.sidecar.queue_size == 2000 &&
      output.telemetry.sidecar.self_metrics_durable
    )
    error_message = "El exportador debe reintentar 30 minutos con cola persistente, y las métricas internas deben salir por ese mismo pipeline durable."
  }

  # Sin las series internas la pérdida vuelve a ser indemostrable, y sin las
  # alarmas un sidecar essential = false muere sin que nadie se entere.
  assert {
    condition = (
      length(output.telemetry.alarm_names) == 2 &&
      contains(output.telemetry.alarm_names, "vetsoftware-dev-telemetry-sidecar-stopped") &&
      contains(output.telemetry.alarm_names, "vetsoftware-dev-telemetry-sidecar-errors")
    )
    error_message = "Deben existir las dos alarmas del sidecar: contenedor detenido con la tarea viva, y errores sostenidos del colector."
  }

  # El reparto. El backend sube respecto de hoy pese a ceder 256 MiB al sidecar,
  # y el memory_limiter queda por debajo de la reserva para que quien rechace sea
  # el colector -contabilizándolo- y no el kernel, que mata sin dejar rastro.
  assert {
    condition = (
      output.telemetry.sidecar.cpu == 64 &&
      output.telemetry.sidecar.memory == 256 &&
      output.telemetry.sidecar.backend_memory == 2688 &&
      output.telemetry.sidecar.memory_limit_mib < output.telemetry.sidecar.memory
    )
    error_message = "El sidecar debe reservar 64/256 dejando 2688 MiB al backend, con el memory_limiter por debajo de su reserva."
  }

  # ECS arranca el colector antes que el backend, así que lo para después: el
  # drenaje ocurre con la aplicación ya callada. 120 s es el máximo de Fargate.
  assert {
    condition = (
      output.telemetry.sidecar.backend_starts_after_sidecar &&
      output.telemetry.sidecar.stop_timeout == 120
    )
    error_message = "El backend debe depender del arranque del sidecar para que ECS lo pare al final y le deje drenar."
  }

  # Root es deliberado y está documentado en el módulo: los volúmenes de tarea de
  # Fargate se montan como root y el usuario 10001 de la imagen distroless no
  # puede crear el directorio de la cola.
  assert {
    condition = (
      output.telemetry.sidecar.runs_as_root &&
      output.telemetry.sidecar.readonly_root &&
      output.telemetry.sidecar.receiver_endpoint == "127.0.0.1:4318"
    )
    error_message = "El sidecar debe correr como root con el raíz de solo lectura y escuchar únicamente en loopback."
  }

  # Ni el usuario ni el token del colector pueden acabar en el state: ECS los
  # resuelve contra Secrets Manager con el rol de ejecución.
  assert {
    condition     = !output.telemetry.sidecar.credentials_in_state
    error_message = "Las credenciales OTLP del sidecar no pueden viajar en la definición de tarea ni quedar en el state."
  }

  # Muestreo al 100 %: el emisor deja de decidir y la decisión pasa a Adaptive
  # Traces, que sí ve la traza completa.
  assert {
    condition     = output.telemetry.tracing_sampling == 1
    error_message = "dev debe emitir el 100 % de las trazas y delegar el muestreo en Adaptive Traces."
  }
}
