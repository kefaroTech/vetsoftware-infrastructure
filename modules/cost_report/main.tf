# Informe diario de costos, con reloj de AWS.
#
# Antes lo disparaba un cron de GitHub Actions. Los eventos programados de GitHub
# no estan garantizados: se encolan en un pool compartido y se retrasan bajo
# carga. Medido en este repositorio, el informe y el drift llegaban entre dos y
# seis horas tarde TODOS los dias -el drift, programado a las 11:17 UTC, disparo
# a las 13:54, 14:40, 17:24, 17:05, 17:23 y 17:30 en seis dias seguidos-.
#
# EventBridge Scheduler cumple el horario, como ya demuestra el apagado
# programado de dev. Mover solo el reloj habria exigido un token de GitHub con
# permiso de escritura guardado en AWS, es decir, una credencial de larga vida en
# un proyecto que monto todo el OIDC para no tener ninguna. Por eso se movio
# tambien la logica: aqui no hace falta credencial.

locals {
  log_group_name = "/aws/lambda/${var.name}"

  # Se arma en vez de leerse del recurso: el atributo arn de un log group nuevo
  # no se conoce hasta el apply, y eso dejaria la politica opaca en plan, sin
  # poder contrastarla sin crear nada.
  log_group_arn = "arn:${var.aws_partition}:logs:${var.aws_region}:${var.aws_account_id}:log-group:${local.log_group_name}"
}

data "archive_file" "source" {
  type        = "zip"
  source_dir  = "${path.module}/src"
  output_path = "${path.module}/.terraform-build/cost-report.zip"
}

resource "aws_cloudwatch_log_group" "this" {
  name              = local.log_group_name
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn
  tags              = var.tags
}

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  name_prefix        = "${var.name}-"
  assume_role_policy = data.aws_iam_policy_document.assume.json
  tags               = var.tags
}

data "aws_iam_policy_document" "this" {
  # Cost Explorer no admite acotar por recurso: sus acciones solo aceptan "*".
  # Se concede unicamente la lectura que el informe usa, y cuesta USD 0.01 por
  # request, asi que el permiso habilita un gasto de ~USD 0.30 al mes.
  statement {
    sid       = "ReadDailyCost"
    actions   = ["ce:GetCostAndUsage"]
    resources = ["*"]
  }

  statement {
    sid       = "PublishCostReport"
    actions   = ["sns:Publish"]
    resources = [var.topic_arn]
  }

  # El topic esta cifrado con la CMK del entorno: publicar exige poder pedirle
  # una data key. Acotado a SNS para que este rol no pueda descifrar lo demas que
  # esa clave protege.
  statement {
    sid       = "EncryptCostReport"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey*"]
    resources = [var.kms_key_arn]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["sns.${var.aws_region}.amazonaws.com"]
    }
  }

  # El log group lo crea Terraform con su retencion y su CMK; la Lambda solo
  # escribe en el. Sin CreateLogGroup, si alguien borra el grupo el fallo se ve
  # en lugar de recrearse uno sin caducidad ni cifrado.
  statement {
    sid       = "WriteOwnLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${local.log_group_arn}:*"]
  }
}

resource "aws_iam_role_policy" "this" {
  name   = "cost-report"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.this.json
}

resource "aws_lambda_function" "this" {
  function_name = var.name
  description   = "Informe diario del gasto de la cuenta, publicado en Slack"

  role             = aws_iam_role.this.arn
  filename         = data.archive_file.source.output_path
  source_code_hash = data.archive_file.source.output_base64sha256

  runtime = "python3.13"
  handler = "cost_report.handler"
  # arm64 cuesta menos que x86 y el informe no depende de la arquitectura.
  architectures = ["arm64"]

  # El trabajo es una llamada a Cost Explorer y una publicacion: memoria minima
  # sobra. El timeout cubre un Cost Explorer lento sin dejar la funcion colgada.
  memory_size = 128
  timeout     = 60

  environment {
    variables = {
      TOPIC_ARN  = var.topic_arn
      ACCOUNT_ID = var.aws_account_id
    }
  }

  # Sin esto la primera invocacion puede crear el log group por su cuenta, sin
  # retencion ni CMK, y Terraform quedaria peleando con un recurso ya existente.
  depends_on = [aws_cloudwatch_log_group.this]

  tags = var.tags
}

# ---------- El reloj -----------------------------------------------------------
data "aws_iam_policy_document" "scheduler_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }

    # Sin esta condicion, cualquier schedule de la cuenta podria asumir el rol.
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.aws_account_id]
    }
  }
}

resource "aws_iam_role" "scheduler" {
  name_prefix        = "${var.name}-scheduler-"
  assume_role_policy = data.aws_iam_policy_document.scheduler_assume.json
  tags               = var.tags
}

data "aws_iam_policy_document" "scheduler" {
  statement {
    sid       = "InvokeCostReport"
    actions   = ["lambda:InvokeFunction"]
    resources = [aws_lambda_function.this.arn]
  }
}

resource "aws_iam_role_policy" "scheduler" {
  name   = "invoke-cost-report"
  role   = aws_iam_role.scheduler.id
  policy = data.aws_iam_policy_document.scheduler.json
}

resource "aws_scheduler_schedule" "this" {
  name                         = var.name
  description                  = "Informe diario del gasto de la cuenta"
  schedule_expression          = var.schedule_expression
  schedule_expression_timezone = var.schedule_timezone
  state                        = var.enabled ? "ENABLED" : "DISABLED"

  # OFF y no una ventana flexible: la puntualidad es el motivo de existir de este
  # scheduler. Una ventana devolveria el problema que se venia a resolver.
  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.this.arn
    role_arn = aws_iam_role.scheduler.arn

    # Vacio: la Lambda toma hoy en UTC como referencia. Un as_of solo se pasa al
    # invocarla a mano para reenviar un dia que no salio.
    input = jsonencode({})

    # Sin reintentos. Si el informe de hoy falla, el de manana lo cubre igual, y
    # reintentar una consulta que se factura por request no compensa.
    retry_policy {
      maximum_event_age_in_seconds = 300
      maximum_retry_attempts       = 0
    }
  }
}
