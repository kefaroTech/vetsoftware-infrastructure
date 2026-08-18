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

# Metricas y compuesta juntas, y con las dos senales internas dentro: quien
# consuma esto para silenciar una ventana necesita las cinco hijas ademas de la
# compuesta, porque silenciar solo la compuesta deja a no_delivery y a
# source_active cambiando de estado por debajo.
output "alarm_names" {
  description = "Alarmas que vigilan el tramo entre CloudWatch Logs y Grafana Cloud, incluidas las dos senales internas y la compuesta."
  value       = local.all_alarm_names
}

output "composite_alarm_names" {
  description = "Alarmas compuestas del modulo; son las unicas del interruptor de hombre muerto que notifican."
  value       = local.composite_alarm_names
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
    alarm_names           = local.all_alarm_names
    metric_alarm_names    = local.metric_alarm_names
    composite_alarm_names = local.composite_alarm_names

    # El contrato del interruptor de hombre muerto, afirmable en plan: la senal
    # de volumen trata el hueco como falla, la de actividad del origen lo trata
    # como calma, y la compuesta exige las dos. Si alguien invierte cualquiera de
    # los dos treat_missing_data, el punto ciego vuelve sin que nada mas cambie.
    dead_mans_switch = {
      volume_alarm_name         = aws_cloudwatch_metric_alarm.no_delivery.alarm_name
      volume_missing_data       = aws_cloudwatch_metric_alarm.no_delivery.treat_missing_data
      liveness_alarm_name       = aws_cloudwatch_metric_alarm.source_active.alarm_name
      liveness_metric           = aws_cloudwatch_metric_alarm.source_active.metric_name
      liveness_missing_data     = aws_cloudwatch_metric_alarm.source_active.treat_missing_data
      liveness_evaluation_range = aws_cloudwatch_metric_alarm.source_active.evaluation_periods * aws_cloudwatch_metric_alarm.source_active.period
      volume_evaluation_range   = aws_cloudwatch_metric_alarm.no_delivery.evaluation_periods * aws_cloudwatch_metric_alarm.no_delivery.period
      composite_alarm_name      = aws_cloudwatch_composite_alarm.not_shipping.alarm_name
      composite_alarm_rule      = aws_cloudwatch_composite_alarm.not_shipping.alarm_rule
    }

    # Ninguna alarma del modulo notifica la recuperacion: el destino es un canal
    # que lee una persona. Se expone para que la prueba lo afirme y no vuelva a
    # colarse un ok_action.
    # Sin ok_actions el atributo queda nulo, no vacio: el conteo tiene que
    # distinguir los dos casos o el propio output revienta el plan.
    ok_actions_configured = length(flatten([
      for actions in [
        aws_cloudwatch_metric_alarm.delivery_failing.ok_actions,
        aws_cloudwatch_metric_alarm.records_in_error_prefix.ok_actions,
        aws_cloudwatch_metric_alarm.delivery_stalled.ok_actions,
        aws_cloudwatch_metric_alarm.no_delivery.ok_actions,
        aws_cloudwatch_metric_alarm.source_active.ok_actions,
        aws_cloudwatch_composite_alarm.not_shipping.ok_actions,
      ] : (actions == null ? [] : tolist(actions))
    ]))

    # Las descripciones viajan identicas al disparar y al recuperar, asi que no
    # pueden afirmar severidad ni estado.
    alarm_descriptions = [
      aws_cloudwatch_metric_alarm.delivery_failing.alarm_description,
      aws_cloudwatch_metric_alarm.records_in_error_prefix.alarm_description,
      aws_cloudwatch_metric_alarm.delivery_stalled.alarm_description,
      aws_cloudwatch_metric_alarm.no_delivery.alarm_description,
      aws_cloudwatch_metric_alarm.source_active.alarm_description,
      aws_cloudwatch_composite_alarm.not_shipping.alarm_description,
    ]

    freshness_warning_seconds = var.delivery_freshness_warning_seconds
  }
}
