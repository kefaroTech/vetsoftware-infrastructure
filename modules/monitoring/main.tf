data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

locals {
  email_notifications_enabled = trimspace(var.alarm_email) != ""
  slack_notifications_enabled = trimspace(var.slack_workspace_id) != "" && trimspace(var.slack_channel_id) != ""
  notification_topic_enabled = (
    local.email_notifications_enabled ||
    local.slack_notifications_enabled ||
    var.budget_sns_notifications_enabled ||
    var.cost_anomaly_detection_enabled
  )
  budget_notifications_enabled = (
    var.monthly_budget_usd > 0 &&
    (local.email_notifications_enabled || var.budget_sns_notifications_enabled)
  )

  # Dos topicos, no uno. Un canal unico obliga a leer el aviso de presupuesto con
  # la misma urgencia que una base que se esta quedando sin disco, y en la
  # practica termina ignorandose entero. `alarm_actions` conserva el nombre
  # anterior porque lo usan las alertas de costo y las advertencias.
  alarm_actions    = local.notification_topic_enabled ? [aws_sns_topic.alarms[0].arn] : []
  critical_actions = local.notification_topic_enabled ? [aws_sns_topic.alarms_critical[0].arn] : []

  # Canal propio para lo critico solo si se pidio uno; si no, ambos topicos
  # entran por la configuracion Slack que ya existe.
  dedicated_critical_channel = local.slack_notifications_enabled && trimspace(var.slack_critical_channel_id) != ""

  # Los interruptores son banderas y no "el ARN viene lleno". Un count que
  # depende del ARN de un cluster que todavia no existe es indecidible en plan:
  # Terraform no puede saber cuantas instancias crear y aborta pidiendo -target.
  # La bandera la fija quien llama, se conoce siempre, y el ARN queda solo como
  # dato del patron de eventos.
  ecs_events_enabled      = var.ecs_events_enabled && local.notification_topic_enabled
  database_events_enabled = var.database_events_enabled && local.notification_topic_enabled
  cache_alarms_enabled    = var.cache_alarms_enabled

  runbook_step           = trimspace(var.runbook_url) != "" ? "Runbook: ${var.runbook_url}" : "Registrar el incidente y su causa raiz en el runbook del entorno"
  backend_log_group_hint = trimspace(var.backend_log_group_name) != "" ? var.backend_log_group_name : "/ecs/${var.ecs_cluster_name}/backend"

  # Los umbrales absolutos se derivan una sola vez para que la alarma, el output
  # y la documentacion no puedan discrepar.
  database_connections_warning_threshold  = floor(var.database_max_connections * var.database_connections_warning_percent / 100)
  database_connections_critical_threshold = floor(var.database_max_connections * var.database_connections_critical_percent / 100)
  database_allocated_storage_bytes        = var.database_allocated_storage_gib * 1024 * 1024 * 1024
  database_free_storage_warning_bytes     = floor(local.database_allocated_storage_bytes * var.database_free_storage_warning_percent / 100)
  database_free_storage_critical_bytes    = floor(local.database_allocated_storage_bytes * var.database_free_storage_critical_percent / 100)

  cache_data_storage_warning_bytes = floor(var.cache_maximum_data_storage_gb * 1024 * 1024 * 1024 * var.cache_utilization_warning_percent / 100)
  # ElastiCacheProcessingUnits se acumula por periodo, mientras que el limite del
  # cache se expresa por segundo: el umbral tiene que multiplicarse por el periodo.
  cache_ecpu_period_seconds     = 300
  cache_ecpu_warning_per_period = floor(var.cache_maximum_ecpu_per_second * local.cache_ecpu_period_seconds * var.cache_utilization_warning_percent / 100)
}

resource "aws_sns_topic" "alarms" {
  count = local.notification_topic_enabled ? 1 : 0

  name              = "${var.name}-alarms"
  kms_master_key_id = trimspace(var.sns_kms_key_arn) != "" ? var.sns_kms_key_arn : null
  tags              = var.tags
}

resource "aws_sns_topic_subscription" "email" {
  count = local.email_notifications_enabled ? 1 : 0

  topic_arn = aws_sns_topic.alarms[0].arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

data "aws_iam_policy_document" "alarms" {
  count = local.notification_topic_enabled ? 1 : 0

  # SNS valida cada accion contra el catalogo permitido en policies de topico y
  # rechaza comodines como SNS:* con "Policy statement action out of service scope".
  statement {
    sid    = "TopicOwnerFullAccess"
    effect = "Allow"
    actions = [
      "SNS:AddPermission",
      "SNS:DeleteTopic",
      "SNS:GetDataProtectionPolicy",
      "SNS:GetTopicAttributes",
      "SNS:ListSubscriptionsByTopic",
      "SNS:ListTagsForResource",
      "SNS:Publish",
      "SNS:PutDataProtectionPolicy",
      "SNS:RemovePermission",
      "SNS:SetTopicAttributes",
      "SNS:Subscribe",
    ]

    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"]
    }

    resources = [aws_sns_topic.alarms[0].arn]
  }

  dynamic "statement" {
    for_each = var.budget_sns_notifications_enabled ? [1] : []

    content {
      sid     = "AWSBudgetsSNSPublishingPermissions"
      effect  = "Allow"
      actions = ["SNS:Publish"]

      principals {
        type        = "Service"
        identifiers = ["budgets.amazonaws.com"]
      }

      resources = [aws_sns_topic.alarms[0].arn]

      condition {
        test     = "StringEquals"
        variable = "aws:SourceAccount"
        values   = [data.aws_caller_identity.current.account_id]
      }

      condition {
        test     = "ArnLike"
        variable = "aws:SourceArn"
        values   = ["arn:${data.aws_partition.current.partition}:budgets::${data.aws_caller_identity.current.account_id}:*"]
      }
    }
  }

  dynamic "statement" {
    for_each = length(var.notification_publisher_role_arns) > 0 ? [1] : []

    content {
      sid     = "NotificationsPublishingPermissions"
      effect  = "Allow"
      actions = ["SNS:Publish"]

      principals {
        type        = "AWS"
        identifiers = var.notification_publisher_role_arns
      }

      resources = [aws_sns_topic.alarms[0].arn]
    }
  }

  dynamic "statement" {
    for_each = var.cost_anomaly_detection_enabled ? [1] : []

    content {
      sid     = "AWSCostAnomalyDetectionSNSPublishingPermissions"
      effect  = "Allow"
      actions = ["SNS:Publish"]

      principals {
        type        = "Service"
        identifiers = ["costalerts.amazonaws.com"]
      }

      resources = [aws_sns_topic.alarms[0].arn]

      condition {
        test     = "StringEquals"
        variable = "aws:SourceAccount"
        values   = [data.aws_caller_identity.current.account_id]
      }
    }
  }

  dynamic "statement" {
    for_each = local.ecs_events_enabled || local.database_events_enabled ? [1] : []

    content {
      sid     = "EventBridgeSNSPublishingPermissions"
      effect  = "Allow"
      actions = ["SNS:Publish"]

      principals {
        type        = "Service"
        identifiers = ["events.amazonaws.com"]
      }

      resources = [aws_sns_topic.alarms[0].arn]

      condition {
        test     = "StringEquals"
        variable = "aws:SourceAccount"
        values   = [data.aws_caller_identity.current.account_id]
      }
    }
  }
}

resource "aws_sns_topic_policy" "alarms" {
  count = local.notification_topic_enabled ? 1 : 0

  arn    = aws_sns_topic.alarms[0].arn
  policy = data.aws_iam_policy_document.alarms[0].json
}

resource "aws_sns_topic" "alarms_critical" {
  count = local.notification_topic_enabled ? 1 : 0

  name              = "${var.name}-alarms-critical"
  kms_master_key_id = trimspace(var.sns_kms_key_arn) != "" ? var.sns_kms_key_arn : null
  tags              = merge(var.tags, { Severity = "critical" })
}

# El correo se suscribe a los dos topicos: quien confirmo la suscripcion espera
# recibir lo urgente, no solo lo informativo.
resource "aws_sns_topic_subscription" "email_critical" {
  count = local.email_notifications_enabled ? 1 : 0

  topic_arn = aws_sns_topic.alarms_critical[0].arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

data "aws_iam_policy_document" "alarms_critical" {
  count = local.notification_topic_enabled ? 1 : 0

  statement {
    sid    = "TopicOwnerFullAccess"
    effect = "Allow"
    actions = [
      "SNS:AddPermission",
      "SNS:DeleteTopic",
      "SNS:GetDataProtectionPolicy",
      "SNS:GetTopicAttributes",
      "SNS:ListSubscriptionsByTopic",
      "SNS:ListTagsForResource",
      "SNS:Publish",
      "SNS:PutDataProtectionPolicy",
      "SNS:RemovePermission",
      "SNS:SetTopicAttributes",
      "SNS:Subscribe",
    ]

    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"]
    }

    resources = [aws_sns_topic.alarms_critical[0].arn]
  }

  dynamic "statement" {
    for_each = local.ecs_events_enabled || local.database_events_enabled ? [1] : []

    content {
      sid     = "EventBridgeSNSPublishingPermissions"
      effect  = "Allow"
      actions = ["SNS:Publish"]

      principals {
        type        = "Service"
        identifiers = ["events.amazonaws.com"]
      }

      resources = [aws_sns_topic.alarms_critical[0].arn]

      condition {
        test     = "StringEquals"
        variable = "aws:SourceAccount"
        values   = [data.aws_caller_identity.current.account_id]
      }
    }
  }
}

resource "aws_sns_topic_policy" "alarms_critical" {
  count = local.notification_topic_enabled ? 1 : 0

  arn    = aws_sns_topic.alarms_critical[0].arn
  policy = data.aws_iam_policy_document.alarms_critical[0].json
}

data "aws_iam_policy_document" "slack_notifications_assume_role" {
  count = local.slack_notifications_enabled ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["chatbot.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "slack_notifications" {
  count = local.slack_notifications_enabled ? 1 : 0

  name               = "${var.name}-slack-notifications"
  description        = "Notification-only role for Amazon Q Developer in Slack"
  assume_role_policy = data.aws_iam_policy_document.slack_notifications_assume_role[0].json
  tags               = var.tags
}

resource "aws_chatbot_slack_channel_configuration" "alarms" {
  count = local.slack_notifications_enabled ? 1 : 0

  configuration_name = "${var.name}-cost-alerts"
  iam_role_arn       = aws_iam_role.slack_notifications[0].arn
  slack_channel_id   = var.slack_channel_id
  slack_team_id      = var.slack_workspace_id
  sns_topic_arns = local.dedicated_critical_channel ? [
    aws_sns_topic.alarms[0].arn,
    ] : [
    aws_sns_topic.alarms[0].arn,
    aws_sns_topic.alarms_critical[0].arn,
  ]
  guardrail_policy_arns       = ["arn:${data.aws_partition.current.partition}:iam::aws:policy/ReadOnlyAccess"]
  logging_level               = "NONE"
  user_authorization_required = true
  tags                        = var.tags
}

resource "aws_chatbot_slack_channel_configuration" "alarms_critical" {
  count = local.dedicated_critical_channel ? 1 : 0

  configuration_name          = "${var.name}-critical-alerts"
  iam_role_arn                = aws_iam_role.slack_notifications[0].arn
  slack_channel_id            = var.slack_critical_channel_id
  slack_team_id               = var.slack_workspace_id
  sns_topic_arns              = [aws_sns_topic.alarms_critical[0].arn]
  guardrail_policy_arns       = ["arn:${data.aws_partition.current.partition}:iam::aws:policy/ReadOnlyAccess"]
  logging_level               = "NONE"
  user_authorization_required = true
  tags                        = merge(var.tags, { Severity = "critical" })
}

resource "aws_cloudwatch_metric_alarm" "alloy_status" {
  for_each = { for index, instance_id in var.alloy_instance_ids : tostring(index) => instance_id }

  alarm_name          = "${var.name}-alloy-${each.value}-status"
  alarm_description   = "EC2 instance status check failed"
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = local.alarm_actions

  dimensions = { InstanceId = each.value }
  tags       = var.tags
}

resource "aws_cloudwatch_metric_alarm" "alloy_recovery" {
  for_each = { for index, instance_id in var.alloy_instance_ids : tostring(index) => instance_id }

  alarm_name          = "${var.name}-alloy-${each.key}-system-recovery"
  alarm_description   = "Recover the EC2 instance after an underlying system failure"
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed_System"
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "missing"
  alarm_actions = concat(local.alarm_actions, [
    "arn:aws:automate:${var.aws_region}:ec2:recover"
  ])

  dimensions = { InstanceId = each.value }
  tags       = var.tags
}

resource "aws_budgets_budget" "monthly" {
  count = var.monthly_budget_usd > 0 ? 1 : 0

  name         = "${var.name}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  dynamic "notification" {
    for_each = local.budget_notifications_enabled ? [80, 100] : []

    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value
      threshold_type             = "PERCENTAGE"
      notification_type          = notification.value == 80 ? "FORECASTED" : "ACTUAL"
      subscriber_email_addresses = var.budget_sns_notifications_enabled ? [] : [var.alarm_email]
      subscriber_sns_topic_arns = var.budget_sns_notifications_enabled ? [
        aws_sns_topic.alarms[0].arn,
      ] : []
    }
  }

  depends_on = [aws_sns_topic_policy.alarms]
}

resource "aws_ce_anomaly_monitor" "services" {
  count = var.cost_anomaly_detection_enabled ? 1 : 0

  name              = "${var.name}-aws-services"
  monitor_type      = "DIMENSIONAL"
  monitor_dimension = "SERVICE"
  tags              = var.tags
}

resource "aws_ce_anomaly_subscription" "immediate" {
  count = var.cost_anomaly_detection_enabled ? 1 : 0

  name             = "${var.name}-cost-anomalies"
  frequency        = "IMMEDIATE"
  monitor_arn_list = [aws_ce_anomaly_monitor.services[0].arn]

  subscriber {
    type    = "SNS"
    address = aws_sns_topic.alarms[0].arn
  }

  threshold_expression {
    dimension {
      key           = "ANOMALY_TOTAL_IMPACT_ABSOLUTE"
      match_options = ["GREATER_THAN_OR_EQUAL"]
      values        = [tostring(var.cost_anomaly_threshold_usd)]
    }
  }

  tags = var.tags

  depends_on = [aws_sns_topic_policy.alarms]
}
