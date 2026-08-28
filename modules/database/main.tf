resource "aws_db_subnet_group" "this" {
  name       = var.name
  subnet_ids = var.subnet_ids
  tags       = merge(var.tags, { Name = var.name })
}

resource "aws_db_parameter_group" "this" {
  name_prefix = "${var.name}-"
  family      = var.parameter_group_family
  description = "VetSoftware secure MySQL defaults"

  # RDS normaliza este booleano a 1, asi que declararlo como "ON" deja un diff
  # perpetuo: todo plan pide reescribir el bloque y el guard image-only del
  # despliegue lo rechaza por tocar un recurso fuera de ECS.
  parameter {
    name  = "require_secure_transport"
    value = "1"
  }

  # El log general escribe el texto de CADA sentencia al almacenamiento de la
  # instancia: identificaciones, correos, montos de facturacion. RDS lo trae
  # apagado, pero el parametro es dinamico y cualquiera lo enciende desde la
  # consola sin reinicio. Fijarlo aqui hace a Terraform su dueno, de modo que
  # el drift detection lo detecte y el apply siguiente lo revierta. Quitar la
  # exportacion a CloudWatch (var.enabled_log_exports) no basta: sin esto el
  # dato se genera igual, solo que se queda en el disco de la instancia.
  parameter {
    name  = "general_log"
    value = "0"
  }

  parameter {
    name  = "slow_query_log"
    value = "1"
  }

  parameter {
    name  = "long_query_time"
    value = "2"
  }

  # ATENCION: esto RELAJA UNA COMPROBACION DE SEGURIDAD del motor. No es un ajuste
  # rutinario y no se toca sin leer los cuatro parrafos siguientes.
  #
  # POR QUE HACE FALTA
  # El changelog de Liquibase 346_create_accounting_period_triggers.xml crea siete
  # disparadores, entre ellos el que impide escribir en un periodo contable cerrado y
  # el que garantiza que siempre quede al menos un periodo abierto. Con el log binario
  # activo, MySQL rechaza CREATE TRIGGER salvo que el creador tenga SUPER o el
  # privilegio dinamico que lo sustituye:
  #
  #   ERROR 1419 (HY000): You do not have the SUPER privilege and binary logging is
  #   enabled (you *might* want to use the less safe log_bin_trust_function_creators
  #   variable)
  #
  # Aqui se cumplen las dos condiciones y no son evitables:
  #   - El log binario esta encendido porque var.backup_retention_period es >= 7 -lo
  #     obliga la precondition de aws_db_instance.this-, y RDS activa el binlog en
  #     cuanto hay backups automaticos. Apagarlo no es una opcion.
  #   - RDS NUNCA concede SUPER al usuario maestro: es un servicio gestionado. Y el
  #     backend se conecta precisamente como el maestro (var.master_username, con la
  #     contrasena de manage_master_user_password), asi que es el maestro quien corre
  #     la migracion.
  #
  # Sin esto Liquibase falla en el changeset 346, y cuando Liquibase falla la
  # aplicacion no arranca: no es una degradacion, es que el servicio no levanta.
  #
  # POR QUE ESTE CAMINO Y NO EL PRIVILEGIO
  # La alternativa correcta a largo plazo es GRANT SET_ANY_DEFINER -SET_USER_ID antes
  # de MySQL 8.2- al usuario que migra. No es declarable aqui: es un GRANT dentro del
  # motor, el proveedor de AWS no lo modela, y anadir el proveedor mysql exigiria que
  # el runner de CI alcanzara la instancia, que vive en subredes privadas sin ruta
  # desde GitHub Actions. Este parametro es la unica palanca declarable en Terraform y
  # es la que AWS documenta para el error 1419 en RDS.
  #
  # QUE SE PIERDE AL PONERLO EN 1
  # La comprobacion existe para que un usuario sin privilegios no pueda crear un
  # disparador que luego se replique y se ejecute en la replica con los permisos de su
  # DEFINER. En 1, cualquiera con CREATE ROUTINE o TRIGGER en esta instancia puede
  # crear disparadores que acaban en el binlog. Se acepta porque el unico usuario de la
  # instancia es el maestro que usa la aplicacion, no hay replicas de lectura y el
  # acceso de red esta cerrado al security group del backend. Si algun dia se crean
  # usuarios de aplicacion separados, o una replica de lectura, HAY QUE REVISAR ESTA
  # DECISION y migrar al GRANT.
  #
  # VERSION Y REINICIO
  # El parametro esta deprecado desde MySQL 8.0.34 y desaparecera en una version
  # futura; el sustituto es el GRANT descrito arriba. Sigue existiendo y siendo
  # modificable en la familia mysql8.4 que usa esta instancia -verificado contra la
  # API de AWS con
  #   aws rds describe-engine-default-parameters --db-parameter-group-family mysql8.4
  # que lo devuelve con ApplyType "dynamic" e IsModifiable true-. Al ser dinamico, RDS
  # lo aplica en caliente: NO exige reinicio de la instancia ni en dev ni en prod.
  parameter {
    name  = "log_bin_trust_function_creators"
    value = "1"
  }

  lifecycle {
    create_before_destroy = true
  }

  tags = var.tags
}

# RDS crea estos grupos por su cuenta la primera vez que exporta, con retencion
# "Never expire" y la clave gestionada por AWS. Declararlos es la unica forma de
# fijarles caducidad y CMK: no hay ajuste equivalente en la instancia.
#
# Tienen que existir ANTES que ella. Si RDS llega primero, el grupo ya creado no
# es de Terraform y adoptarlo exige un import manual.
resource "aws_cloudwatch_log_group" "database" {
  for_each = toset(var.enabled_log_exports)

  name              = "/aws/rds/instance/${var.name}/${each.value}"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn

  tags = merge(var.tags, { Name = "${var.name}-${each.value}" })
}

resource "aws_db_instance" "this" {
  identifier = var.name

  engine         = "mysql"
  engine_version = var.engine_version
  instance_class = var.instance_class

  db_name  = var.database_name
  username = var.master_username

  # RDS gestiona la contrasena maestra y la guarda en un secreto propio, cuyo ARN
  # exportamos y consume la definicion de tarea del backend como DB_PASSWORD.
  #
  # NO lo pongas en false para "quitar la rotacion". Ese flag no controla la rotacion:
  # controla si RDS gestiona el secreto. En false, el secreto DESAPARECE, el output
  # master_secret_arn deja de existir y el backend se queda sin contrasena.
  #
  # La rotacion automatica -cada 7 dias- se desactivo el 2026-08-25 desde Secrets
  # Manager con `aws secretsmanager cancel-rotate-secret`, y NO se puede declarar aqui:
  # aws_db_instance no expone ese atributo, asi que Terraform ni la ve ni la revierte.
  # Esta linea queda como el unico sitio donde consta la decision.
  #
  # El motivo: la aplicacion lee la contrasena una sola vez, al arrancar. Cuando el
  # secreto rotaba, toda tarea arrancada antes se quedaba con credenciales muertas y
  # fallaba al abrir la siguiente conexion -pool vacio, "Access denied"- mientras el
  # health check seguia en verde, porque no comprueba la base. Paso el 2026-08-25.
  #
  # El arreglo de fondo no es dejar la contrasena fija para siempre, es que la rotacion
  # deje de cortar: releer el secreto al fallar la autenticacion, o disparar un
  # redespliegue desde el evento de rotacion. Mientras eso no exista, esto se queda asi.
  manage_master_user_password         = true
  iam_database_authentication_enabled = true

  allocated_storage     = var.allocated_storage
  max_allocated_storage = var.max_allocated_storage
  storage_type          = "gp3"
  storage_encrypted     = true

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = var.security_group_ids
  parameter_group_name   = aws_db_parameter_group.this.name
  publicly_accessible    = false
  multi_az               = var.multi_az

  backup_retention_period = var.backup_retention_period
  backup_window           = "03:00-04:00"
  maintenance_window      = "sun:04:30-sun:05:30"
  copy_tags_to_snapshot   = true

  performance_insights_enabled          = var.performance_insights_enabled
  performance_insights_retention_period = var.performance_insights_enabled ? 7 : null
  monitoring_interval                   = 0

  auto_minor_version_upgrade = true
  apply_immediately          = var.apply_immediately
  deletion_protection        = true
  skip_final_snapshot        = false
  final_snapshot_identifier  = "${var.name}-final"

  enabled_cloudwatch_logs_exports = var.enabled_log_exports

  tags = merge(var.tags, { Name = var.name })

  depends_on = [aws_cloudwatch_log_group.database]

  lifecycle {
    precondition {
      condition     = var.backup_retention_period >= 7
      error_message = "RDS debe conservar al menos siete dias de backups."
    }
  }
}
