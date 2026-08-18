# Alarmas del envio de logs.
#
# El hueco de 50 minutos no fue invisible por falta de datos: fue invisible
# porque nadie vigilaba el tramo. Estas tres alarmas cubren las tres formas en
# que este camino puede fallar, y ninguna de ellas se nota mirando la aplicacion.
#
# treat_missing_data es "notBreaching" en todas, igual que en el resto del
# entorno: dev se apaga cada noche y sin trafico Firehose no publica metrica. Una
# alarma que lea "sin datos" como falla se convierte en una pagina diaria.

# 1. Entregas que fallan. Success es la proporcion de intentos aceptados por el
#    endpoint: por debajo de 1 hay registros rebotando -token sin scope, 429,
#    endpoint del stack equivocado-. Es la senal directa del incidente original.
resource "aws_cloudwatch_metric_alarm" "delivery_failing" {
  alarm_name          = "${var.name}-logs-delivery-failing"
  alarm_description   = "CRITICO · Firehose no logra entregar logs a Grafana Cloud. Revise ${local.log_group_name}, flujo ${aws_cloudwatch_log_stream.http_endpoint.name}: ahi esta la respuesta del endpoint."
  namespace           = "AWS/Firehose"
  metric_name         = "DeliveryToHttpEndpoint.Success"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.critical_actions
  ok_actions          = local.critical_actions

  dimensions = {
    DeliveryStreamName = aws_kinesis_firehose_delivery_stream.logs.name
  }

  tags = merge(var.tags, { Severity = "critical" })
}

# 2. Datos en el prefijo de error del bucket. Con s3_backup_mode FailedDataOnly
#    lo unico que Firehose escribe en S3 son los registros que agoto reintentando,
#    asi que DeliveryToS3.Records mayor que cero equivale a "hay objetos nuevos
#    bajo el prefijo de error". Se mide asi y no con metricas de S3 porque las de
#    prefijo son metricas de peticion y se facturan; esta es gratuita y llega
#    antes.
resource "aws_cloudwatch_metric_alarm" "records_in_error_prefix" {
  alarm_name          = "${var.name}-logs-in-error-bucket"
  alarm_description   = "CRITICO · Hay logs que Firehose no pudo entregar y deposito en s3://${local.backup_bucket_name}/${local.error_output_prefix}. Son eventos que no estan en Loki."
  namespace           = "AWS/Firehose"
  metric_name         = "DeliveryToS3.Records"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.critical_actions
  ok_actions          = local.critical_actions

  dimensions = {
    DeliveryStreamName = aws_kinesis_firehose_delivery_stream.logs.name
  }

  tags = merge(var.tags, { Severity = "critical" })
}

# 3. Firehose vivo pero sin entregar. DataFreshness es la edad del registro mas
#    viejo que sigue en el buffer: mientras reintenta, Success no baja y no hay
#    nada en S3 todavia, pero Loki lleva rato sin ver un log. Es exactamente la
#    ventana en la que el hueco se estaba abriendo sin que nada avisara.
resource "aws_cloudwatch_metric_alarm" "delivery_stalled" {
  alarm_name          = "${var.name}-logs-delivery-stalled"
  alarm_description   = "ADVERTENCIA · El registro mas antiguo sin entregar supera ${var.delivery_freshness_warning_seconds / 60} minutos: Firehose sigue reintentando y Loki ya va con retraso."
  namespace           = "AWS/Firehose"
  metric_name         = "DeliveryToHttpEndpoint.DataFreshness"
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  threshold           = var.delivery_freshness_warning_seconds
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.warning_actions
  ok_actions          = local.warning_actions

  dimensions = {
    DeliveryStreamName = aws_kinesis_firehose_delivery_stream.logs.name
  }

  tags = merge(var.tags, { Severity = "warning" })
}
