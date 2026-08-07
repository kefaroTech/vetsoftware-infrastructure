data "aws_partition" "current" {}

data "aws_region" "current" {}

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "scheduler" {
  name_prefix        = "${var.name}-scheduler-"
  assume_role_policy = data.aws_iam_policy_document.assume.json
  tags               = var.tags
}

data "aws_iam_policy_document" "scheduler" {
  statement {
    sid       = "ScaleDevelopmentBackend"
    actions   = ["ecs:UpdateService"]
    resources = [var.ecs_service_arn]
  }

  # Solo detener: el encendido es manual -workflow "Start dev environment"- y el
  # scheduler no tiene por que poder arrancar la base.
  statement {
    sid       = "StopDevelopmentDatabase"
    actions   = ["rds:StopDBInstance"]
    resources = [var.database_arn]
  }

  # Publicar el aviso no necesita nada en la policy del topic ni en la de la CMK:
  # ambas delegan en IAM al principal root de la cuenta -"TopicOwnerFullAccess" y
  # "EnableAccountAdministration"-, asi que con este permiso de identidad alcanza.
  dynamic "statement" {
    for_each = local.stop_notice_enabled ? [1] : []

    content {
      sid       = "AnnounceScheduledShutdown"
      actions   = ["sns:Publish"]
      resources = [var.notification_topic_arn]
    }
  }

  # SNS pide la data key con la identidad de quien publica: sin permiso sobre la
  # CMK que cifra el topic, el aviso muere con un AccessDenied de KMS.
  dynamic "statement" {
    for_each = local.stop_notice_enabled && trimspace(var.notification_kms_key_arn) != "" ? [1] : []

    content {
      sid       = "EncryptScheduledShutdownNotice"
      actions   = ["kms:Decrypt", "kms:GenerateDataKey*"]
      resources = [var.notification_kms_key_arn]

      condition {
        test     = "StringEquals"
        variable = "kms:ViaService"
        values   = ["sns.${data.aws_region.current.region}.amazonaws.com"]
      }
    }
  }
}

resource "aws_iam_role_policy" "scheduler" {
  name   = "start-stop-development"
  role   = aws_iam_role.scheduler.id
  policy = data.aws_iam_policy_document.scheduler.json
}

locals {
  # El aviso se enciende con una bandera y no mirando el ARN del topic: en el
  # primer plan ese ARN todavia no existe, y una clave de for_each que depende de
  # un valor desconocido aborta el plan entero. Que el ARN venga cuando la bandera
  # esta encendida lo garantiza la validacion de notification_topic_arn.
  stop_notice_enabled = var.stop_notice_enabled

  # "cron(0 20 ? * MON-FRI *)" -> "20:00". Un horario que nadie tiene que traducir
  # vale mas que la expresion cruda, pero si alguien configura un rate() o un cron
  # con listas, se cae a mostrar la expresion tal cual.
  schedule_times = {
    for key, expression in {
      backend  = var.backend_stop_schedule
      database = var.database_stop_schedule
      } : key => try(
      format(
        "%02d:%02d",
        tonumber(regex("^cron\\((\\d{1,2}) (\\d{1,2}) ", expression)[1]),
        tonumber(regex("^cron\\((\\d{1,2}) (\\d{1,2}) ", expression)[0]),
      ),
      expression,
    )
  }

  # El formato de las "custom notifications" de Amazon Q -version, source y
  # content-, lo unico que ese integrador acepta de un emisor propio. Es el mismo
  # canal por el que ya sale el aviso de despliegue: ni un webhook nuevo ni un
  # secreto mas que rotar.
  stop_notice_payload = {
    version = "1.0"
    source  = "custom"
    content = {
      textType = "client-markdown"
      title    = ":new_moon: Apagado programado del ambiente ${var.name}"
      description = join("\n", [
        "*Servicio:* `${var.ecs_service_name}` a 0 tareas (${local.schedule_times.backend} ${var.schedule_timezone})",
        "*Base:* `${var.database_identifier}` se detiene a las ${local.schedule_times.database}",
        "_Para volver a encenderlo, ejecute el workflow *Start dev environment*._",
      ])
    }
  }

  # Un solo aviso por apagado, a la hora en que se van las tareas: es el momento en
  # que el ambiente deja de responder. La base cae minutos despues y el mismo
  # mensaje ya lo dice, asi que un segundo aviso solo seria ruido nocturno.
  stop_notice_schedule = local.stop_notice_enabled ? {
    stop-notice = {
      expression = var.backend_stop_schedule
      target_arn = "arn:${data.aws_partition.current.partition}:scheduler:::aws-sdk:sns:publish"
      input = {
        TopicArn = var.notification_topic_arn
        # El payload viaja como texto dentro del campo Message: SNS transporta una
        # cadena, y es Amazon Q quien la vuelve a interpretar como JSON.
        Message = jsonencode(local.stop_notice_payload)
      }
    }
  } : {}

  # Solo apagado: el ambiente se enciende a voluntad con el workflow "Start dev
  # environment", asi que nada lo levanta por hora. El apagado si queda programado,
  # que es lo que protege el gasto cuando alguien olvida bajarlo.
  #
  # Los targets universales nombran los campos con la convencion del SDK de Java v2,
  # que no repite mayusculas consecutivas: el campo es DbInstanceIdentifier, no
  # DBInstanceIdentifier como lo llama la API de RDS. Con el nombre equivocado el
  # campo se ignora y CreateSchedule falla con "Request payload is missing the
  # following field(s): DbInstanceIdentifier". Los targets de ECS no lo sufren
  # porque Cluster, Service y DesiredCount ya casan con esa convencion.
  schedules = merge(local.stop_notice_schedule, {
    backend-stop = {
      expression = var.backend_stop_schedule
      target_arn = "arn:${data.aws_partition.current.partition}:scheduler:::aws-sdk:ecs:updateService"
      input = {
        Cluster      = var.ecs_cluster_arn
        Service      = var.ecs_service_name
        DesiredCount = 0
      }
    }
    database-stop = {
      expression = var.database_stop_schedule
      target_arn = "arn:${data.aws_partition.current.partition}:scheduler:::aws-sdk:rds:stopDBInstance"
      input = {
        DbInstanceIdentifier = var.database_identifier
      }
    }
  })
}

resource "aws_scheduler_schedule" "this" {
  for_each = local.schedules

  name                         = "${var.name}-${each.key}"
  description                  = "Ahorro programado de recursos de desarrollo"
  schedule_expression          = each.value.expression
  schedule_expression_timezone = var.schedule_timezone
  state                        = var.enabled ? "ENABLED" : "DISABLED"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = each.value.target_arn
    role_arn = aws_iam_role.scheduler.arn
    input    = jsonencode(each.value.input)

    retry_policy {
      maximum_event_age_in_seconds = 60
      maximum_retry_attempts       = 0
    }
  }
}
