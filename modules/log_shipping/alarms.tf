# Alarmas del envio de logs.
#
# El hueco de 50 minutos no fue invisible por falta de datos: fue invisible
# porque nadie vigilaba el tramo. Estas alarmas cubren las formas en que este
# camino puede fallar, y ninguna de ellas se nota mirando la aplicacion.
#
# Tres decisiones transversales, escritas una sola vez aqui:
#
# 1. Ninguna alarma tiene ok_actions. El destino es un canal de Slack que lee una
#    persona, y la recuperacion no le pide ninguna accion: en la taxonomia de
#    Google es Logging, no Alerta. Es el mismo criterio que traen por defecto los
#    receptores de Alertmanager -send_resolved = false en Slack y correo, true en
#    PagerDuty y webhooks-: la recuperacion se manda a los sistemas que llevan
#    estado de incidente y hay que cerrar, no a los humanos. Ninguna de estas
#    alarmas dispara una remediacion automatica; si alguna llegara a hacerlo, esa
#    si querria su ok_action.
#
# 2. Las descripciones no dicen severidad ni estado. AlarmDescription es un
#    string fijo que CloudWatch envia identico al disparar y al recuperar -no hay
#    plantillas-, asi que un "CRITICO" escrito dentro produce un aviso de
#    recuperacion que se contradice a si mismo. La severidad viaja donde si
#    cambia: tags.Severity y la eleccion del topic. La descripcion solo dice que
#    se mide y donde mirar.
#
# 3. treat_missing_data es "notBreaching" en las alarmas de proporcion y de
#    latencia, igual que en el resto del entorno: dev se apaga cada noche y sin
#    trafico Firehose no publica metrica. La excepcion es la alarma de volumen
#    -no_delivery-, que existe precisamente para que la ausencia de datos sea la
#    senal; su ruido nocturno lo apaga la compuesta, no el trato de los huecos.

# 1. Entregas que fallan. Success es la proporcion de intentos aceptados por el
#    endpoint: por debajo de 1 hay registros rebotando -token sin scope, 429,
#    endpoint del stack equivocado-. Es la senal directa del incidente original.
#
#    Su punto ciego ya no queda descubierto: Success solo existe si hubo
#    intentos, asi que un stream muerto no produce datapoints y esta alarma se
#    queda en OK. Ese caso lo cubre la compuesta de mas abajo.
resource "aws_cloudwatch_metric_alarm" "delivery_failing" {
  alarm_name          = "${var.name}-logs-delivery-failing"
  alarm_description   = "Mide la proporcion de entregas aceptadas por el endpoint de Grafana Cloud (DeliveryToHttpEndpoint.Success) en el stream ${local.stream_name}. Donde mirar: log group ${local.log_group_name}, flujo ${aws_cloudwatch_log_stream.http_endpoint.name}; ahi esta la respuesta literal del endpoint."
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
  alarm_description   = "Cuenta los registros que Firehose deposito en el respaldo tras agotar los reintentos (DeliveryToS3.Records); lo que aterriza ahi no esta en Loki. Donde mirar: s3://${local.backup_bucket_name}/${local.error_output_prefix}, el flujo ${aws_cloudwatch_log_stream.s3_backup.name} del log group ${local.log_group_name}, y el original que sigue en ${var.source_log_group_name}."
  namespace           = "AWS/Firehose"
  metric_name         = "DeliveryToS3.Records"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.critical_actions

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
  alarm_description   = "Mide la antiguedad del registro mas viejo sin entregar (DeliveryToHttpEndpoint.DataFreshness) frente al umbral de ${var.delivery_freshness_warning_seconds / 60} minutos en el stream ${local.stream_name}. Donde mirar: DeliveryToHttpEndpoint.Success de la misma ventana; si sigue en 1 es lentitud del endpoint y se absorbe dentro de las ${var.retry_duration_seconds / 3600} horas de reintento."
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

  dimensions = {
    DeliveryStreamName = aws_kinesis_firehose_delivery_stream.logs.name
  }

  tags = merge(var.tags, { Severity = "warning" })
}

# 4. El interruptor de hombre muerto, en dos senales y una compuesta.
#
#    Las alarmas 1 y 3 son de proporcion y de latencia: las dos necesitan que
#    Firehose intente algo para existir. Si el stream muere, si la suscripcion se
#    borra o si el rol pierde el permiso, no hay intentos, no hay datapoints y con
#    notBreaching esas alarmas se quedan en un OK indistinguible del OK correcto.
#    Ese es justo el modo de fallo que este modulo vino a cerrar.
#
#    La traduccion a CloudWatch del absent() de PromQL es medir volumen en vez de
#    proporcion y tratar el hueco como falla: Records con estadistico Sum por
#    debajo de 1 y treat_missing_data = "breaching". Aqui el silencio es la senal.
#
#    Sola, esta alarma sonaria todas las noches: el apagado programado baja el
#    servicio a las 20:00 hora Bogota y a partir de ahi no hay nada que entregar.
#    Por eso no notifica -actions_enabled = false- y solo participa en la
#    compuesta.
resource "aws_cloudwatch_metric_alarm" "no_delivery" {
  alarm_name          = "${var.name}-logs-no-delivery"
  alarm_description   = "Cuenta los registros entregados al endpoint de Grafana Cloud (DeliveryToHttpEndpoint.Records, Sum) en el stream ${local.stream_name}, tratando la ausencia de metrica como falla. Senal interna: no notifica por si sola, alimenta la compuesta ${var.name}-logs-not-shipping. Donde mirar: que existan y esten habilitados el stream y la suscripcion ${var.name}-backend-to-grafana-cloud sobre ${var.source_log_group_name}."
  namespace           = "AWS/Firehose"
  metric_name         = "DeliveryToHttpEndpoint.Records"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  threshold           = 1
  comparison_operator = "LessThanThreshold"

  # La unica "breaching" del modulo, y el motivo de que exista este recurso: sin
  # esto un stream muerto no se distingue de un stream sano.
  treat_missing_data = "breaching"

  # No notifica: sonaria cada noche a las 20:00. La decision de avisar la toma la
  # compuesta, que ademas sabe si habia algo que entregar.
  actions_enabled = false

  dimensions = {
    DeliveryStreamName = aws_kinesis_firehose_delivery_stream.logs.name
  }

  tags = merge(var.tags, { Severity = "internal" })
}

# 5. La senal de "hay algo que entregar", que es la que evita que lo anterior
#    grite durante el apagado nocturno.
#
#    Se mide sobre IncomingLogEvents del log group de origen y no sobre el estado
#    de ECS a proposito: es la definicion literal de "existe trabajo para este
#    stream" -si nadie escribio en el log group, no hay nada que Firehose deba
#    haber entregado-, es gratuita, y no depende de Container Insights, que en dev
#    esta desactivado y por tanto no publica RunningTaskCount.
#
#    En ALARM significa "el origen esta produciendo logs". Es una inversion
#    deliberada del sentido habitual, porque una compuesta solo sabe combinar
#    estados de alarma.
#
#    La ventana es MAS CORTA que la de no_delivery, y eso es lo que hay que
#    conservar si alguien toca los periodos: durante el apagado esta debe volver a
#    OK -y cerrar la compuerta- antes de que no_delivery entre en ALARM. Con un
#    periodo aqui y dos alla quedan cinco minutos de margen. Si algun dia llega un
#    aviso a las 20:10, la correccion es ampliar no_delivery a tres periodos,
#    nunca alargar esta.
resource "aws_cloudwatch_metric_alarm" "source_active" {
  alarm_name          = "${var.name}-logs-source-active"
  alarm_description   = "Cuenta los eventos que ingresan al log group de origen ${var.source_log_group_name} (IncomingLogEvents, Sum). Senal interna e invertida: en ALARM significa que el entorno esta produciendo logs y por tanto hay algo que entregar. No notifica; habilita la compuesta ${var.name}-logs-not-shipping fuera del apagado programado."
  namespace           = "AWS/Logs"
  metric_name         = "IncomingLogEvents"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"

  # Sin eventos no hay metrica, y sin eventos no hay nada que entregar: el hueco
  # significa "entorno callado", que es exactamente el OK que se quiere. Aqui
  # notBreaching no reintroduce el punto ciego de la alarma 1 -alli tapaba la
  # senal de fallo, aqui cierra una compuerta-, pero deja un caso descubierto: si
  # el driver de logs de la tarea se rompe, el log group enmudece, esta vuelve a
  # OK y la compuesta calla. Ese fallo es del backend y no del envio, y lo vigilan
  # las alarmas del modulo de monitoreo.
  treat_missing_data = "notBreaching"
  actions_enabled    = false

  dimensions = {
    LogGroupName = var.source_log_group_name
  }

  tags = merge(var.tags, { Severity = "internal" })
}

# 6. La compuesta: no llega nada a Grafana Cloud teniendo algo que enviar.
#
#    AWS recomienda esta figura para agrupar senales relacionadas y bajar el ruido
#    (Well-Architected OPS10-BP02). Aqui hace las dos cosas a la vez: convierte el
#    silencio en un aviso y le quita las catorce horas diarias en que el silencio
#    es lo esperado.
resource "aws_cloudwatch_composite_alarm" "not_shipping" {
  alarm_name        = "${var.name}-logs-not-shipping"
  alarm_description = "Se activa cuando el stream ${local.stream_name} no entrego ningun registro al endpoint mientras el log group ${var.source_log_group_name} si estaba recibiendo eventos. Donde mirar: primero que el stream y la suscripcion ${var.name}-backend-to-grafana-cloud existan y esten habilitados; despues el log group ${local.log_group_name}, flujo ${aws_cloudwatch_log_stream.http_endpoint.name}. Durante el apagado programado no se espera actividad aqui."

  alarm_rule = join(" AND ", [
    "ALARM(\"${aws_cloudwatch_metric_alarm.no_delivery.alarm_name}\")",
    "ALARM(\"${aws_cloudwatch_metric_alarm.source_active.alarm_name}\")",
  ])

  actions_enabled = true
  alarm_actions   = local.critical_actions

  tags = merge(var.tags, { Severity = "critical" })
}

locals {
  metric_alarm_names = [
    aws_cloudwatch_metric_alarm.delivery_failing.alarm_name,
    aws_cloudwatch_metric_alarm.records_in_error_prefix.alarm_name,
    aws_cloudwatch_metric_alarm.delivery_stalled.alarm_name,
    aws_cloudwatch_metric_alarm.no_delivery.alarm_name,
    aws_cloudwatch_metric_alarm.source_active.alarm_name,
  ]

  composite_alarm_names = [
    aws_cloudwatch_composite_alarm.not_shipping.alarm_name,
  ]

  # Todas, incluidas las dos senales internas. Una regla de silenciado que las
  # omitiera dejaria a la compuesta activandose por sus hijas.
  all_alarm_names = concat(local.metric_alarm_names, local.composite_alarm_names)
}
