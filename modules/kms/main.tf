data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

data "aws_iam_policy_document" "this" {
  statement {
    sid    = "EnableAccountAdministration"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"]
    }

    actions   = ["kms:*"]
    resources = ["*"]
  }

  statement {
    sid    = "AllowCloudWatchLogsEncryption"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["logs.${data.aws_region.current.region}.amazonaws.com"]
    }

    actions = [
      "kms:Decrypt*",
      "kms:Describe*",
      "kms:Encrypt*",
      "kms:GenerateDataKey*",
      "kms:ReEncrypt*",
    ]
    resources = ["*"]

    condition {
      test     = "ArnLike"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values   = ["arn:${data.aws_partition.current.partition}:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:*"]
    }
  }

  # El rastro de la cuenta cifra sus archivos con esta clave. CloudTrail no usa la
  # identidad de quien crea el trail: pide la data key con la suya propia, asi
  # que sin este statement CreateTrail falla con
  # InsufficientEncryptionPolicyException aunque el rol de apply tenga todos los
  # permisos de CloudTrail y del bucket. El mensaje nombra el bucket Y la clave,
  # lo que despista: lo que falta es el permiso sobre la clave.
  #
  # SourceArn acota a los trails de esta cuenta y region, de modo que ningun
  # trail ajeno pueda pedirle a esta clave que cifre por el.
  statement {
    sid    = "AllowCloudTrailEncryption"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    actions = [
      "kms:DescribeKey",
      "kms:GenerateDataKey*",
    ]
    resources = ["*"]

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:${data.aws_partition.current.partition}:cloudtrail:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:trail/*"]
    }
  }

  dynamic "statement" {
    for_each = var.cost_alerts_sns_enabled ? [1] : []

    content {
      sid    = "AllowCloudWatchAlarmEncryption"
      effect = "Allow"

      principals {
        type        = "Service"
        identifiers = ["cloudwatch.amazonaws.com"]
      }

      actions = [
        "kms:Decrypt",
        "kms:GenerateDataKey*",
      ]
      resources = ["*"]

      condition {
        test     = "StringEquals"
        variable = "aws:SourceAccount"
        values   = [data.aws_caller_identity.current.account_id]
      }

      condition {
        test     = "ArnLike"
        variable = "aws:SourceArn"
        values   = ["arn:${data.aws_partition.current.partition}:cloudwatch:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:alarm:*"]
      }
    }
  }

  dynamic "statement" {
    for_each = var.cost_alerts_sns_enabled ? [1] : []

    content {
      sid    = "AllowAWSBudgetsAlertEncryption"
      effect = "Allow"

      principals {
        type        = "Service"
        identifiers = ["budgets.amazonaws.com"]
      }

      actions = [
        "kms:Decrypt",
        "kms:GenerateDataKey*",
      ]
      resources = ["*"]

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
    for_each = length(var.sns_publisher_role_arns) > 0 ? [1] : []

    content {
      sid    = "AllowDeploymentNotificationEncryption"
      effect = "Allow"

      principals {
        type        = "AWS"
        identifiers = var.sns_publisher_role_arns
      }

      actions = [
        "kms:Decrypt",
        "kms:GenerateDataKey*",
      ]
      resources = ["*"]

      # Acotado a SNS: la clave cifra tambien datos de la aplicacion, y publicar un
      # aviso no es motivo para poder descifrarlos.
      condition {
        test     = "StringEquals"
        variable = "kms:ViaService"
        values   = ["sns.${data.aws_region.current.region}.amazonaws.com"]
      }
    }
  }

  # EventBridge publica los eventos de ECS y RDS en un topic cifrado con esta
  # clave. Sin permiso de GenerateDataKey la regla coincide, el target se ejecuta
  # y la publicacion falla en silencio: el evento se pierde sin dejar error
  # visible en ningun lado salvo la metrica FailedInvocations de la regla.
  dynamic "statement" {
    for_each = var.event_notifications_sns_enabled ? [1] : []

    content {
      sid    = "AllowEventBridgeAlertEncryption"
      effect = "Allow"

      principals {
        type        = "Service"
        identifiers = ["events.amazonaws.com"]
      }

      actions = [
        "kms:Decrypt",
        "kms:GenerateDataKey*",
      ]
      resources = ["*"]

      condition {
        test     = "StringEquals"
        variable = "aws:SourceAccount"
        values   = [data.aws_caller_identity.current.account_id]
      }

      condition {
        test     = "StringEquals"
        variable = "kms:ViaService"
        values   = ["sns.${data.aws_region.current.region}.amazonaws.com"]
      }
    }
  }

  dynamic "statement" {
    for_each = var.cost_alerts_sns_enabled ? [1] : []

    content {
      sid    = "AllowCostAnomalyAlertEncryption"
      effect = "Allow"

      principals {
        type        = "Service"
        identifiers = ["costalerts.amazonaws.com"]
      }

      actions = [
        "kms:Decrypt",
        "kms:GenerateDataKey*",
      ]
      resources = ["*"]

      condition {
        test     = "StringEquals"
        variable = "aws:SourceAccount"
        values   = [data.aws_caller_identity.current.account_id]
      }
    }
  }
}

resource "aws_kms_key" "this" {
  description             = "CMK for ${var.name} application data and operational logs"
  deletion_window_in_days = var.deletion_window_in_days
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.this.json

  tags = merge(var.tags, { Name = "${var.name}-data" })
}

resource "aws_kms_alias" "this" {
  name          = "alias/${var.name}-data"
  target_key_id = aws_kms_key.this.key_id
}
