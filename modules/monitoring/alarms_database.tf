# Alarmas de RDS MySQL.
#
# Los umbrales absolutos no se escriben a mano: se derivan de max_connections y
# del almacenamiento asignado en locals, de modo que cambiar de clase de
# instancia mueva las alarmas con ella en vez de dejarlas mintiendo.
#
# Ninguna usa treat_missing_data = "breaching". El apagado programado detiene la
# instancia cada noche entre semana, y RDS deja de publicar metricas cuando esta
# detenida: interpretar ese silencio como falla genera una alarma diaria a las
# 20:15 que enseña al equipo a ignorar el canal.

resource "aws_cloudwatch_metric_alarm" "database_cpu" {
  alarm_name          = "${var.name}-database-high-cpu"
  alarm_description   = "ADVERTENCIA · CPU de RDS por encima de ${var.database_cpu_warning_percent}% durante 15 minutos."
  namespace           = "AWS/RDS"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  datapoints_to_alarm = 3
  threshold           = var.database_cpu_warning_percent
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions

  dimensions = {
    DBInstanceIdentifier = var.database_identifier
  }

  tags = merge(var.tags, { Severity = "warning" })
}

resource "aws_cloudwatch_metric_alarm" "database_cpu_critical" {
  alarm_name          = "${var.name}-database-cpu-saturated"
  alarm_description   = "CRITICO · CPU de RDS por encima de ${var.database_cpu_critical_percent}% durante 10 minutos: las consultas se estan encolando y el pool del backend se va a agotar."
  namespace           = "AWS/RDS"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  threshold           = var.database_cpu_critical_percent
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.critical_actions
  ok_actions          = local.critical_actions

  dimensions = {
    DBInstanceIdentifier = var.database_identifier
  }

  tags = merge(var.tags, { Severity = "critical" })
}

# Conexiones. El limite real es max_connections, calculado por RDS como
# {DBInstanceClassMemory/12582880}: en clases micro la memoria reservada lo deja
# alrededor de 60. Cuando se agota, MySQL responde "Too many connections" y el
# backend deja de servir aunque la base este perfectamente viva; por eso el
# umbral critico esta antes del limite y no en el limite.
resource "aws_cloudwatch_metric_alarm" "database_connections" {
  alarm_name          = "${var.name}-database-connections-high"
  alarm_description   = "ADVERTENCIA · ${local.database_connections_warning_threshold} conexiones abiertas de un maximo de ${var.database_max_connections} (${var.database_connections_warning_percent}%). Revisar fugas del pool antes de que llegue al limite."
  namespace           = "AWS/RDS"
  metric_name         = "DatabaseConnections"
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  threshold           = local.database_connections_warning_threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions

  dimensions = {
    DBInstanceIdentifier = var.database_identifier
  }

  tags = merge(var.tags, { Severity = "warning" })
}

resource "aws_cloudwatch_metric_alarm" "database_connections_critical" {
  alarm_name          = "${var.name}-database-connections-exhausted"
  alarm_description   = "CRITICO · ${local.database_connections_critical_threshold} conexiones de ${var.database_max_connections}: el proximo cliente recibe Too many connections."
  namespace           = "AWS/RDS"
  metric_name         = "DatabaseConnections"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 3
  datapoints_to_alarm = 2
  threshold           = local.database_connections_critical_threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.critical_actions
  ok_actions          = local.critical_actions

  dimensions = {
    DBInstanceIdentifier = var.database_identifier
  }

  tags = merge(var.tags, { Severity = "critical" })
}

resource "aws_cloudwatch_metric_alarm" "database_storage" {
  alarm_name          = "${var.name}-database-low-storage"
  alarm_description   = "ADVERTENCIA · Menos de ${var.database_free_storage_warning_percent}% de disco libre en RDS. El autoescalado de almacenamiento esta apagado en dev: ampliar es una accion manual."
  namespace           = "AWS/RDS"
  metric_name         = "FreeStorageSpace"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 1
  threshold           = local.database_free_storage_warning_bytes
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions

  dimensions = {
    DBInstanceIdentifier = var.database_identifier
  }

  tags = merge(var.tags, { Severity = "warning" })
}

# Por debajo del 10% RDS emite RDS-EVENT-0222 y apaga la base para no corromper
# los datos. Esta alarma es el ultimo aviso util antes de esa parada.
resource "aws_cloudwatch_metric_alarm" "database_storage_critical" {
  alarm_name          = "${var.name}-database-storage-exhausted"
  alarm_description   = "CRITICO · Menos de ${var.database_free_storage_critical_percent}% de disco libre. RDS apaga la instancia para evitar corrupcion si sigue bajando."
  namespace           = "AWS/RDS"
  metric_name         = "FreeStorageSpace"
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 1
  threshold           = local.database_free_storage_critical_bytes
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.critical_actions
  ok_actions          = local.critical_actions

  dimensions = {
    DBInstanceIdentifier = var.database_identifier
  }

  tags = merge(var.tags, { Severity = "critical" })
}

resource "aws_cloudwatch_metric_alarm" "database_memory" {
  alarm_name          = "${var.name}-database-low-memory"
  alarm_description   = "ADVERTENCIA · Memoria libre de RDS por debajo del umbral seguro; el buffer pool empieza a competir con las conexiones."
  namespace           = "AWS/RDS"
  metric_name         = "FreeableMemory"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  threshold           = var.database_freeable_memory_threshold_bytes
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions

  dimensions = {
    DBInstanceIdentifier = var.database_identifier
  }

  tags = merge(var.tags, { Severity = "warning" })
}

resource "aws_cloudwatch_metric_alarm" "database_memory_critical" {
  alarm_name          = "${var.name}-database-memory-exhausted"
  alarm_description   = "CRITICO · Memoria libre de RDS agotada. El siguiente paso del motor es swap, y despues el reinicio."
  namespace           = "AWS/RDS"
  metric_name         = "FreeableMemory"
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 5
  datapoints_to_alarm = 3
  threshold           = var.database_freeable_memory_critical_bytes
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.critical_actions
  ok_actions          = local.critical_actions

  dimensions = {
    DBInstanceIdentifier = var.database_identifier
  }

  tags = merge(var.tags, { Severity = "critical" })
}

# Swap sostenido en una instancia de 1 GiB no es una molestia de rendimiento: es
# el sintoma que precede al reinicio del motor por presion de memoria.
resource "aws_cloudwatch_metric_alarm" "database_swap" {
  alarm_name          = "${var.name}-database-swap-usage"
  alarm_description   = "ADVERTENCIA · RDS lleva 15 minutos usando swap: hay presion real de memoria, no un pico."
  namespace           = "AWS/RDS"
  metric_name         = "SwapUsage"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  datapoints_to_alarm = 3
  threshold           = var.database_swap_warning_bytes
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions

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
  alarm_description   = "ADVERTENCIA · Latencia de ${lower(each.key) == "read" ? "lectura" : "escritura"} de RDS por encima de ${var.database_latency_warning_seconds * 1000} ms durante 15 minutos."
  namespace           = "AWS/RDS"
  metric_name         = "${each.key}Latency"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  datapoints_to_alarm = 3
  threshold           = var.database_latency_warning_seconds
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions

  dimensions = {
    DBInstanceIdentifier = var.database_identifier
  }

  tags = merge(var.tags, { Severity = "warning" })
}

resource "aws_cloudwatch_metric_alarm" "database_disk_queue" {
  alarm_name          = "${var.name}-database-disk-queue"
  alarm_description   = "ADVERTENCIA · Cola de disco de RDS sostenida por encima de ${var.database_disk_queue_warning}: el volumen no absorbe la carga."
  namespace           = "AWS/RDS"
  metric_name         = "DiskQueueDepth"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  datapoints_to_alarm = 3
  threshold           = var.database_disk_queue_warning
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions

  dimensions = {
    DBInstanceIdentifier = var.database_identifier
  }

  tags = merge(var.tags, { Severity = "warning" })
}

# Creditos de rafaga. Son especificos de la familia t y son la causa mas comun de
# una base que "de repente esta lenta" sin que ninguna metrica clasica lo
# explique: al agotarse, el throughput cae a la linea base sin emitir un error.
# En estas dos, notBreaching cubre el caso de mover el entorno a una clase que no
# las publica. La de creditos de CPU usa "ignore" por el motivo explicado abajo.
resource "aws_cloudwatch_metric_alarm" "database_ebs_balance" {
  for_each = toset(["EBSIOBalance%", "EBSByteBalance%"])

  alarm_name          = "${var.name}-database-${lower(replace(each.key, "%", ""))}-low"
  alarm_description   = "ADVERTENCIA · Credito ${each.key} por debajo de ${var.database_ebs_balance_warning_percent}%: al agotarse, la E/S baja a la linea base sin devolver ningun error."
  namespace           = "AWS/RDS"
  metric_name         = each.key
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  datapoints_to_alarm = 3
  threshold           = var.database_ebs_balance_warning_percent
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions

  dimensions = {
    DBInstanceIdentifier = var.database_identifier
  }

  tags = merge(var.tags, { Severity = "warning" })
}

# Unica alarma con "ignore" en vez de "notBreaching", y es deliberado.
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
# queda como estaba en vez de fingir recuperacion. No genera ruido extra porque
# sin cambio de estado no hay notificacion.
#
# Contrapartida: si el entorno se mueve a una clase que no publica
# CPUCreditBalance estando en ALARM, la alarma queda colgada en ese estado. Ese
# es el caso que "notBreaching" cubre en las demas de esta familia; aqui se
# acepta a cambio de no recibir un OK falso cada noche.
resource "aws_cloudwatch_metric_alarm" "database_cpu_credits" {
  alarm_name          = "${var.name}-database-cpu-credits-low"
  alarm_description   = "ADVERTENCIA · Creditos de CPU de la instancia burstable por debajo de ${var.database_cpu_credit_warning_balance}. Sin creditos, la clase t cae a su linea base o factura sobrecosto."
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
  ok_actions          = local.alarm_actions

  dimensions = {
    DBInstanceIdentifier = var.database_identifier
  }

  tags = merge(var.tags, { Severity = "warning" })
}
