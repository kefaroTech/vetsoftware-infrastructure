# La contrasena vive en el state, deliberadamente, y no en un valor efimero.
#
# El mecanismo anterior la generaba con un bloque `ephemeral`: nada se persistia y
# los dos consumidores -el usuario de ElastiCache y el secreto de conexion- solo
# coincidian si ambos se escribian en el MISMO apply. Cuando un apply se cortaba a
# la mitad cada cual capturaba un valor distinto del efimero y, como la version no
# cambiaba, ninguno se reescribia nunca mas: el backend arrancaba y moria con
# "WRONGPASS invalid username-password pair or user is disabled". Paso de verdad en
# dev y por eso existe valkey_password_version = 2 en environments/dev/variables.tf.
# Reintentar el apply no lo arreglaba: el efimero generaba un valor NUEVO y volvia a
# divergir.
#
# random_password NO es efimero: su valor se guarda en el state y es estable entre
# ejecuciones. keepers lo regenera unicamente cuando cambia password_version. Con
# eso, un apply cortado converge en el reintento: el consumidor que quedo atras
# tiene su *_wo_version desactualizada en el state, Terraform planifica su
# reescritura, y escribe EL MISMO valor que ya tiene el otro en vez de uno nuevo.
#
# Contrapartida, que es un intercambio y no una mejora gratuita: el hash de la
# contrasena pasa a vivir en el state remoto. Ese state esta cifrado con la CMK
# exclusiva del entorno, versionado en S3 y solo lo lee el rol de apply, asi que el
# intercambio es razonable -pero quien tenga lectura del bucket de state tiene la
# contrasena de Valkey, cosa que con el efimero no ocurria-.
resource "random_password" "valkey" {
  length           = 40
  special          = true
  override_special = "!#$%&*+-.:=?@^_~"
  min_lower        = 4
  min_upper        = 4
  min_numeric      = 4
  min_special      = 4

  keepers = {
    password_version = var.password_version
  }
}

resource "aws_elasticache_user" "application" {
  user_id       = replace("${var.name}-app", "_", "-")
  user_name     = var.user_name
  access_string = "on ~* +@all"
  engine        = "valkey"

  # Sigue siendo write-only: el valor no se copia al state de ESTE recurso. La
  # unica copia es la de random_password, arriba.
  passwords_wo         = random_password.valkey.result
  passwords_wo_version = var.password_version

  tags = var.tags
}

resource "aws_elasticache_user_group" "this" {
  engine        = "valkey"
  user_group_id = replace("${var.name}-users", "_", "-")
  user_ids      = [aws_elasticache_user.application.user_id]

  tags = var.tags
}

resource "aws_elasticache_serverless_cache" "this" {
  engine               = "valkey"
  major_engine_version = var.major_engine_version
  name                 = var.name
  description          = "VetSoftware managed serverless cache"

  subnet_ids         = var.subnet_ids
  security_group_ids = var.security_group_ids
  user_group_id      = aws_elasticache_user_group.this.user_group_id

  # Los datos en cache incluyen sesiones y respuestas con datos de pacientes. Sin
  # esto se cifran con la clave gestionada por AWS, cuya politica de acceso no
  # controla el proyecto, mientras S3, RDS, los log groups y los secretos usan la
  # CMK del entorno.
  #
  # ATENCION: cambiar la clave de cifrado de una caché existente FUERZA su
  # recreacion. En Valkey el dato es efimero por definicion, asi que el impacto es
  # una caché fria y un endpoint nuevo -no una perdida-, pero el endpoint nuevo hay
  # que republicarlo en el secreto: mirar el plan antes de aplicar.
  #
  # null deja el comportamiento actual -clave de AWS- para que las raices que
  # todavia no cablean la variable sigan planificando sin cambios.
  kms_key_id = var.kms_key_arn

  cache_usage_limits {
    data_storage {
      maximum = var.maximum_data_storage_gb
      unit    = "GB"
    }

    ecpu_per_second {
      maximum = var.maximum_ecpu_per_second
    }
  }

  daily_snapshot_time      = var.daily_snapshot_time
  snapshot_retention_limit = var.snapshot_retention_limit

  tags = merge(var.tags, { Name = var.name })
}

resource "aws_secretsmanager_secret" "connection" {
  name                    = "${var.name}/connection"
  description             = "Generated Valkey TLS connection for VetSoftware"
  recovery_window_in_days = 7
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "connection" {
  secret_id = aws_secretsmanager_secret.connection.id

  # El usuario se referencia por su atributo, no por var.user_name: asi la arista
  # de dependencia con aws_elasticache_user es de datos y no depende de que nadie
  # conserve el depends_on de abajo en una edicion futura.
  secret_string_wo = jsonencode({
    REDIS_URL = "rediss://${aws_elasticache_user.application.user_name}:${urlencode(random_password.valkey.result)}@${aws_elasticache_serverless_cache.this.endpoint[0].address}:${aws_elasticache_serverless_cache.this.endpoint[0].port}"
  })

  secret_string_wo_version = var.password_version

  # Orden explicito: el usuario debe tener la contrasena ANTES de que el secreto la
  # anuncie, para que nunca exista una ventana en la que el backend lee unas
  # credenciales publicadas que todavia no funcionan.
  depends_on = [aws_elasticache_user.application]
}
