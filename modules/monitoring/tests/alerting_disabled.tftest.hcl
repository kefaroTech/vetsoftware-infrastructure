// Vive en su propio archivo porque alerting.tftest.hcl fija los ARN de los
// topics con override_resource, y aqui los topics no deben existir.

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

run "notifications_stay_off_without_a_channel" {
  command = plan

  variables {
    name                             = "vetsoftware-dev"
    aws_region                       = "us-east-1"
    alarm_email                      = ""
    slack_workspace_id               = ""
    slack_channel_id                 = ""
    budget_sns_notifications_enabled = false
    cost_anomaly_detection_enabled   = false
    monthly_budget_usd               = 0
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

  # Las banderas de eventos estan encendidas y aun asi no debe crearse nada: sin
  # destino, una regla de EventBridge publicaria contra un ARN inexistente y
  # fallaria en cada invocacion sin que nadie se entere.
  assert {
    condition = (
      length(aws_sns_topic.alarms) == 0 &&
      length(aws_sns_topic.alarms_critical) == 0 &&
      length(aws_cloudwatch_event_rule.ecs_task_failed) == 0 &&
      length(aws_cloudwatch_event_rule.ecs_task_stopped) == 0 &&
      length(aws_cloudwatch_event_rule.database_critical) == 0 &&
      length(aws_cloudwatch_composite_alarm.database_saturated) == 0
    )
    error_message = "Sin canal de notificacion no debe crearse ningun circuito que publique en un topic inexistente."
  }

  # Las alarmas de metrica si se crean: sirven en el panel de CloudWatch aunque
  # no tengan a donde notificar.
  assert {
    condition     = length(aws_cloudwatch_metric_alarm.backend_memory_critical.alarm_actions) == 0
    error_message = "Sin topics, las alarmas deben quedar sin acciones en vez de referenciar un ARN que no existe."
  }
}
