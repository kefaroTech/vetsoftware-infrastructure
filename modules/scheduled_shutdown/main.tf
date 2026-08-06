data "aws_partition" "current" {}

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
}

resource "aws_iam_role_policy" "scheduler" {
  name   = "start-stop-development"
  role   = aws_iam_role.scheduler.id
  policy = data.aws_iam_policy_document.scheduler.json
}

locals {
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
  schedules = {
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
  }
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
