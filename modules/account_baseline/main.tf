
locals {
  trail_arn = "arn:${var.aws_partition}:cloudtrail:${var.aws_region}:${var.aws_account_id}:trail/${var.name}"

  # Los nombres y ARN se arman aqui en vez de leerse del recurso. El atributo
  # arn de un bucket nuevo no se conoce hasta el apply, y eso dejaria las dos
  # politicas opacas en plan: no se podrian contrastar sin crear nada.
  trail_bucket_name       = "${var.name}-cloudtrail-${var.aws_account_id}"
  access_logs_bucket_name = "${var.name}-s3-access-logs-${var.aws_account_id}"
  trail_bucket_arn        = "arn:${var.aws_partition}:s3:::${local.trail_bucket_name}"
  access_logs_bucket_arn  = "arn:${var.aws_partition}:s3:::${local.access_logs_bucket_name}"
}

# Linea base de trazabilidad de la CUENTA. Cada cuenta necesita la suya: el
# rastro, el detector y el analizador son singletons de cuenta, y dev y prod
# viven en cuentas separadas.
#
# Todo lo que este modulo activa por defecto es gratuito:
#
#   CloudTrail, primer trail, management events .... sin cargo
#   S3 server access logging ....................... sin cargo por evento
#   IAM Access Analyzer ............................ sin cargo
#
# Lo unico que se paga es el almacenamiento en S3 de lo que se escribe, que para
# esta cuenta son megabytes. Lo que si cuesta -GuardDuty y los data events de
# CloudTrail- queda apagado por defecto y documentado en las variables.

# ---------- Bucket de evidencia, inmutable -----------------------------------
resource "aws_s3_bucket" "trail" {
  bucket              = local.trail_bucket_name
  object_lock_enabled = true
  force_destroy       = false

  lifecycle {
    prevent_destroy = true
  }

  tags = merge(var.tags, { DataClassification = "audit" })
}

resource "aws_s3_bucket_versioning" "trail" {
  bucket = aws_s3_bucket.trail.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Usa la CMK del entorno en lugar de crear una propia: una clave son USD 1 al
# mes y el objetivo es no anadir coste. La contrapartida hay que tenerla
# presente: si el entorno se destruye y su CMK con el, los objetos ya escritos
# quedan ilegibles aunque el bucket sobreviva. El bucket key reduce ademas las
# llamadas a KMS a practicamente cero.
resource "aws_s3_bucket_server_side_encryption_configuration" "trail" {
  bucket = aws_s3_bucket.trail.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }

    bucket_key_enabled = true
  }
}

# COMPLIANCE y no GOVERNANCE: el modo que nadie puede levantar, ni el root de la
# cuenta. Una evidencia que el administrador comprometido puede borrar no
# acredita nada.
resource "aws_s3_bucket_object_lock_configuration" "trail" {
  bucket = aws_s3_bucket.trail.id

  rule {
    default_retention {
      mode = "COMPLIANCE"
      days = var.trail_retention_days
    }
  }

  depends_on = [aws_s3_bucket_versioning.trail]
}

resource "aws_s3_bucket_public_access_block" "trail" {
  bucket                  = aws_s3_bucket.trail.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "trail" {
  bucket = aws_s3_bucket.trail.id

  rule {
    id     = "archive-trail"
    status = "Enabled"

    filter {}

    transition {
      days          = 90
      storage_class = "GLACIER"
    }
  }

  depends_on = [aws_s3_bucket_versioning.trail]
}

data "aws_iam_policy_document" "trail_bucket" {
  statement {
    sid    = "AWSCloudTrailAclCheck"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    actions   = ["s3:GetBucketAcl"]
    resources = [local.trail_bucket_arn]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [local.trail_arn]
    }
  }

  statement {
    sid    = "AWSCloudTrailWrite"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    actions   = ["s3:PutObject"]
    resources = ["${local.trail_bucket_arn}/AWSLogs/${var.aws_account_id}/*"]

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [local.trail_arn]
    }
  }

  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions   = ["s3:*"]
    resources = [local.trail_bucket_arn, "${local.trail_bucket_arn}/*"]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "trail" {
  bucket = aws_s3_bucket.trail.id
  policy = data.aws_iam_policy_document.trail_bucket.json
}

# ---------- CloudTrail --------------------------------------------------------
resource "aws_cloudtrail" "this" {
  name                          = var.name
  s3_bucket_name                = aws_s3_bucket.trail.id
  is_multi_region_trail         = true
  include_global_service_events = true
  kms_key_id                    = var.kms_key_arn

  # Sin esto el propio registro es repudiable: los digests firmados son lo que
  # permite demostrar que nadie edito ni borro un archivo del rastro.
  enable_log_file_validation = true

  # El primer trail de la cuenta entrega una copia de los management events sin
  # cargo. Un segundo trail ya se factura, asi que este es el unico.
  advanced_event_selector {
    name = "Management events"

    field_selector {
      field  = "eventCategory"
      equals = ["Management"]
    }
  }

  # Los data events son la version de pago de la misma pregunta que responde el
  # access logging de S3, con mas detalle y en minutos en vez de horas. Apagado
  # por defecto: se activa cuando el caso lo justifique y asumiendo el cargo.
  dynamic "advanced_event_selector" {
    for_each = var.enable_s3_data_events && length(var.regulated_bucket_arns) > 0 ? [1] : []

    content {
      name = "S3 data events on regulated buckets"

      field_selector {
        field  = "eventCategory"
        equals = ["Data"]
      }

      field_selector {
        field  = "resources.type"
        equals = ["AWS::S3::Object"]
      }

      field_selector {
        field       = "resources.ARN"
        starts_with = var.regulated_bucket_arns
      }
    }
  }

  tags = var.tags

  depends_on = [aws_s3_bucket_policy.trail]
}

# ---------- Destino del access logging de S3 ----------------------------------
# Aqui esta la respuesta gratuita a "quien descargo este documento". S3 entrega
# estos registros sin cargo por evento; solo se paga el almacenamiento, y el
# lifecycle lo acota. No sustituye a los data events -es best effort y llega en
# horas- pero es lo que convierte el acceso a datos personales en algo
# reconstruible sin factura.
resource "aws_s3_bucket" "access_logs" {
  bucket        = local.access_logs_bucket_name
  force_destroy = false

  tags = merge(var.tags, { DataClassification = "audit" })
}

resource "aws_s3_bucket_versioning" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id

  versioning_configuration {
    status = "Enabled"
  }
}

# AES256 y no la CMK: S3 no entrega access logs a un destino cifrado con
# SSE-KMS. Es una limitacion del servicio, no una decision.
resource "aws_s3_bucket_server_side_encryption_configuration" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }

    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "access_logs" {
  bucket                  = aws_s3_bucket.access_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id

  rule {
    id     = "expire-access-logs"
    status = "Enabled"

    filter {}

    expiration {
      days = var.access_log_retention_days
    }

    noncurrent_version_expiration {
      noncurrent_days = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.access_logs]
}

data "aws_iam_policy_document" "access_logs_bucket" {
  # El servicio de logging escribe con su propia identidad desde que las ACL
  # estan desaconsejadas; la condicion de SourceAccount evita que un tercero
  # dirija sus registros a este bucket y los pague esta cuenta.
  statement {
    sid    = "AllowS3ServerAccessLogging"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["logging.s3.amazonaws.com"]
    }

    actions   = ["s3:PutObject"]
    resources = ["${local.access_logs_bucket_arn}/*"]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.aws_account_id]
    }
  }

  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions   = ["s3:*"]
    resources = [local.access_logs_bucket_arn, "${local.access_logs_bucket_arn}/*"]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id
  policy = data.aws_iam_policy_document.access_logs_bucket.json
}

# ---------- GuardDuty ---------------------------------------------------------
# Apagado por defecto por coste. Es la pieza que falta para detectar lo anomalo
# -exfiltracion, credenciales usadas desde IPs inusuales, acceso directo a RDS-;
# el resto de este modulo registra, pero no detecta.
resource "aws_guardduty_detector" "this" {
  count = var.enable_guardduty ? 1 : 0

  enable                       = true
  finding_publishing_frequency = "FIFTEEN_MINUTES"
  tags                         = var.tags
}

resource "aws_guardduty_detector_feature" "rds_login" {
  count = var.enable_guardduty ? 1 : 0

  detector_id = aws_guardduty_detector.this[0].id
  name        = "RDS_LOGIN_EVENTS"
  status      = "ENABLED"
}

# Los hallazgos entran por el topic que ya escucha Amazon Q en Slack. Sin topic
# el circuito no se crea en lugar de fallar: un detector sin ruteo sigue siendo
# mejor que ninguno.
resource "aws_cloudwatch_event_rule" "guardduty" {
  count = var.enable_guardduty && var.alarm_topic_arn != null ? 1 : 0

  name        = "${var.name}-guardduty-findings"
  description = "Hallazgos GuardDuty de severidad media o superior"

  event_pattern = jsonencode({
    source      = ["aws.guardduty"]
    detail-type = ["GuardDuty Finding"]
    detail      = { severity = [{ numeric = [">=", 4] }] }
  })

  tags = var.tags
}

resource "aws_cloudwatch_event_target" "guardduty" {
  count = var.enable_guardduty && var.alarm_topic_arn != null ? 1 : 0

  rule      = aws_cloudwatch_event_rule.guardduty[0].name
  target_id = "alarm-topic"
  arn       = var.alarm_topic_arn
}

# ---------- IAM Access Analyzer -----------------------------------------------
# Gratuito. Avisa de cualquier recurso accesible desde fuera de la cuenta.
resource "aws_accessanalyzer_analyzer" "account" {
  count = var.enable_access_analyzer ? 1 : 0

  analyzer_name = "${var.name}-account"
  type          = "ACCOUNT"
  tags          = var.tags
}
