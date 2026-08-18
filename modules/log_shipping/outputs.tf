output "delivery_stream_name" {
  description = "Nombre del delivery stream que entrega los logs a Grafana Cloud."
  value       = aws_kinesis_firehose_delivery_stream.logs.name
}

output "delivery_stream_arn" {
  description = "ARN del delivery stream; es el destino de la suscripcion del log group."
  value       = aws_kinesis_firehose_delivery_stream.logs.arn
}

output "backup_bucket_name" {
  description = "Bucket donde aterriza lo que Firehose no logro entregar."
  value       = aws_s3_bucket.backup.id
}

output "backup_bucket_arn" {
  description = "ARN del bucket de respaldo de entregas fallidas."
  value       = aws_s3_bucket.backup.arn
}

output "firehose_log_group_name" {
  description = "Log group donde Firehose escribe la respuesta del endpoint cuando una entrega falla."
  value       = aws_cloudwatch_log_group.firehose.name
}

output "firehose_role_arn" {
  description = "Rol que asume Firehose para entregar, respaldar y leer la clave de acceso."
  value       = aws_iam_role.firehose.arn
}

output "subscription_role_arn" {
  description = "Rol que asume CloudWatch Logs para empujar la suscripcion hacia Firehose."
  value       = aws_iam_role.subscription.arn
}

output "alarm_names" {
  description = "Alarmas que vigilan el tramo entre CloudWatch Logs y Grafana Cloud."
  value = [
    aws_cloudwatch_metric_alarm.delivery_failing.alarm_name,
    aws_cloudwatch_metric_alarm.records_in_error_prefix.alarm_name,
    aws_cloudwatch_metric_alarm.delivery_stalled.alarm_name,
  ]
}

# Inventario declarativo del tramo, con el mismo proposito que el output
# `alerting` del modulo de monitoreo: que las pruebas afirmen sobre la
# configuracion real -sobre todo las etiquetas lbl_, que son lo unico que separa
# "los logs llegan" de "los logs llegan donde nadie los busca"- sin tener que
# leer recurso por recurso.
output "shipping" {
  description = "Contrato del envio durable de logs: destino, etiquetas de Loki, reintento, respaldo y alarmas."
  value = {
    delivery_stream_name = aws_kinesis_firehose_delivery_stream.logs.name
    endpoint_url         = var.endpoint_url
    source_log_group     = var.source_log_group_name
    filter_pattern       = var.filter_pattern
    distribution         = aws_cloudwatch_log_subscription_filter.backend.distribution
    content_encoding     = "GZIP"

    # Nombres tal cual viajan en request_configuration.common_attributes, con el
    # prefijo puesto. Grafana lo elimina al almacenar: lbl_service_name aterriza
    # en Loki como service_name.
    loki_labels = local.common_attributes

    retry_duration_seconds     = var.retry_duration_seconds
    buffering_interval_seconds = var.buffering_interval_seconds
    buffering_size_mib         = var.buffering_size_mib

    s3_backup_mode = "FailedDataOnly"
    # El nombre derivado y no el id del recurso: asi el contrato se puede afirmar
    # en plan, que es donde corren las pruebas del entorno.
    backup_bucket_name    = local.backup_bucket_name
    error_output_prefix   = local.error_output_prefix
    backup_retention_days = var.backup_retention_days

    access_key_secret_arn = var.access_key_secret_arn
    access_key_in_state   = false
    cloudwatch_logging    = true
    firehose_log_group    = aws_cloudwatch_log_group.firehose.name
    encrypted_with_cmk    = var.kms_key_arn
    alarm_names = [
      aws_cloudwatch_metric_alarm.delivery_failing.alarm_name,
      aws_cloudwatch_metric_alarm.records_in_error_prefix.alarm_name,
      aws_cloudwatch_metric_alarm.delivery_stalled.alarm_name,
    ]
    freshness_warning_seconds = var.delivery_freshness_warning_seconds
  }
}
