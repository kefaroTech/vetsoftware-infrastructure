// Proveedor real con credenciales falsas, no mock_provider: aws_iam_policy_document
// se resuelve del lado del cliente y no necesita llamar a AWS, pero mock_provider
// lo sustituiria por un documento vacio y no quedaria politica que verificar.
// Las dos data sources que si llamarian a AWS se sustituyen una por una.

provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test-only-access-key"
  secret_key                  = "test-only-secret-key"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_region_validation      = true
  skip_requesting_account_id  = true
}

override_data {
  target = data.aws_caller_identity.current

  values = {
    account_id = "123456789012"
    arn        = "arn:aws:iam::123456789012:user/terraform-test"
    id         = "123456789012"
  }
}

override_data {
  target = data.aws_partition.current

  values = {
    partition  = "aws"
    id         = "aws"
    dns_suffix = "amazonaws.com"
  }
}

// La politica referencia el ARN del topic, que solo existe despues del apply, y
// eso deja el JSON entero indeterminado en plan. Fijar los ARN lo vuelve
// calculable sin crear nada.
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
  budget_sns_notifications_enabled = true
  notification_publisher_role_arns = ["arn:aws:iam::123456789012:role/vetsoftware-iac-apply-dev"]
  cost_anomaly_detection_enabled   = true
  alloy_instance_ids               = []
}

# Regresion con historia. Los dos topics se crearon sin autorizar a
# cloudwatch.amazonaws.com, asi que toda alarma cambiaba de estado y fallaba al
# notificar con "CloudWatch Alarms is not authorized to perform: SNS:Publish",
# enterrado en el historial de acciones donde nadie mira.
#
# Nadie lo noto porque el informe diario de costos y los avisos de despliegue si
# llegaban a Slack -publican con roles IAM, que tienen su propio statement-, y
# eso daba la impresion de que el canal funcionaba. En dev la alarma de memoria
# de RDS estuvo cuatro dias en ALARM sin que saliera un solo mensaje.
#
# La trampa esta en que TopicOwnerFullAccess autoriza al principal :root de la
# cuenta y parece cubrirlo todo. No lo hace: CloudWatch publica como service
# principal, que es una identidad distinta.
run "alarms_are_authorized_to_publish" {
  command = plan

  assert {
    condition = alltrue([
      for policy in [
        data.aws_iam_policy_document.alarms[0].json,
        data.aws_iam_policy_document.alarms_critical[0].json,
        ] : anytrue([
          for statement in jsondecode(policy).Statement : (
            try(statement.Principal.Service, "") == "cloudwatch.amazonaws.com" &&
            contains(flatten([statement.Action]), "SNS:Publish")
          )
      ])
    ])
    error_message = "Los dos topics deben autorizar a cloudwatch.amazonaws.com a publicar; sin eso las alarmas cambian de estado y no notifican a nadie."
  }

  # Acotado a la cuenta. Sin condicion, el topic quedaria abierto a cualquier
  # CloudWatch; con una condicion que el servicio no popule, volveria el mismo
  # fallo silencioso que este statement viene a arreglar.
  assert {
    condition = alltrue([
      for policy in [
        data.aws_iam_policy_document.alarms[0].json,
        data.aws_iam_policy_document.alarms_critical[0].json,
        ] : anytrue([
          for statement in jsondecode(policy).Statement : (
            try(statement.Principal.Service, "") == "cloudwatch.amazonaws.com" &&
            try(statement.Condition.StringEquals["aws:SourceAccount"], "") == "123456789012"
          )
      ])
    ])
    error_message = "El permiso de CloudWatch debe acotarse con aws:SourceAccount a las alarmas de esta cuenta."
  }

  # Los eventos criticos publican en el topic critico, no en el de eventos, asi
  # que EventBridge tiene que estar autorizado en los dos. Si falta el permiso el
  # target existe, la regla casa y SNS rechaza el Publish: la notificacion
  # desaparece sin error visible en ningun sitio. Es el fallo mas caro de todos
  # los posibles aqui, porque se descubre el dia que hacia falta la alerta.
  assert {
    condition = alltrue([
      for policy in [
        data.aws_iam_policy_document.events[0].json,
        data.aws_iam_policy_document.alarms_critical[0].json,
        ] : anytrue([
          for statement in jsondecode(policy).Statement : (
            try(statement.Principal.Service, "") == "events.amazonaws.com" &&
            contains(flatten([statement.Action]), "SNS:Publish") &&
            try(statement.Condition.StringEquals["aws:SourceAccount"], "") == "123456789012"
          )
      ])
    ])
    error_message = "El topic de eventos y el critico deben autorizar a events.amazonaws.com acotado a la cuenta; sin eso EventBridge publica al vacio."
  }

  # Cada publicador tiene que quedar en el topic de su familia. Si Budgets sigue
  # autorizado en el topic de alarmas, el informe de costos vuelve a caer en el
  # canal de alertas, que es justo lo que la separacion viene a evitar.
  assert {
    condition = alltrue([
      for servicio in ["budgets.amazonaws.com", "costalerts.amazonaws.com"] : anytrue([
        for statement in jsondecode(data.aws_iam_policy_document.finops[0].json).Statement :
        try(statement.Principal.Service, "") == servicio
      ])
    ])
    error_message = "El topic de costos debe autorizar a Budgets y a Cost Anomaly Detection."
  }

  assert {
    condition = anytrue([
      for statement in jsondecode(data.aws_iam_policy_document.events[0].json).Statement :
      try(statement.Principal.Service, "") == "events.amazonaws.com"
    ])
    error_message = "El topic de eventos debe autorizar a EventBridge."
  }

  # Los roles de GitHub publican el aviso de despliegue y el informe diario. Sin
  # su statement en el topic correcto, ambos vuelven a fallar con AccessDenied.
  assert {
    condition = alltrue([
      for policy in [
        data.aws_iam_policy_document.events[0].json,
        data.aws_iam_policy_document.finops[0].json,
        ] : anytrue([
          for statement in jsondecode(policy).Statement :
          try(contains(flatten([statement.Principal.AWS]), "arn:aws:iam::123456789012:role/vetsoftware-iac-apply-dev"), false)
      ])
    ])
    error_message = "Los roles publicadores deben estar autorizados en los topics de eventos y de costos."
  }

  # Las alarmas no publican avisos de costo ni de despliegue: su topic solo debe
  # aceptar a CloudWatch y a la cuenta.
  assert {
    condition = alltrue([
      for statement in jsondecode(data.aws_iam_policy_document.alarms[0].json).Statement :
      try(statement.Principal.Service, "cloudwatch.amazonaws.com") == "cloudwatch.amazonaws.com"
    ])
    error_message = "El topic de alarmas no debe autorizar publicadores de otras familias."
  }
}
