# Alarmas del cache serverless Valkey.
#
# El cache no es opcional para el backend: las sesiones y el rate limiting viven
# ahi, asi que un cache que rechaza comandos tumba la API igual que una base
# caida. ElastiCache Serverless publica en AWS/ElastiCache con la dimension
# clusterId -no CacheClusterId, que es la de los clusters por nodos-.
#
# Los limites de dev son deliberadamente bajos (1 GB y 1.000 ECPU/s) para fijar
# el costo, lo que hace que tocarlos sea plausible y no teorico.
#
# Sin `ok_actions` ni severidad en el texto: ver la cabecera de
# alarms_database.tf.
#
# Nota sobre la ausencia de datos. ElastiCache Serverless NO se apaga con el
# resto del entorno -no existe stop para serverless-, asi que la justificacion
# del apagado nocturno nunca aplico a este fichero. Aun asi las dos alarmas de
# ocupacion siguen `continuous_metric_missing_data` en lugar de forzarse a
# "breaching": con el trafico practicamente nulo de dev no esta verificado que
# ElastiCacheProcessingUnits publique ceros en vez de no publicar, y una alarma
# permanentemente en ALARM seria peor que la ceguera que corrige.
# ThrottledCmds y AuthenticationFailures si quedan fijas en notBreaching: son
# metricas que por diseno solo existen cuando hay error.

resource "aws_cloudwatch_metric_alarm" "cache_data_storage" {
  count = local.cache_alarms_enabled && var.cache_maximum_data_storage_gb > 0 ? 1 : 0

  alarm_name          = "${var.name}-cache-storage-high"
  alarm_description   = "BytesUsedForCache de ${var.cache_name} por encima del ${var.cache_utilization_warning_percent}% de su limite de ${var.cache_maximum_data_storage_gb} GB; al llegar al tope empieza a expulsar claves. Mirar BytesUsedForCache y Evictions."
  namespace           = "AWS/ElastiCache"
  metric_name         = "BytesUsedForCache"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  threshold           = local.cache_data_storage_warning_bytes
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = var.continuous_metric_missing_data
  alarm_actions       = local.alarm_actions

  dimensions = {
    clusterId = var.cache_name
  }

  tags = merge(var.tags, { Severity = "warning" })
}

resource "aws_cloudwatch_metric_alarm" "cache_ecpu" {
  count = local.cache_alarms_enabled && var.cache_maximum_ecpu_per_second > 0 ? 1 : 0

  alarm_name          = "${var.name}-cache-ecpu-high"
  alarm_description   = "ElastiCacheProcessingUnits de ${var.cache_name} por encima del ${var.cache_utilization_warning_percent}% de su limite de ${var.cache_maximum_ecpu_per_second} ECPU/s; pasado el tope ElastiCache empieza a rechazar comandos. Mirar ElastiCacheProcessingUnits y ThrottledCmds."
  namespace           = "AWS/ElastiCache"
  metric_name         = "ElastiCacheProcessingUnits"
  statistic           = "Sum"
  period              = local.cache_ecpu_period_seconds
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  threshold           = local.cache_ecpu_warning_per_period
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = var.continuous_metric_missing_data
  alarm_actions       = local.alarm_actions

  dimensions = {
    clusterId = var.cache_name
  }

  tags = merge(var.tags, { Severity = "warning" })
}

# ThrottledCmds no es una advertencia de capacidad: es la confirmacion de que
# comandos que el backend envio ya fueron rechazados.
resource "aws_cloudwatch_metric_alarm" "cache_throttled" {
  count = local.cache_alarms_enabled ? 1 : 0

  alarm_name          = "${var.name}-cache-throttled"
  alarm_description   = "ElastiCache rechazo comandos de ${var.cache_name} por limite de capacidad: el backend ya esta recibiendo errores del cache. Mirar ElastiCacheProcessingUnits del mismo intervalo."
  namespace           = "AWS/ElastiCache"
  metric_name         = "ThrottledCmds"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.critical_actions

  dimensions = {
    clusterId = var.cache_name
  }

  tags = merge(var.tags, { Severity = "critical" })
}

# La contrasena de Valkey se regenera por version del ephemeral; un apply cortado
# a la mitad deja usuario y secreto con valores distintos y el backend arranca y
# muere con WRONGPASS. Esta alarma nombra esa falla antes de que alguien la
# diagnostique leyendo logs de arranque.
resource "aws_cloudwatch_metric_alarm" "cache_authentication_failures" {
  count = local.cache_alarms_enabled ? 1 : 0

  alarm_name          = "${var.name}-cache-auth-failures"
  alarm_description   = "Fallos de autenticacion contra ${var.cache_name}. Si coinciden con un despliegue, revisar valkey_password_version: usuario y secreto pueden haber quedado desincronizados. Mirar ${local.backend_log_group_hint} buscando WRONGPASS."
  namespace           = "AWS/ElastiCache"
  metric_name         = "AuthenticationFailures"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.critical_actions

  dimensions = {
    clusterId = var.cache_name
  }

  tags = merge(var.tags, { Severity = "critical" })
}
