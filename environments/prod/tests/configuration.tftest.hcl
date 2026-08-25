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

  mock_data "aws_ssm_parameter" {
    defaults = {
      value = "ami-0123456789abcdef0"
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

# El ARN de un topic SNS no existe hasta el apply, y lo que hay que verificar
# -que produccion tenga a donde publicar- se decide en plan. El override no
# debilita la asercion: el indice [0] solo existe si el modulo creo el topico, y
# si no lo creara el output volveria a ser null y la asercion caeria igual.
override_resource {
  target          = module.monitoring.aws_sns_topic.alarms[0]
  override_during = plan

  values = {
    arn = "arn:aws:sns:us-east-1:123456789012:vetsoftware-prod-alarms"
  }
}

override_resource {
  target          = module.monitoring.aws_sns_topic.alarms_critical[0]
  override_during = plan

  values = {
    arn = "arn:aws:sns:us-east-1:123456789012:vetsoftware-prod-alarms-critical"
  }
}

override_resource {
  target          = module.monitoring.aws_sns_topic.events[0]
  override_during = plan

  values = {
    arn = "arn:aws:sns:us-east-1:123456789012:vetsoftware-prod-events"
  }
}

override_resource {
  target          = module.monitoring.aws_sns_topic.finops[0]
  override_during = plan

  values = {
    arn = "arn:aws:sns:us-east-1:123456789012:vetsoftware-prod-finops"
  }
}

# El ARN de la CMK no existe hasta el apply, y sin el no se puede comprobar en
# plan que los log groups de RDS la usen en lugar de la clave de AWS.
override_resource {
  target          = module.kms.aws_kms_key.this
  override_during = plan

  values = {
    arn = "arn:aws:kms:us-east-1:123456789012:key/11111111-2222-3333-4444-555555555555"
  }
}

# Las variables obligatorias del root se declaran una sola vez para todo el
# archivo: cada `run` las hereda y solo sobrescribe lo que su asercion mide. Sin
# esto, el run que comprueba que alarm_email es obligatorio tendria que repetir
# el bloque entero y fallaria por la variable equivocada.
variables {
  backend_image_uri = "123456789012.dkr.ecr.us-east-1.amazonaws.com/vetsoftware-backend@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

  jwt_secret                 = "test-only-jwt-secret-with-sufficient-length"
  resend_api_key             = "test-only-resend-key"
  recaptcha_secret           = "test-only-recaptcha-key"
  dian_enc_key               = "MDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDA="
  otlp_username              = "test-only-user"
  otlp_api_key               = "test-only-api-key"
  otel_exporter_otlp_headers = "Authorization=Basic dGVzdDp0ZXN0"

  cloudflare_tunnel_token = "test-only-cloudflare-tunnel-token-with-sufficient-length"

  grafana_otlp_endpoint         = "https://otlp.example.test/otlp"
  api_domain_name               = "api.example.test"
  cors_allowed_origins          = ["https://app.example.test"]
  email_from                    = "VetSoftware <noreply@example.test>"
  registration_verification_url = "https://app.example.test/verify"
  password_reset_url            = "https://app.example.test/reset"
  login_url                     = "https://app.example.test/login"
  alarm_email                   = "alertas@example.test"
}

run "production_configuration_plans" {
  command = plan

  variables {
    monthly_budget_usd = 0
  }

  assert {
    condition     = output.monthly_budget_usd == 0
    error_message = "El presupuesto debe poder deshabilitarse para pruebas."
  }

  assert {
    condition = (
      output.database_hardening.backup_retention_period >= 7 &&
      output.database_hardening.deletion_protection &&
      output.database_hardening.iam_database_authentication_enabled &&
      !output.database_hardening.skip_final_snapshot
    )
    error_message = "RDS prod debe conservar backup, IAM DB Auth, deletion protection y snapshot final."
  }

  # El log general expone el texto de cada consulta y sus log groups, si los crea
  # RDS, nacen sin caducidad y con la clave de AWS. Prod no puede desplegarse asi.
  assert {
    condition = (
      !contains(output.database_logging.exports, "general") &&
      output.database_logging.retention_in_days == 30 &&
      output.database_logging.all_encrypted_with_cmk &&
      length(output.database_logging.log_group_names) == 2
    )
    error_message = "Los logs de RDS prod deben excluir general, caducar a 30 dias y cifrarse con la CMK del entorno."
  }

  # INF-49. La evidencia de prod tiene que cubrir el termino de firmeza fiscal, y
  # el Object Lock COMPLIANCE no permite alargar despues lo que se escriba corto.
  assert {
    condition = (
      output.traceability.multi_region &&
      output.traceability.global_service_events &&
      output.traceability.log_file_validation &&
      output.traceability.encrypted_with_cmk &&
      output.traceability.evidence_object_lock == "COMPLIANCE" &&
      output.traceability.evidence_retention >= 1825 &&
      output.traceability.access_analyzer_enabled
    )
    error_message = "Prod debe conservar el rastro cinco anios bajo Object Lock COMPLIANCE, multi-region y con digests firmados."
  }

  assert {
    condition = (
      !output.traceability.guardduty_enabled &&
      !output.traceability.s3_data_events
    )
    error_message = "Ni GuardDuty ni los data events pueden encenderse sin decidirlo: los dos se facturan."
  }

  // Igual que en dev: la autorizacion de la CMK no es afirmable bajo
  // mock_provider, que vacia todo aws_iam_policy_document.

  # Una shell en el contenedor de produccion lee DB_PASSWORD, JWT_SECRET y
  # DIAN_ENC_KEY. Que este apagada es parte del hallazgo, no un detalle aparte.
  assert {
    condition     = !var.enable_execute_command
    error_message = "ECS Exec debe venir apagado en produccion; se activa con un apply deliberado cuando haya que diagnosticar."
  }

  assert {
    condition = (
      output.network_egress_profile.assign_public_ip &&
      output.network_egress_profile.interface_endpoints == 0 &&
      output.network_egress_profile.s3_gateway_endpoint &&
      output.network_egress_profile.backend_cidr == "0.0.0.0/0" &&
      output.network_egress_profile.backend_port == 443 &&
      output.network_egress_profile.alloy_cidr == "0.0.0.0/0" &&
      output.network_egress_profile.alloy_port == 443
    )
    error_message = "Prod debe usar salida HTTPS publica explicita, Fargate con IP publica, cero Interface Endpoints y S3 Gateway."
  }

  assert {
    condition     = output.cloudflare_tunnel_origin_url == "http://localhost:8080"
    error_message = "El hostname prod de Cloudflare Tunnel debe apuntar al backend local de la misma tarea."
  }

  # INF-37 / #108. Lo que se afirma aqui no es como se comporta el modulo de
  # monitoreo -se comporta exactamente como esta escrito- sino como lo invoca
  # produccion. El estado degradado que esto impide no fallaba: creaba las
  # alarmas con alarm_actions vacio y salia verde.
  #
  # Este run no configura Slack a proposito. Que los cuatro topicos existan con
  # slack_enabled en falso es justo la regresion que hay que impedir: el destino
  # de una alarma de produccion no puede depender de que alguien haya rellenado
  # dos IDs de Slack.
  assert {
    condition = (
      output.alarm_destinations.email_enabled &&
      !output.alarm_destinations.slack_enabled &&
      output.alarm_destinations.warning_topic_arn != null &&
      output.alarm_destinations.critical_topic_arn != null &&
      output.alarm_destinations.events_topic_arn != null &&
      output.alarm_destinations.finops_topic_arn != null
    )
    error_message = "Produccion debe crear los cuatro topicos SNS y suscribir el correo aunque Slack no este configurado."
  }

  # El mismo valor que recibe module.account_baseline. Nulo aqui significa que
  # la regla de EventBridge que rutea los hallazgos de GuardDuty no se crea
  # -modules/account_baseline/main.tf:369-, y el detector queda sin destino el
  # dia que se encienda.
  assert {
    condition     = output.alarm_destinations.guardduty_routing_topic_arn != null
    error_message = "El topic de alarmas debe existir para que account_baseline pueda rutear los hallazgos de GuardDuty."
  }

  # Las dos compuestas correlacionan senales que por separado no son incidente.
  # Cuelgan de que exista topico: sin destino no se crean, y con ellas se pierde
  # la unica alarma que dice "la base se cae en los proximos minutos".
  assert {
    condition     = length(output.alerting.composite_alarm_names) == 2
    error_message = "Produccion debe crear las alarmas compuestas de saturacion de RDS y degradacion del backend."
  }

  # El circuito de eventos es lo unico que detecta una tarea que muere y no
  # vuelve: CPU y memoria miden una tarea viva. Container Insights sigue apagado
  # -se factura por metrica-, y por eso el interruptor de hombre muerto es nulo.
  assert {
    condition = (
      output.alerting.ecs_events_enabled &&
      output.alerting.database_events_enabled &&
      !output.alerting.container_insights_alarms &&
      output.alerting.backend_dead_mans_switch == null
    )
    error_message = "Produccion debe observar eventos de ECS y RDS; las alarmas que dependen de Container Insights quedan fuera mientras siga apagado."
  }

  # Los umbrales de conexiones cuelgan de max_connections, no de un numero
  # escrito a mano. El default del modulo -60- es el de una clase micro: con la
  # db.t4g.small de prod abriria la advertencia a 42 conexiones.
  assert {
    condition = (
      output.alerting.database.max_connections == 120 &&
      output.alerting.database.connections_warning == 84 &&
      output.alerting.database.connections_critical == 108
    )
    error_message = "Los umbrales de conexiones de prod deben derivarse de max_connections: 70% advertencia y 90% critico sobre 120."
  }

  # Ninguna alarma avisa al recuperarse: el OK duplicaria el ruido sin anadir
  # una decision. Se afirma porque es exactamente lo que alguien vuelve a pegar.
  assert {
    condition     = !output.alerting.notify_on_recovery
    error_message = "Las alarmas de produccion no deben notificar la recuperacion."
  }
}

# La otra mitad del contrato: que el estado degradado sea imposible, no solo que
# hoy no se de. Con el correo vacio -que era el default- el plan de produccion
# tiene que detenerse en la validacion de la variable, antes de tocar AWS.
run "produccion_no_puede_planificarse_sin_destino_de_alarma" {
  command = plan

  variables {
    alarm_email = ""
  }

  expect_failures = [
    var.alarm_email,
  ]
}
