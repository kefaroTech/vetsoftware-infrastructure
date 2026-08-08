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

run "development_cost_profile_plans" {
  command = plan

  variables {
    backend_image_uri = "123456789012.dkr.ecr.us-east-1.amazonaws.com/vetsoftware-dev-backend@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

    application_secrets_json = jsonencode({
      JWT_SECRET       = "test-only-jwt-secret-with-sufficient-length"
      RESEND_API_KEY   = "test-only-resend-key"
      RECAPTCHA_SECRET = "test-only-recaptcha-key"
    })

    grafana_secrets_json = jsonencode({
      OTLP_USERNAME              = "test-only-user"
      OTLP_API_KEY               = "test-only-api-key"
      OTEL_EXPORTER_OTLP_HEADERS = "Authorization=Basic dGVzdDp0ZXN0"
    })

    cloudflare_tunnel_token = "test-only-cloudflare-tunnel-token-with-sufficient-length"

    grafana_otlp_endpoint         = "https://otlp.example.test/otlp"
    cors_allowed_origins          = ["https://dev.example.test"]
    email_from                    = "VetSoftware Dev <noreply@example.test>"
    registration_verification_url = "https://dev.example.test/verify"
    password_reset_url            = "https://dev.example.test/reset"
    login_url                     = "https://dev.example.test/login"
    api_domain_name               = "dev-api.example.test"
    alarm_email                   = "finops@example.test"
    slack_workspace_id            = "T0123456789"
    slack_channel_id              = "C0123456789"
    slack_alerts_channel_id       = "C0ALERTS000"
    slack_infra_channel_id        = "C0INFRA0000"
  }

  assert {
    condition     = output.cost_profile.backend_cpu_mib == 512 && output.cost_profile.backend_memory_mib == 2048
    error_message = "Dev debe conservar 512 CPU y 2048 MiB."
  }

  assert {
    condition     = output.cost_profile.fargate_spot_only && output.cost_profile.backend_min_tasks == 0 && output.cost_profile.backend_max_tasks == 1
    error_message = "Dev debe usar solo Fargate Spot y limitar el servicio entre cero y una tarea."
  }

  assert {
    condition     = output.cost_profile.database_class == "db.t4g.micro" && output.cost_profile.database_backup_days == 7
    error_message = "RDS dev debe conservar db.t4g.micro y siete dias de backup."
  }

  assert {
    condition = (
      output.cost_profile.database_hardening.deletion_protection &&
      output.cost_profile.database_hardening.iam_database_authentication_enabled &&
      !output.cost_profile.database_hardening.skip_final_snapshot
    )
    error_message = "RDS dev debe conservar IAM DB Auth, deletion protection y snapshot final."
  }

  assert {
    condition     = output.cost_profile.valkey_storage_gb == 1 && output.cost_profile.valkey_ecpu_per_second == 1000
    error_message = "Valkey dev debe mantener los límites mínimos."
  }

  assert {
    condition     = output.cost_profile.log_retention_days == 3 && output.cost_profile.load_balancer_count == 0 && !output.cost_profile.dedicated_alloy
    error_message = "Dev debe retener logs tres días y operar sin ALB ni Alloy dedicado."
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
  # es la que lo detiene antes de que las alarmas avisen tarde.
  assert {
    condition = (
      output.alerting.database.max_connections == 60 &&
      output.alerting.database.connections_warning == 42 &&
      output.alerting.database.connections_critical == 54
    )
    error_message = "Los umbrales de conexiones deben derivarse de max_connections: 70% advertencia y 90% critico sobre 60 conexiones."
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
    condition = (
      length(output.alerting.composite_alarm_names) == 2 &&
      contains(output.alerting.composite_alarm_names, "vetsoftware-dev-database-saturated") &&
      contains(output.alerting.composite_alarm_names, "vetsoftware-dev-backend-degraded")
    )
    error_message = "Deben existir las dos alarmas compuestas que correlacionan señales sueltas en un incidente."
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
