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

  # El presupuesto de Bedrock tiene su propia condicion y NO reutiliza la de
  # arriba, aunque el resto sea identico. Reutilizarla ata sus avisos a
  # monthly_budget_usd: poner a cero el presupuesto global -que es la forma
  # documentada de apagarlo- dejaria el presupuesto de Bedrock creado y mudo,
  # que es peor que no tenerlo, porque en la consola se ve.
  bedrock_budget_notifications_enabled = (
    var.bedrock_budget_usd > 0 &&
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

  # Los nombres se declaran una sola vez y el ARN se deriva de ellos en vez de
  # leerse del recurso. Referenciar aws_sns_topic.alarms[0].arn dentro de la
  # policy obliga a Terraform a diferir la lectura del policy document hasta el
  # apply -el ARN no existe antes-, y eso deja la politica como "known after
  # apply" en cada plan: no se puede revisar en el PR ni afirmar sobre ella en un
  # contrato. Derivarla la vuelve visible en el plan.
  alarms_topic_name          = "${var.name}-alarms"
  alarms_critical_topic_name = "${var.name}-alarms-critical"
  events_topic_name          = "${var.name}-events"
  finops_topic_name          = "${var.name}-finops"
  sns_arn_prefix             = "arn:${data.aws_partition.current.partition}:sns:${var.aws_region}:${data.aws_caller_identity.current.account_id}"
  alarms_topic_arn           = "${local.sns_arn_prefix}:${local.alarms_topic_name}"
  alarms_critical_topic_arn  = "${local.sns_arn_prefix}:${local.alarms_critical_topic_name}"
  events_topic_arn           = "${local.sns_arn_prefix}:${local.events_topic_name}"
  finops_topic_arn           = "${local.sns_arn_prefix}:${local.finops_topic_name}"

  # Los topics se separan por tipo de senal, no por severidad: una alarma dice
  # que algo esta mal, un evento dice que algo paso, y un aviso de costo no
  # exige nada hoy. Cada familia tiene su ritmo y mezclarlas hace que la mas
  # frecuente entierre a la mas importante.
  #
  # La severidad sigue partida en dos topics aunque hoy ambos vayan al mismo
  # canal: no cuesta nada y deja mandar lo critico a una guardia mas adelante
  # sin volver a repartir nada.
  #
  # Cada canal vacio cae al canal base, asi que configurar de menos nunca deja
  # una senal sin destino: la manda al canal que ya se estaba leyendo.
  alerts_channel   = trimspace(var.slack_alerts_channel_id) != "" ? var.slack_alerts_channel_id : var.slack_channel_id
  critical_channel = trimspace(var.slack_critical_channel_id) != "" ? var.slack_critical_channel_id : local.alerts_channel
  infra_channel    = trimspace(var.slack_infra_channel_id) != "" ? var.slack_infra_channel_id : var.slack_channel_id
  finops_channel   = var.slack_channel_id

  # Amazon Q admite una configuracion por canal, no una por topic, asi que los
  # topics se agrupan por destino antes de crear nada.
  slack_channels = local.slack_notifications_enabled ? distinct([
    local.alerts_channel,
    local.critical_channel,
    local.infra_channel,
    local.finops_channel,
  ]) : []

  channel_topics = {
    for canal in local.slack_channels : canal => compact([
      canal == local.alerts_channel ? local.alarms_topic_arn : "",
      canal == local.critical_channel ? local.alarms_critical_topic_arn : "",
      canal == local.infra_channel ? local.events_topic_arn : "",
      canal == local.finops_channel ? local.finops_topic_arn : "",
    ])
  }

  # El nombre de la configuracion se arma con las familias que aterrizan en ese
  # canal, para que en la consola de Amazon Q se lea que hace cada una.
  channel_labels = {
    for canal in local.slack_channels : canal => join("-", compact([
      canal == local.alerts_channel ? "alerts" : "",
      canal == local.critical_channel && local.critical_channel != local.alerts_channel ? "critical" : "",
      canal == local.infra_channel ? "infra" : "",
      canal == local.finops_channel ? "finops" : "",
    ]))
  }

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

  name              = local.alarms_topic_name
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

    resources = [local.alarms_topic_arn]
  }

  # Sin esto ninguna alarma avisa. TopicOwnerFullAccess autoriza a la cuenta
  # -principal :root-, pero cuando una alarma se dispara quien publica no es la
  # cuenta: es el service principal cloudwatch.amazonaws.com, que ese statement
  # no cubre. El resultado es una alarma que cambia de estado correctamente y
  # falla en silencio al notificar, con "CloudWatch Alarms is not authorized to
  # perform: SNS:Publish" enterrado en el historial de acciones.
  #
  # Paso exactamente eso en dev: database-low-memory estuvo cuatro dias en ALARM
  # sin que llegara un solo mensaje, mientras el informe de costos y los avisos de
  # despliegue si llegaban -esos publican con roles IAM, que tienen su statement-.
  #
  # Se acota con aws:SourceAccount y no con aws:SourceArn a proposito: una
  # condicion que el servicio no popule reproduce el mismo fallo silencioso que
  # este statement viene a arreglar. La cuenta ya es el limite que importa,
  # porque todas las alarmas de la cuenta son nuestras.
  statement {
    sid     = "CloudWatchAlarmsSNSPublishingPermissions"
    effect  = "Allow"
    actions = ["SNS:Publish"]

    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }

    resources = [local.alarms_topic_arn]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
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

  name              = local.alarms_critical_topic_name
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

    resources = [local.alarms_critical_topic_arn]
  }

  # Mismo motivo que en el topic de advertencia: las alarmas criticas y las
  # compuestas publican como cloudwatch.amazonaws.com, no como la cuenta.
  statement {
    sid     = "CloudWatchAlarmsSNSPublishingPermissions"
    effect  = "Allow"
    actions = ["SNS:Publish"]

    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }

    resources = [local.alarms_critical_topic_arn]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }

  # Los eventos criticos -RDS fuera de servicio, tarea muerta, scheduler que no
  # coloca- entran por aca ademas de las alarmas, asi que EventBridge tambien
  # tiene que poder publicar. Sin este statement el target existe, la regla casa
  # y SNS rechaza el Publish: la notificacion desaparece sin dejar rastro en
  # ningun sitio donde alguien mire.
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

      resources = [local.alarms_critical_topic_arn]

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

# Eventos: lo que paso, no lo que esta mal. Despliegues, apagados programados y
# los eventos de ECS y RDS que EventBridge traduce a Slack.
resource "aws_sns_topic" "events" {
  count = local.notification_topic_enabled ? 1 : 0

  name              = local.events_topic_name
  kms_master_key_id = trimspace(var.sns_kms_key_arn) != "" ? var.sns_kms_key_arn : null
  tags              = merge(var.tags, { Signal = "events" })
}

data "aws_iam_policy_document" "events" {
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

    resources = [local.events_topic_arn]
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

      resources = [local.events_topic_arn]

      condition {
        test     = "StringEquals"
        variable = "aws:SourceAccount"
        values   = [data.aws_caller_identity.current.account_id]
      }
    }
  }

  # Los roles de GitHub publican el aviso de despliegue aca. Se autoriza por
  # policy del topic y no en la policy del rol porque sus inline policies estan
  # cerca del limite de 10.240 caracteres.
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

      resources = [local.events_topic_arn]
    }
  }
}

resource "aws_sns_topic_policy" "events" {
  count = local.notification_topic_enabled ? 1 : 0

  arn    = aws_sns_topic.events[0].arn
  policy = data.aws_iam_policy_document.events[0].json
}

# FinOps: el informe diario, el presupuesto y las anomalias de costo. Trafico
# predecible que no exige nada hoy, y que mezclado con lo operativo se lleva la
# atencion por delante.
resource "aws_sns_topic" "finops" {
  count = local.notification_topic_enabled ? 1 : 0

  name              = local.finops_topic_name
  kms_master_key_id = trimspace(var.sns_kms_key_arn) != "" ? var.sns_kms_key_arn : null
  tags              = merge(var.tags, { Signal = "finops" })
}

resource "aws_sns_topic_subscription" "email_finops" {
  count = local.email_notifications_enabled ? 1 : 0

  topic_arn = aws_sns_topic.finops[0].arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

data "aws_iam_policy_document" "finops" {
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

    resources = [local.finops_topic_arn]
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

      resources = [local.finops_topic_arn]

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
    for_each = var.cost_anomaly_detection_enabled ? [1] : []

    content {
      sid     = "AWSCostAnomalyDetectionSNSPublishingPermissions"
      effect  = "Allow"
      actions = ["SNS:Publish"]

      principals {
        type        = "Service"
        identifiers = ["costalerts.amazonaws.com"]
      }

      resources = [local.finops_topic_arn]

      condition {
        test     = "StringEquals"
        variable = "aws:SourceAccount"
        values   = [data.aws_caller_identity.current.account_id]
      }
    }
  }

  # El informe diario de costos corre con el rol de plan y publica aca.
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

      resources = [local.finops_topic_arn]
    }
  }
}

resource "aws_sns_topic_policy" "finops" {
  count = local.notification_topic_enabled ? 1 : 0

  arn    = aws_sns_topic.finops[0].arn
  policy = data.aws_iam_policy_document.finops[0].json
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

# Una configuracion por canal, con los topics que aterrizan ahi. El for_each va
# sobre canales y no sobre topics porque Amazon Q asocia la configuracion al
# canal: dos configuraciones apuntando al mismo canal se pisan.
resource "aws_chatbot_slack_channel_configuration" "channels" {
  for_each = local.channel_topics

  configuration_name          = "${var.name}-${local.channel_labels[each.key]}"
  iam_role_arn                = aws_iam_role.slack_notifications[0].arn
  slack_channel_id            = each.key
  slack_team_id               = var.slack_workspace_id
  sns_topic_arns              = each.value
  guardrail_policy_arns       = ["arn:${data.aws_partition.current.partition}:iam::aws:policy/ReadOnlyAccess"]
  logging_level               = "NONE"
  user_authorization_required = true
  tags                        = merge(var.tags, { Signals = local.channel_labels[each.key] })
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
        aws_sns_topic.finops[0].arn,
      ] : []
    }
  }

  depends_on = [aws_sns_topic_policy.finops]
}

# Presupuesto propio de Bedrock, y no un umbral mas del global.
#
# aws_budgets_budget.monthly no lleva cost_filter: vigila la cuenta entera y no
# puede distinguir USD 30 de Bedrock de USD 30 de RDS. Cuando salte, ya no se
# sabra quien fue. El gasto de Bedrock no lo decide la infraestructura
# declarada sino el trafico de un endpoint publico sin autenticar, asi que
# necesita su propia linea contable.
#
# Los umbrales son bajos a proposito: sobre una cuenta cuya mayor linea
# individual son USD 5,99 al mes -el Valkey de dev-, USD 10 ya es una anomalia.
# El 50 % y el 80 % son previstos y el 100 % es real: el previsto avisa mientras
# todavia se puede hacer algo.
#
# Va al topic finops, donde ya viven el informe diario y las anomalias de costo,
# y no al de alarmas: esto es contabilidad, no una base quedandose sin disco.
#
# Gratis: AWS Budgets regala los dos primeros presupuestos por cuenta y este es
# el segundo.
resource "aws_budgets_budget" "bedrock" {
  count = var.bedrock_budget_usd > 0 ? 1 : 0

  name         = "${var.name}-bedrock"
  budget_type  = "COST"
  limit_amount = tostring(var.bedrock_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_filter {
    name   = "Service"
    values = ["Amazon Bedrock"]
  }

  dynamic "notification" {
    for_each = local.bedrock_budget_notifications_enabled ? [50, 80, 100] : []

    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value
      threshold_type             = "PERCENTAGE"
      notification_type          = notification.value == 100 ? "ACTUAL" : "FORECASTED"
      subscriber_email_addresses = var.budget_sns_notifications_enabled ? [] : [var.alarm_email]
      subscriber_sns_topic_arns = var.budget_sns_notifications_enabled ? [
        aws_sns_topic.finops[0].arn,
      ] : []
    }
  }

  depends_on = [aws_sns_topic_policy.finops]
}

# Un presupuesto avisa, no corta, y ademas evalua con datos de facturacion que
# llegan con hasta 24 horas de retraso. Contra un abuso que gasta cien dolares
# en una hora, el presupuesto avisaria al dia siguiente.
#
# Esta alarma es lo unico de esta cuenta que ve el gasto de Bedrock en minutos.
# No sustituye al tope de la aplicacion -ese es el unico control que actua ANTES
# de gastar-: es su respaldo, y su umbral esta puesto muy por encima del ritmo
# que ese tope permite. Dicho de otro modo: si esta alarma suena, el tope de la
# aplicacion ha dejado de cortar, o esta invocando alguien que no es la
# aplicacion.
#
# Sin dimension ModelId a proposito: agrega todo el Bedrock de la cuenta. Con un
# solo caso de uso eso es exactamente lo que se quiere, y sobrevive a un cambio
# de modelo sin que nadie se acuerde de mover la alarma.
#
# Sin ok_actions, como el resto del modulo. La higiene de alertas de este
# entorno declara notify_on_recovery = false en el contrato de alertas, y pegar
# un ok_actions aqui dejaria ese contrato mintiendo.
#
# treat_missing_data = "notBreaching" no es el atajo de siempre: en el namespace
# AWS/Bedrock la ausencia de datos significa literalmente que nadie invoco el
# modelo, que es el estado bueno y el normal mientras la palanca este apagada.
resource "aws_cloudwatch_metric_alarm" "bedrock_invocation_surge" {
  count = var.bedrock_budget_usd > 0 ? 1 : 0

  alarm_name          = "${var.name}-bedrock-invocation-surge"
  alarm_description   = "Invocaciones de Bedrock por encima del ritmo que permite el tope de gasto de la aplicacion: el endpoint es publico y quien decide cuanto se gasta es quien manda peticiones."
  namespace           = "AWS/Bedrock"
  metric_name         = "Invocations"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = var.bedrock_invocation_surge_threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.critical_actions
  tags                = var.tags
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
    address = aws_sns_topic.finops[0].arn
  }

  threshold_expression {
    dimension {
      key           = "ANOMALY_TOTAL_IMPACT_ABSOLUTE"
      match_options = ["GREATER_THAN_OR_EQUAL"]
      values        = [tostring(var.cost_anomaly_threshold_usd)]
    }
  }

  tags = var.tags

  depends_on = [aws_sns_topic_policy.finops]
}
