# Envio durable de logs a Grafana Cloud.
#
# La aplicacion exportaba por OTLP directo desde ECS y el unico buffer era la
# cola en memoria del BatchLogRecordProcessor: al llenarse descarta en silencio, y
# al fallar el export hace batch.clear() incondicional. Un 429 sostenido abrio un
# hueco de 50 minutos en Loki con la aplicacion viva y los 310 eventos correctos
# en CloudWatch.
#
# La decision es mover la frontera de durabilidad a CloudWatch Logs -que ya los
# tenia todos- y dejar el ultimo tramo a Firehose, que reintenta durante dos
# horas y deposita en S3 lo que no logre entregar. Lo que antes se perdia ahora
# se retrasa o aterriza en un bucket, y en los dos casos hay una alarma.

data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

locals {
  stream_name    = "${var.name}-logs"
  log_group_name = "/aws/kinesisfirehose/${var.name}-logs"

  backup_bucket_name = (
    var.backup_bucket_name != ""
    ? var.backup_bucket_name
    : "${var.name}-logs-backup-${data.aws_caller_identity.current.account_id}-${data.aws_region.current.region}"
  )

  # Prefijo unico donde aterriza lo que no se pudo entregar. Se declara aqui
  # porque lo usan tres cosas: el stream, la alarma que lo vigila y el output que
  # dice donde mirar cuando la alarma suena.
  error_output_prefix = "errors/!{firehose:error-output-type}/!{timestamp:yyyy/MM/dd}/"

  # Grafana elimina el prefijo lbl_ al almacenar. Sin estos atributos los logs
  # llegan con la etiqueta por defecto del endpoint y todas las consultas que hoy
  # usan service_name=vetsoftware dejan de encontrarlos.
  common_attributes = { for key, value in var.loki_labels : "lbl_${key}" => value }

  warning_actions  = trimspace(var.alarm_topic_arn) != "" ? [var.alarm_topic_arn] : []
  critical_actions = trimspace(var.critical_alarm_topic_arn) != "" ? [var.critical_alarm_topic_arn] : []
}

resource "aws_s3_bucket" "backup" {
  bucket        = local.backup_bucket_name
  force_destroy = var.backup_bucket_force_destroy

  tags = merge(var.tags, { DataClassification = "operational-logs" })
}

resource "aws_s3_bucket_versioning" "backup" {
  bucket = aws_s3_bucket.backup.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "backup" {
  bucket = aws_s3_bucket.backup.id

  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = var.kms_key_arn
      sse_algorithm     = "aws:kms"
    }

    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "backup" {
  bucket = aws_s3_bucket.backup.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "backup" {
  bucket = aws_s3_bucket.backup.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "backup" {
  bucket = aws_s3_bucket.backup.id

  rule {
    id     = "expire-undelivered-logs"
    status = "Enabled"

    filter {}

    expiration {
      days = var.backup_retention_days
    }

    noncurrent_version_expiration {
      noncurrent_days = 7
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

data "aws_iam_policy_document" "backup_bucket" {
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.backup.arn,
      "${aws_s3_bucket.backup.arn}/*",
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "backup" {
  bucket = aws_s3_bucket.backup.id
  policy = data.aws_iam_policy_document.backup_bucket.json
}

# Los fallos del propio Firehose no aparecen en ninguna metrica con detalle
# suficiente para actuar: el cuerpo de la respuesta del endpoint -un 429 con su
# mensaje, un token sin scope- solo sale por aqui.
resource "aws_cloudwatch_log_group" "firehose" {
  name              = local.log_group_name
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn
  tags              = var.tags
}

resource "aws_cloudwatch_log_stream" "http_endpoint" {
  name           = "HttpEndpointDelivery"
  log_group_name = aws_cloudwatch_log_group.firehose.name
}

resource "aws_cloudwatch_log_stream" "s3_backup" {
  name           = "BackupDelivery"
  log_group_name = aws_cloudwatch_log_group.firehose.name
}

data "aws_iam_policy_document" "firehose_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["firehose.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "sts:ExternalId"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_iam_role" "firehose" {
  name_prefix        = "${var.name}-firehose-logs-"
  description        = "Entrega de logs de CloudWatch a Grafana Cloud y a su respaldo en S3"
  assume_role_policy = data.aws_iam_policy_document.firehose_assume.json
  tags               = var.tags
}

data "aws_iam_policy_document" "firehose" {
  statement {
    sid = "BucketMetadata"
    actions = [
      "s3:GetBucketLocation",
      "s3:ListBucket",
      "s3:ListBucketMultipartUploads",
    ]
    resources = [aws_s3_bucket.backup.arn]
  }

  statement {
    sid = "WriteUndeliveredRecords"
    actions = [
      "s3:AbortMultipartUpload",
      "s3:ListMultipartUploadParts",
      "s3:PutObject",
    ]
    resources = ["${aws_s3_bucket.backup.arn}/*"]
  }

  # El bucket de respaldo esta cifrado con la CMK del entorno y Firehose pide la
  # data key con SU identidad, no con la de quien aplica: sin esto la entrega al
  # respaldo falla justo cuando hace falta, que es cuando el endpoint ya fallo.
  statement {
    sid = "UseEnvironmentKey"
    actions = [
      "kms:Decrypt",
      "kms:DescribeKey",
      "kms:GenerateDataKey",
    ]
    resources = [var.kms_key_arn]
  }

  # La clave de acceso del endpoint no viaja en la configuracion del stream:
  # Firehose la resuelve contra Secrets Manager en cada entrega. Asi el token no
  # entra en el codigo, ni en una variable con valor por defecto, ni en el state.
  statement {
    sid       = "ReadEndpointAccessKey"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [var.access_key_secret_arn]
  }

  statement {
    sid       = "WriteDeliveryLogs"
    actions   = ["logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.firehose.arn}:*"]
  }
}

resource "aws_iam_role_policy" "firehose" {
  name   = "deliver-logs-to-grafana-cloud"
  role   = aws_iam_role.firehose.id
  policy = data.aws_iam_policy_document.firehose.json
}

resource "aws_kinesis_firehose_delivery_stream" "logs" {
  name        = local.stream_name
  destination = "http_endpoint"

  http_endpoint_configuration {
    url      = var.endpoint_url
    name     = var.endpoint_name
    role_arn = aws_iam_role.firehose.arn

    # Volumen esperado en dev: ~1,5 GB al mes, es decir menos de un MiB por
    # minuto. Con ese caudal manda el intervalo, no el tamano: 60 segundos deja
    # la latencia hacia Loki por debajo del minuto sin multiplicar peticiones.
    buffering_interval = var.buffering_interval_seconds
    buffering_size     = var.buffering_size_mib

    # Dos horas de reintento, el maximo. El incidente que origino esto fue un 429
    # sostenido: con la cola en memoria de la aplicacion se perdio, con esta
    # ventana se habria absorbido entero.
    retry_duration = var.retry_duration_seconds

    # Solo lo que no se pudo entregar. Duplicar en S3 todo lo entregado costaria
    # almacenamiento por nada: la copia intacta ya vive en CloudWatch Logs.
    s3_backup_mode = "FailedDataOnly"

    secrets_manager_configuration {
      enabled    = true
      secret_arn = var.access_key_secret_arn
      role_arn   = aws_iam_role.firehose.arn
    }

    request_configuration {
      content_encoding = "GZIP"

      dynamic "common_attributes" {
        for_each = local.common_attributes

        content {
          name  = common_attributes.key
          value = common_attributes.value
        }
      }
    }

    s3_configuration {
      role_arn            = aws_iam_role.firehose.arn
      bucket_arn          = aws_s3_bucket.backup.arn
      error_output_prefix = local.error_output_prefix
      buffering_interval  = var.backup_buffering_interval_seconds
      buffering_size      = var.backup_buffering_size_mib
      compression_format  = "GZIP"
      kms_key_arn         = var.kms_key_arn

      cloudwatch_logging_options {
        enabled         = true
        log_group_name  = aws_cloudwatch_log_group.firehose.name
        log_stream_name = aws_cloudwatch_log_stream.s3_backup.name
      }
    }

    cloudwatch_logging_options {
      enabled         = true
      log_group_name  = aws_cloudwatch_log_group.firehose.name
      log_stream_name = aws_cloudwatch_log_stream.http_endpoint.name
    }
  }

  tags = var.tags

  depends_on = [aws_iam_role_policy.firehose]
}

# Proteccion contra el confused deputy acotada al log group concreto, que es la
# forma que usa la plantilla oficial de Grafana Labs. Sin la condicion, cualquier
# log group de la cuenta podria hacer que CloudWatch Logs asumiera este rol y
# empujara hacia este stream.
#
# Se admiten las dos formas del ARN porque el atributo del recurso viene sin
# sufijo y CloudWatch Logs lo presenta a veces con ":*"; las dos designan el
# mismo grupo, y equivocar la forma deja la suscripcion muda sin decir por que.
data "aws_iam_policy_document" "subscription_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["logs.amazonaws.com"]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values = [
        var.source_log_group_arn,
        "${trimsuffix(var.source_log_group_arn, ":*")}:*",
      ]
    }
  }
}

resource "aws_iam_role" "subscription" {
  name_prefix        = "${var.name}-logs-to-firehose-"
  description        = "Rol que usa CloudWatch Logs para empujar la suscripcion hacia Firehose"
  assume_role_policy = data.aws_iam_policy_document.subscription_assume.json
  tags               = var.tags
}

# Sin kms:Decrypt a proposito. El log group esta cifrado con la CMK, pero quien
# descifra es CloudWatch Logs con su propio principal -ya autorizado en la
# politica de la clave-, no este rol: el rol solo empuja el resultado a Firehose.
data "aws_iam_policy_document" "subscription" {
  statement {
    sid = "PushSubscriptionToFirehose"
    actions = [
      "firehose:PutRecord",
      "firehose:PutRecordBatch",
    ]
    resources = [aws_kinesis_firehose_delivery_stream.logs.arn]
  }
}

resource "aws_iam_role_policy" "subscription" {
  name   = "push-backend-logs-to-firehose"
  role   = aws_iam_role.subscription.id
  policy = data.aws_iam_policy_document.subscription.json
}

# filter_pattern vacio: todo. Filtrar aqui reintroduce exactamente el problema
# que se viene a cerrar -decidir en el camino que log sobrevive-, y el volumen de
# dev no lo justifica.
resource "aws_cloudwatch_log_subscription_filter" "backend" {
  name            = "${var.name}-backend-to-grafana-cloud"
  log_group_name  = var.source_log_group_name
  filter_pattern  = var.filter_pattern
  destination_arn = aws_kinesis_firehose_delivery_stream.logs.arn
  role_arn        = aws_iam_role.subscription.arn

  # El valor de la plantilla oficial de Grafana Labs. Agrupa por flujo de origen
  # en vez de repartir al azar, que es lo que conserva el orden relativo de los
  # eventos de una misma tarea al reconstruirlos en Loki.
  distribution = "ByLogStream"

  depends_on = [aws_iam_role_policy.subscription]
}
