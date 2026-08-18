# Alarmas de RDS MySQL.
#
# Los umbrales absolutos no se escriben a mano: se derivan de max_connections y
# del almacenamiento asignado en locals, de modo que cambiar de clase de
# instancia mueva las alarmas con ella en vez de dejarlas mintiendo.
#
# Dos reglas de higiene que aplican a todo el fichero:
#
#   1. Sin `ok_actions`. La recuperacion no exige ninguna accion -en la taxonomia
#      de Google es Logging, no Alert- y Slack no tiene estado de incidente que
#      cerrar. Es el mismo default de Alertmanager: send_resolved = false para
#      los canales que lee una persona. El OK sigue existiendo en el historial de
#      la alarma y en el panel, que es donde se consulta.
#   2. Sin severidad en el texto. `AlarmDescription` viaja identico en el disparo
#      y en la recuperacion, asi que un texto que empieza por "CRITICO ·" produce
#      un ✅ que dice CRITICO. La severidad viaja en tags.Severity y en el topic.
#
# Todas estas metricas fluyen de forma continua mientras la instancia esta
# disponible, asi que su tratamiento de la ausencia de datos se decide desde el
# root con `continuous_metric_missing_data`. La unica excepcion es
# CPUCreditBalance, explicada al final.

resource "aws_cloudwatch_metric_alarm" "database_cpu" {
  alarm_name          = "${var.name}-database-high-cpu"
  alarm_description   = "CPUUtilization de RDS ${var.database_identifier} por encima de ${var.database_cpu_warning_percent}% durante 15 minutos. Mirar Performance Insights y las consultas en curso."
  namespace           = "AWS/RDS"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  datapoints_to_alarm = 3
  threshold           = var.database_cpu_warning_percent
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = var.continuous_metric_missing_data
  alarm_actions       = local.alarm_actions

  dimensions = {
    DBInstanceIdentifier = var.database_identifier
  }

  tags = merge(var.tags, { Severity = "warning" })
}

resource "aws_cloudwatch_metric_alarm" "database_cpu_critical" {
  alarm_name          = "${var.name}-database-cpu-saturated"
  alarm_description   = "CPUUtilization de RDS ${var.database_identifier} por encima de ${var.database_cpu_critical_percent}% durante 10 minutos: las consultas se encolan y el pool del backend se agota. Mirar Performance Insights y SHOW PROCESSLIST."
  namespace           = "AWS/RDS"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  threshold           = var.database_cpu_critical_percent
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = var.continuous_metric_missing_data
  alarm_actions       = local.critical_actions

  dimensions = {
    DBInstanceIdentifier = var.database_identifier
  }

  tags = merge(var.tags, { Severity = "critical" })
}

# Conexiones. El limite real es max_connections, calculado por RDS como
# {DBInstanceClassMemory/12582880} -formula de sistema, no fijada en el parameter
# group-: en clases micro la memoria reservada lo deja alrededor de 60 y en small
# alrededor de 120. Cada root declara el suyo en database_max_connections y hay
# que medirlo con SHOW GLOBAL VARIABLES al cambiar de clase, porque
# DBInstanceClassMemory no lo expone ningun describe-*. Cuando se agota, MySQL
# responde "Too many connections" y el backend deja de servir aunque la base este
# perfectamente viva; por eso el umbral critico esta antes del limite y no en el
# limite.
resource "aws_cloudwatch_metric_alarm" "database_connections" {
  alarm_name          = "${var.name}-database-connections-high"
  alarm_description   = "DatabaseConnections de ${var.database_identifier} por encima de ${local.database_connections_warning_threshold} de un maximo de ${var.database_max_connections} (${var.database_connections_warning_percent}%). Mirar el pool de Hikari y SHOW PROCESSLIST buscando conexiones sin devolver."
  namespace           = "AWS/RDS"
  metric_name         = "DatabaseConnections"
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  threshold           = local.database_connections_warning_threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = var.continuous_metric_missing_data
  alarm_actions       = local.alarm_actions

  dimensions = {
    DBInstanceIdentifier = var.database_identifier
  }

  tags = merge(var.tags, { Severity = "warning" })
}

resource "aws_cloudwatch_metric_alarm" "database_connections_critical" {
  alarm_name          = "${var.name}-database-connections-exhausted"
  alarm_description   = "DatabaseConnections de ${var.database_identifier} por encima de ${local.database_connections_critical_threshold} de ${var.database_max_connections}: el proximo cliente recibe Too many connections. Mirar SHOW PROCESSLIST y el pool de Hikari."
  namespace           = "AWS/RDS"
  metric_name         = "DatabaseConnections"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 3
  datapoints_to_alarm = 2
  threshold           = local.database_connections_critical_threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = var.continuous_metric_missing_data
  alarm_actions       = local.critical_actions

  dimensions = {
    DBInstanceIdentifier = var.database_identifier
  }

  tags = merge(var.tags, { Severity = "critical" })
}

resource "aws_cloudwatch_metric_alarm" "database_storage" {
  alarm_name          = "${var.name}-database-low-storage"
  alarm_description   = "FreeStorageSpace de ${var.database_identifier} por debajo del ${var.database_free_storage_warning_percent}% del volumen. El autoescalado de almacenamiento esta apagado: ampliar database_allocated_storage es una accion manual."
  namespace           = "AWS/RDS"
  metric_name         = "FreeStorageSpace"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 1
  threshold           = local.database_free_storage_warning_bytes
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = var.continuous_metric_missing_data
  alarm_actions       = local.alarm_actions

  dimensions = {
    DBInstanceIdentifier = var.database_identifier
  }

  tags = merge(var.tags, { Severity = "warning" })
}

# Por debajo del 10% RDS emite RDS-EVENT-0222 y apaga la base para no corromper
# los datos. Esta alarma es el ultimo aviso util antes de esa parada.
resource "aws_cloudwatch_metric_alarm" "database_storage_critical" {
  alarm_name          = "${var.name}-database-storage-exhausted"
  alarm_description   = "FreeStorageSpace de ${var.database_identifier} por debajo del ${var.database_free_storage_critical_percent}%: RDS apaga la instancia para evitar corrupcion si sigue bajando. Ampliar database_allocated_storage y revisar binlogs y tablas temporales."
  namespace           = "AWS/RDS"
  metric_name         = "FreeStorageSpace"
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 1
  threshold           = local.database_free_storage_critical_bytes
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = var.continuous_metric_missing_data
  alarm_actions       = local.critical_actions

  dimensions = {
    DBInstanceIdentifier = var.database_identifier
  }

  tags = merge(var.tags, { Severity = "critical" })
}

resource "aws_cloudwatch_metric_alarm" "database_memory" {
  alarm_name          = "${var.name}-database-low-memory"
  alarm_description   = "FreeableMemory de ${var.database_identifier} por debajo del umbral seguro: el buffer pool empieza a competir con las conexiones. Mirar FreeableMemory y SwapUsage de la ultima hora."
  namespace           = "AWS/RDS"
  metric_name         = "FreeableMemory"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  threshold           = var.database_freeable_memory_threshold_bytes
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = var.continuous_metric_missing_data
  alarm_actions       = local.alarm_actions

  dimensions = {
    DBInstanceIdentifier = var.database_identifier
  }

  tags = merge(var.tags, { Severity = "warning" })
}

resource "aws_cloudwatch_metric_alarm" "database_memory_critical" {
  alarm_name          = "${var.name}-database-memory-exhausted"
  alarm_description   = "FreeableMemory de ${var.database_identifier} agotada: el siguiente paso del motor es swap y despues el reinicio. Mirar los eventos RDS-EVENT-0403 del mismo intervalo en el historial de la instancia."
  namespace           = "AWS/RDS"
  metric_name         = "FreeableMemory"
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 5
  datapoints_to_alarm = 3
  threshold           = var.database_freeable_memory_critical_bytes
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = var.continuous_metric_missing_data
  alarm_actions       = local.critical_actions

  dimensions = {
    DBInstanceIdentifier = var.database_identifier
  }

  tags = merge(var.tags, { Severity = "critical" })
}

# Swap sostenido en una instancia de memoria justa no es una molestia de
# rendimiento: es el sintoma que precede al reinicio del motor por presion de
# memoria. Cuanto mas holgada la clase, mas anomalo es cualquier swap y mas bajo
# se pone el umbral desde el root -dev usa 64 MiB con db.t4g.small-.
resource "aws_cloudwatch_metric_alarm" "database_swap" {
  alarm_name          = "${var.name}-database-swap-usage"
  alarm_description   = "SwapUsage de ${var.database_identifier} sostenido 15 minutos por encima del umbral: hay presion real de memoria, no un pico. Mirar FreeableMemory y el tamano efectivo del buffer pool."
  namespace           = "AWS/RDS"
  metric_name         = "SwapUsage"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  datapoints_to_alarm = 3
  threshold           = var.database_swap_warning_bytes
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = var.continuous_metric_missing_data
  alarm_actions       = local.alarm_actions

  dimensions = {
    DBInstanceIdentifier = var.database_identifier
  }

  tags = merge(var.tags, { Severity = "warning" })
}

# Latencia de E/S. La unidad de la metrica es segundos; 0.02 s son los 20 ms que
# la industria toma como frontera de una carga transaccional sana sobre gp3.
resource "aws_cloudwatch_metric_alarm" "database_latency" {
  for_each = toset(["Read", "Write"])

  alarm_name          = "${var.name}-database-${lower(each.key)}-latency"
  alarm_description   = "${each.key}Latency de ${var.database_identifier} por encima de ${var.database_latency_warning_seconds * 1000} ms durante 15 minutos. Mirar DiskQueueDepth y los creditos EBS del mismo intervalo."
  namespace           = "AWS/RDS"
  metric_name         = "${each.key}Latency"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  datapoints_to_alarm = 3
  threshold           = var.database_latency_warning_seconds
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = var.continuous_metric_missing_data
  alarm_actions       = local.alarm_actions

  dimensions = {
    DBInstanceIdentifier = var.database_identifier
  }

  tags = merge(var.tags, { Severity = "warning" })
}

resource "aws_cloudwatch_metric_alarm" "database_disk_queue" {
  alarm_name          = "${var.name}-database-disk-queue"
  alarm_description   = "DiskQueueDepth de ${var.database_identifier} sostenida por encima de ${var.database_disk_queue_warning}: el volumen no absorbe la carga. Mirar ReadLatency, WriteLatency y EBSIOBalance%."
  namespace           = "AWS/RDS"
  metric_name         = "DiskQueueDepth"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  datapoints_to_alarm = 3
  threshold           = var.database_disk_queue_warning
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = var.continuous_metric_missing_data
  alarm_actions       = local.alarm_actions

  dimensions = {
    DBInstanceIdentifier = var.database_identifier
  }

  tags = merge(var.tags, { Severity = "warning" })
}

# Creditos de rafaga. Son especificos de la familia t y son la causa mas comun de
# una base que "de repente esta lenta" sin que ninguna metrica clasica lo
# explique: al agotarse, el throughput cae a la linea base sin emitir un error.
resource "aws_cloudwatch_metric_alarm" "database_ebs_balance" {
  for_each = toset(["EBSIOBalance%", "EBSByteBalance%"])

  alarm_name          = "${var.name}-database-${lower(replace(each.key, "%", ""))}-low"
  alarm_description   = "${each.key} de ${var.database_identifier} por debajo de ${var.database_ebs_balance_warning_percent}%: al agotarse, la E/S baja a la linea base sin devolver ningun error. Mirar ReadLatency, WriteLatency y DiskQueueDepth."
  namespace           = "AWS/RDS"
  metric_name         = each.key
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  datapoints_to_alarm = 3
  threshold           = var.database_ebs_balance_warning_percent
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = var.continuous_metric_missing_data
  alarm_actions       = local.alarm_actions

  dimensions = {
    DBInstanceIdentifier = var.database_identifier
  }

  tags = merge(var.tags, { Severity = "warning" })
}

# Unica alarma con "ignore" fija, y es deliberado.
#
# Parar una instancia RDS de clase t borra el saldo de creditos acumulado: al
# encender arranca en 0. Como el ambiente se apaga cada noche (schedules
# vetsoftware-dev-*-stop) y solo vive encendido unas horas, el saldo casi nunca
# alcanza el umbral antes del siguiente apagado. Con "notBreaching" pasaba esto:
# la instancia se apagaba, faltaba UN datapoint -bastan 1 de los 3 que exige
# datapoints_to_alarm-, y la alarma anunciaba OK en Slack como si se hubiera
# recuperado. Verificado el 2026-08-08: apagado a las 05:38 UTC con el saldo real
# en ~5 creditos, y transicion a OK a las 05:46 UTC.
#
# "ignore" mantiene el ultimo estado conocido mientras no hay datos: la alarma se
# queda como estaba en vez de fingir recuperacion.
#
# Desde este cambio hay ademas dos defensas por encima: ya no tiene `ok_actions`,
# asi que aunque transitara a OK no habria mensaje que enviar, y la ventana de
# mantenimiento silencia el tramo del apagado. "ignore" se conserva igual porque
# es la semantica honesta del estado, no solo un parche de notificacion.
#
# Contrapartida: si el entorno se mueve a una clase que no publica
# CPUCreditBalance estando en ALARM, la alarma queda colgada en ese estado.
resource "aws_cloudwatch_metric_alarm" "database_cpu_credits" {
  alarm_name          = "${var.name}-database-cpu-credits-low"
  alarm_description   = "CPUCreditBalance de ${var.database_identifier} por debajo de ${var.database_cpu_credit_warning_balance}. Sin creditos, la clase t cae a su linea base o factura sobrecosto. Mirar CPUUtilization y CPUSurplusCreditBalance."
  namespace           = "AWS/RDS"
  metric_name         = "CPUCreditBalance"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  datapoints_to_alarm = 3
  threshold           = var.database_cpu_credit_warning_balance
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "ignore"
  alarm_actions       = local.alarm_actions

  dimensions = {
    DBInstanceIdentifier = var.database_identifier
  }

  tags = merge(var.tags, { Severity = "warning" })
}
