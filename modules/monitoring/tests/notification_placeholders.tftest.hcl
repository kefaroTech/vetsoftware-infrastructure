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

override_resource {
  target          = aws_sns_topic.events[0]
  override_during = plan

  values = {
    arn = "arn:aws:sns:us-east-1:123456789012:vetsoftware-dev-events"
  }
}

variables {
  name                             = "vetsoftware-dev"
  aws_region                       = "us-east-1"
  alarm_email                      = "sre@example.test"
  slack_workspace_id               = "T0123456789"
  slack_channel_id                 = "C0123456789"
  ecs_cluster_name                 = "vetsoftware-dev-backend"
  ecs_cluster_arn                  = "arn:aws:ecs:us-east-1:123456789012:cluster/vetsoftware-dev-backend"
  ecs_service_name                 = "backend"
  ecs_service_arn                  = "arn:aws:ecs:us-east-1:123456789012:service/vetsoftware-dev-backend/backend"
  ecs_events_enabled               = true
  cloudflare_tunnel_log_group_name = "/ecs/vetsoftware-dev-backend/cloudflare-tunnel"
  database_identifier              = "vetsoftware-dev-mysql"
  database_arn                     = "arn:aws:rds:us-east-1:123456789012:db:vetsoftware-dev-mysql"
  database_events_enabled          = true
  alloy_instance_ids               = []
}

# jsonencode convierte los signos de menor y mayor a su forma unicode escapada
# -herencia de encoding/json de Go-, y EventBridge busca el marcador en el TEXTO
# de la plantilla. Escapado no sustituye nada y la notificacion llega con los
# marcadores crudos: "Evento: <eventId>" en lugar del EventID.
#
# El fallo no rompe ningun apply y no lo ve ni validate, ni tflint, ni Trivy: la
# plantilla es JSON valido y la regla se crea igual. Solo se nota leyendo un
# mensaje en Slack, que es cuando ya hace falta que sirva. Por eso se fija aqui.

run "los_marcadores_llegan_sin_escapar" {
  command = plan

  assert {
    condition = alltrue([
      for template in [
        aws_cloudwatch_event_target.database_critical_notification[0].input_transformer[0].input_template,
        aws_cloudwatch_event_target.database_warning_notification[0].input_transformer[0].input_template,
        aws_cloudwatch_event_target.ecs_task_failed_notification[0].input_transformer[0].input_template,
        aws_cloudwatch_event_target.ecs_deployment_failed_notification[0].input_transformer[0].input_template,
        aws_cloudwatch_event_target.ecs_service_impaired_notification[0].input_transformer[0].input_template,
      ] : !strcontains(template, "u003c") && !strcontains(template, "u003e")
    ])
    error_message = "Alguna plantilla dejo los signos de menor y mayor escapados: EventBridge no sustituira el marcador y el mensaje llegara crudo."
  }

  # No basta con que no esten escapados: el marcador tiene que existir y
  # coincidir con la clave declarada en input_paths, o la sustitucion tampoco
  # ocurre.
  assert {
    condition = alltrue([
      for target in [
        aws_cloudwatch_event_target.database_critical_notification[0],
        aws_cloudwatch_event_target.database_warning_notification[0],
        ] : alltrue([
          for key in keys(target.input_transformer[0].input_paths) :
          strcontains(target.input_transformer[0].input_template, "<${key}>")
      ])
    ])
    error_message = "Una variable de input_paths no aparece como marcador en la plantilla de RDS: el dato nunca llegara al mensaje."
  }

  assert {
    condition = alltrue([
      for target in [
        aws_cloudwatch_event_target.ecs_task_failed_notification[0],
        aws_cloudwatch_event_target.ecs_deployment_failed_notification[0],
        aws_cloudwatch_event_target.ecs_service_impaired_notification[0],
        ] : alltrue([
          for key in keys(target.input_transformer[0].input_paths) :
          strcontains(target.input_transformer[0].input_template, "<${key}>")
      ])
    ])
    error_message = "Una variable de input_paths no aparece como marcador en la plantilla de ECS: el dato nunca llegara al mensaje."
  }

  # El caso concreto que fallo el 9 de agosto de 2026.
  assert {
    condition     = strcontains(aws_cloudwatch_event_target.database_critical_notification[0].input_transformer[0].input_template, "*Evento:* `<eventId>`")
    error_message = "La alerta critica de RDS debe poder nombrar el EventID que la disparo."
  }
}
