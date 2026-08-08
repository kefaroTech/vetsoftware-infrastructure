# Alarmas del cache serverless Valkey.
#
# El cache no es opcional para el backend: las sesiones y el rate limiting viven
# ahi, asi que un cache que rechaza comandos tumba la API igual que una base
# caida. ElastiCache Serverless publica en AWS/ElastiCache con la dimension
# clusterId -no CacheClusterId, que es la de los clusters por nodos-.
#
# Los limites de dev son deliberadamente bajos (1 GB y 1.000 ECPU/s) para fijar
# el costo, lo que hace que tocarlos sea plausible y no teorico.

resource "aws_cloudwatch_metric_alarm" "cache_data_storage" {
  count = local.cache_alarms_enabled && var.cache_maximum_data_storage_gb > 0 ? 1 : 0

  alarm_name          = "${var.name}-cache-storage-high"
  alarm_description   = "ADVERTENCIA · El cache ocupa mas del ${var.cache_utilization_warning_percent}% de su limite de ${var.cache_maximum_data_storage_gb} GB. Al llegar al tope empieza a expulsar claves."
  namespace           = "AWS/ElastiCache"
  metric_name         = "BytesUsedForCache"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  threshold           = local.cache_data_storage_warning_bytes
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions

  dimensions = {
    clusterId = var.cache_name
  }

  tags = merge(var.tags, { Severity = "warning" })
}

resource "aws_cloudwatch_metric_alarm" "cache_ecpu" {
  count = local.cache_alarms_enabled && var.cache_maximum_ecpu_per_second > 0 ? 1 : 0

  alarm_name          = "${var.name}-cache-ecpu-high"
  alarm_description   = "ADVERTENCIA · El cache consume mas del ${var.cache_utilization_warning_percent}% de su limite de ${var.cache_maximum_ecpu_per_second} ECPU/s. Pasado el tope, ElastiCache empieza a rechazar comandos."
  namespace           = "AWS/ElastiCache"
  metric_name         = "ElastiCacheProcessingUnits"
  statistic           = "Sum"
  period              = local.cache_ecpu_period_seconds
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  threshold           = local.cache_ecpu_warning_per_period
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions

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
  alarm_description   = "CRITICO · ElastiCache esta rechazando comandos por limite de capacidad: el backend ya esta recibiendo errores del cache."
  namespace           = "AWS/ElastiCache"
  metric_name         = "ThrottledCmds"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.critical_actions
  ok_actions          = local.critical_actions

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
  alarm_description   = "CRITICO · Fallos de autenticacion contra Valkey. Si coinciden con un despliegue, revisar valkey_password_version: usuario y secreto pueden haber quedado desincronizados."
  namespace           = "AWS/ElastiCache"
  metric_name         = "AuthenticationFailures"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.critical_actions
  ok_actions          = local.critical_actions

  dimensions = {
    clusterId = var.cache_name
  }

  tags = merge(var.tags, { Severity = "critical" })
}
