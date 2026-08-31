data "aws_region" "current" {}

# Una shell en el contenedor da acceso al filesystem, a la red de la tarea y a
# las variables inyectadas desde Secrets Manager -DB_PASSWORD, JWT_SECRET,
# DIAN_ENC_KEY-. Sin este log group la sesion no queda registrada en ningun
# sitio: CloudTrail anota que alguien invoco ExecuteCommand, pero no lo que se
# tecleo dentro. Solo existe cuando la capacidad esta activa.
resource "aws_cloudwatch_log_group" "exec" {
  count = var.enable_execute_command ? 1 : 0

  name              = "/ecs/${var.name}/exec"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn
  tags              = var.tags
}

resource "aws_ecs_cluster" "this" {
  name = var.name

  setting {
    name  = "containerInsights"
    value = var.enable_container_insights ? "enhanced" : "disabled"
  }

  dynamic "configuration" {
    for_each = var.enable_execute_command ? [1] : []

    content {
      execute_command_configuration {
        kms_key_id = var.kms_key_arn
        logging    = "OVERRIDE"

        log_configuration {
          cloud_watch_encryption_enabled = true
          cloud_watch_log_group_name     = aws_cloudwatch_log_group.exec[0].name
        }
      }
    }
  }

  tags = var.tags
}

resource "aws_cloudwatch_log_group" "backend" {
  name              = "/ecs/${var.name}/backend"
  retention_in_days = var.backend_log_retention_days != null ? var.backend_log_retention_days : var.log_retention_days
  kms_key_id        = var.kms_key_arn
  tags              = var.tags
}

resource "aws_cloudwatch_log_group" "cloudflare_tunnel" {
  name              = "/ecs/${var.name}/cloudflare-tunnel"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn
  tags              = var.tags
}

# Log group propio del sidecar. Es esencial que no comparta el del backend: el
# colector es essential = false, asi que puede morir sin llevarse la tarea y sin
# que nadie se entere. Estas lineas son la unica evidencia de por que murio -y
# son las que consulta el filtro de metrica que dispara la alarma-. Si algun dia
# readonlyRootFilesystem le impide escribir en un path que necesite, el sintoma
# aparece aqui y en ningun otro sitio.
resource "aws_cloudwatch_log_group" "telemetry" {
  count = var.telemetry_sidecar_enabled ? 1 : 0

  name              = "/ecs/${var.name}/telemetry"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn
  tags              = var.tags
}

data "aws_iam_policy_document" "task_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "execution" {
  name_prefix        = "${var.name}-execution-"
  assume_role_policy = data.aws_iam_policy_document.task_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

data "aws_iam_policy_document" "execution_secrets" {
  statement {
    sid       = "ReadRuntimeSecrets"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = var.runtime_secret_arns
  }
}

resource "aws_iam_role_policy" "execution_secrets" {
  name   = "read-runtime-secrets"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.execution_secrets.json
}

resource "aws_iam_role" "task" {
  name_prefix        = "${var.name}-task-"
  assume_role_policy = data.aws_iam_policy_document.task_assume.json
  tags               = var.tags
}

data "aws_iam_policy_document" "task" {
  statement {
    sid = "ApplicationBucketMetadata"
    actions = [
      "s3:GetBucketLocation",
      "s3:ListBucket"
    ]
    resources = [var.application_bucket_arn]
  }

  statement {
    sid = "ApplicationObjects"
    actions = [
      "s3:AbortMultipartUpload",
      "s3:DeleteObject",
      "s3:GetObject",
      "s3:ListMultipartUploadParts",
      "s3:PutObject"
    ]
    resources = ["${var.application_bucket_arn}/*"]
  }

  dynamic "statement" {
    for_each = var.firehose_stream_arn != "" ? [1] : []

    content {
      sid       = "PublishAuditEvents"
      actions   = ["firehose:PutRecord", "firehose:PutRecordBatch"]
      resources = [var.firehose_stream_arn]
    }
  }

  statement {
    sid = "UseApplicationEncryptionKey"
    actions = [
      "kms:Decrypt",
      "kms:DescribeKey",
      "kms:Encrypt",
      "kms:GenerateDataKey",
      "kms:ReEncrypt*",
    ]
    resources = [var.kms_key_arn]
  }

  dynamic "statement" {
    for_each = var.enable_execute_command ? [1] : []

    content {
      sid = "EcsExecChannels"
      actions = [
        "ssmmessages:CreateControlChannel",
        "ssmmessages:CreateDataChannel",
        "ssmmessages:OpenControlChannel",
        "ssmmessages:OpenDataChannel"
      ]
      resources = ["*"]
    }
  }

  dynamic "statement" {
    for_each = length(var.database_connect_resource_arns) > 0 ? [1] : []

    content {
      sid       = "ConnectToDatabaseWithIam"
      actions   = ["rds-db:connect"]
      resources = var.database_connect_resource_arns
    }
  }

  # Invocar el modelo de Bedrock. Mismo patron que los dos statements de arriba:
  # sin ARN no hay statement, asi que el entorno que no use Bedrock no gana el
  # permiso aunque comparta modulo.
  #
  # La lista que llega NO es un ARN, son cuatro, y esa es la trampa cara de este
  # permiso. Los modelos recientes -de cualquier proveedor: Anthropic, DeepSeek,
  # Amazon Nova, Meta- se invocan por un perfil de inferencia entre regiones, e
  # IAM evalua dos cosas distintas: el ARN del perfil -que lleva account-id- y el
  # ARN del modelo base EN CADA REGION a la que ese perfil pueda enrutar -que no
  # lleva account-id-. Conceder solo el perfil da apply verde, despliegue verde y
  # un AccessDeniedException intermitente que solo aparece cuando el enrutador
  # manda la peticion a una region que falta en la politica.
  #
  # Este modulo no sabe -ni tiene por que- de que familia es el modelo: recibe
  # ARN ya compuestos. Quien los compone es el root, a partir de un unico
  # identificador de perfil, para que cambiar de familia no obligue a tocar esta
  # politica.
  #
  # Ninguna accion de KMS nueva: Bedrock con la clave gestionada por AWS no
  # exige nada del llamante, y el rol ya tiene la CMK del entorno mas arriba.
  dynamic "statement" {
    for_each = length(var.bedrock_model_arns) > 0 ? [1] : []

    content {
      sid = "InvokeBedrockModels"
      actions = compact([
        "bedrock:InvokeModel",
        var.bedrock_streaming_enabled ? "bedrock:InvokeModelWithResponseStream" : "",
      ])
      resources = var.bedrock_model_arns
    }
  }
}

resource "aws_iam_role_policy" "task" {
  name   = "application-runtime"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.task.json
}

locals {
  # Los nombres de contenedor se declaran una vez y se referencian desde las
  # dependencias. Antes se leian de vuelta con local.container_definition.name,
  # que dejo de resolverse cuando esa definicion pasa por merge().
  backend_container_name   = "backend"
  telemetry_container_name = "telemetry"

  telemetry_enabled = var.telemetry_sidecar_enabled

  telemetry_cpu    = local.telemetry_enabled ? var.telemetry_sidecar_cpu : 0
  telemetry_memory = local.telemetry_enabled ? var.telemetry_sidecar_memory : 0

  telemetry_volume_name = "telemetry-queue"
  telemetry_queue_mount = "/var/lib/otelcol"

  # El sidecar arranca ANTES que el backend y, por simetria, ECS lo para al
  # final: el orden de parada es el inverso del de arranque. Eso le da al
  # colector la ventana entera de drenaje despues de que el backend deje de
  # emitir, que es exactamente cuando hace falta. condition = "START" y no
  # "HEALTHY" porque la imagen es distroless -sin shell ni curl- y no hay health
  # check que ECS pueda ejecutar dentro de ella; esperar a HEALTHY dejaria el
  # backend bloqueado para siempre.
  #
  # La clave se anade con merge y no se pone a null: un "dependsOn": null en el
  # JSON no es lo mismo que no declararla, y deja una diferencia permanente
  # contra lo que AWS devuelve normalizado.
  backend_depends_on = local.telemetry_enabled ? {
    dependsOn = [{
      containerName = local.telemetry_container_name
      condition     = "START"
    }]
  } : {}

  container_definition = merge({
    name      = local.backend_container_name
    image     = var.image_uri
    essential = true
    cpu       = var.cpu - var.cloudflare_tunnel_cpu - local.telemetry_cpu
    memory    = var.memory - var.cloudflare_tunnel_memory - local.telemetry_memory

    portMappings = [{
      name          = "http"
      containerPort = var.container_port
      hostPort      = var.container_port
      protocol      = "tcp"
      appProtocol   = "http"
    }]

    # El presupuesto es startPeriod + retries * interval desde que arranca el
    # contenedor. Con 60 y 5 la aplicacion no llegaba: tarda entre 90 y 120 segundos
    # en levantar, asi que gastaba dos reintentos antes de estar viva, y el tercero
    # llegaba justo cuando el DispatcherServlet se inicializa de forma perezosa con
    # la primera peticion —que es el propio health check— y no cabia en 5 segundos.
    # El contenedor moria por lento, no por caido.
    healthCheck = {
      command     = ["CMD-SHELL", "curl --fail --silent --show-error http://localhost:${var.container_port}${var.health_check_path} >/dev/null || exit 1"]
      interval    = 30
      timeout     = 10
      retries     = 3
      startPeriod = 180
    }

    environment = [for key in sort(keys(var.environment_variables)) : {
      name  = key
      value = var.environment_variables[key]
    }]

    secrets = [for key in sort(keys(var.secrets)) : {
      name      = key
      valueFrom = var.secrets[key]
    }]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.backend.name
        awslogs-region        = data.aws_region.current.region
        awslogs-stream-prefix = "backend"
      }
    }

    linuxParameters = {
      initProcessEnabled = true
    }

    readonlyRootFilesystem = false
    stopTimeout            = 30
  }, local.backend_depends_on)

  cloudflare_tunnel_definition = {
    name      = "cloudflare-tunnel"
    image     = var.cloudflare_tunnel_image
    essential = true
    cpu       = var.cloudflare_tunnel_cpu
    memory    = var.cloudflare_tunnel_memory

    # El formato de log se selecciona con --output, no con --logformat: esa bandera
    # no existe en cloudflared y el binario sale con "Incorrect Usage" sin llegar a
    # abrir el tunel. Como el contenedor es essential, se lleva la tarea entera.
    command = [
      "tunnel",
      "--protocol",
      "http2",
      "--loglevel",
      "info",
      "--output",
      "json",
      "--metrics",
      "0.0.0.0:2000",
      "run",
    ]

    secrets = [{
      name      = "TUNNEL_TOKEN"
      valueFrom = var.cloudflare_tunnel_secret_arn
    }]

    dependsOn = [{
      containerName = local.backend_container_name
      condition     = "HEALTHY"
    }]

    healthCheck = {
      command     = ["CMD", "cloudflared", "tunnel", "ready", "--metrics", "localhost:2000"]
      interval    = 30
      timeout     = 5
      retries     = 3
      startPeriod = 30
    }

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.cloudflare_tunnel.name
        awslogs-region        = data.aws_region.current.region
        awslogs-stream-prefix = "cloudflared"
      }
    }

    linuxParameters = {
      initProcessEnabled = true
    }

    readonlyRootFilesystem = true
    stopTimeout            = 30
  }

  telemetry_config = local.telemetry_enabled ? templatefile("${path.module}/templates/otel-collector.yaml.tftpl", {
    otlp_endpoint            = trimsuffix(var.telemetry_otlp_endpoint, "/")
    memory_limit_mib         = var.telemetry_sidecar_memory_limit_mib
    memory_spike_limit_mib   = var.telemetry_sidecar_memory_spike_limit_mib
    queue_size               = var.telemetry_queue_size
    queue_consumers          = var.telemetry_queue_consumers
    retry_max_elapsed_time   = var.telemetry_retry_max_elapsed_time
    self_metrics_interval_ms = var.telemetry_self_metrics_interval_ms
    self_service_name        = "${var.name}-telemetry-sidecar"
    self_service_namespace   = "mainvet"
    environment_name         = var.telemetry_environment_name
  }) : ""

  telemetry_definition = {
    name = local.telemetry_container_name

    image = var.telemetry_sidecar_image

    # essential = false a proposito: si el colector cae, la API sigue en pie. El
    # precio de esa decision es que su muerte es silenciosa -ECS no reemplaza la
    # tarea ni emite una parada-, y por eso existe la alarma dedicada del modulo
    # de monitoreo. Sin ella, esta bandera seria una forma de perder telemetria
    # sin enterarse.
    essential = false
    cpu       = var.telemetry_sidecar_cpu
    memory    = var.telemetry_sidecar_memory

    # 120 segundos es el maximo que Fargate respeta en stopTimeout. Es la ventana
    # que tiene el colector, ya sin backend emitiendo, para drenar a Grafana
    # Cloud lo que le quede en la cola antes de que ECS lo mate. Lo que no drene
    # sigue en el volumen, pero el volumen de tarea muere con la tarea: por eso
    # interesa que drene aqui y no confiar en el disco para sobrevivir a un
    # reemplazo.
    stopTimeout = 120

    # La configuracion entera viaja en una variable de entorno y el binario la
    # lee de ahi. Evita hornear una imagen propia solo para meter un YAML.
    command = ["--config=env:OTELCOL_CONFIG"]

    environment = [{
      name  = "OTELCOL_CONFIG"
      value = local.telemetry_config
    }]

    secrets = [
      {
        name      = "GRAFANA_OTLP_USERNAME"
        valueFrom = "${var.telemetry_credentials_secret_arn}:OTLP_USERNAME::"
      },
      {
        name      = "GRAFANA_OTLP_API_KEY"
        valueFrom = "${var.telemetry_credentials_secret_arn}:OTLP_API_KEY::"
      },
    ]

    mountPoints = [{
      sourceVolume  = local.telemetry_volume_name
      containerPath = local.telemetry_queue_mount
      readOnly      = false
    }]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        # one() y no [0]: Terraform evalua las dos ramas de un condicional aunque
        # solo use una, asi que con el sidecar apagado -y la lista de log groups
        # vacia- un indice fijo revienta el plan del entorno entero.
        awslogs-group         = one(aws_cloudwatch_log_group.telemetry[*].name)
        awslogs-region        = data.aws_region.current.region
        awslogs-stream-prefix = "telemetry"
      }
    }

    linuxParameters = {
      initProcessEnabled = true
    }

    # POR QUE ROOT, y no es un descuido. La imagen del colector es distroless y
    # corre como UID 10001, pero los volumenes de tarea de Fargate se montan
    # propiedad de root sin heredar el UID del contenedor. Con el usuario de la
    # imagen, la extension file_storage no puede crear /var/lib/otelcol/queue y
    # el colector muere en el arranque: exactamente el sintoma que se busca
    # evitar, y ademas silencioso porque el contenedor no es essential. La
    # superficie que abre es acotada: sin puertos expuestos fuera de loopback,
    # con el raiz de solo lectura y sin credenciales mas alla de las dos que ya
    # necesita para hablar con Grafana Cloud.
    user = "0"

    # El colector solo escribe en el volumen montado, asi que el raiz puede ir de
    # solo lectura. AVISO: no esta ejercitado contra la imagen real. Si algun
    # componente necesitara otro path escribible -un temporal, una cache-, el
    # sintoma es el sidecar muerto nada mas arrancar y la causa aparece en su log
    # group, /ecs/<name>/telemetry.
    readonlyRootFilesystem = true
  }

  container_definitions = concat(
    [local.container_definition, local.cloudflare_tunnel_definition],
    local.telemetry_enabled ? [local.telemetry_definition] : [],
  )

  task_definition = merge({
    family                  = "${var.name}-backend"
    networkMode             = "awsvpc"
    requiresCompatibilities = ["FARGATE"]
    cpu                     = tostring(var.cpu)
    memory                  = tostring(var.memory)
    executionRoleArn        = aws_iam_role.execution.arn
    taskRoleArn             = aws_iam_role.task.arn
    runtimePlatform = {
      cpuArchitecture       = var.cpu_architecture
      operatingSystemFamily = "LINUX"
    }
    containerDefinitions = local.container_definitions
    }, var.ephemeral_storage_gib > 20 ? {
    ephemeralStorage = {
      sizeInGiB = var.ephemeral_storage_gib
    }
  } : {})
}

resource "aws_ecs_task_definition" "backend" {
  family                   = local.task_definition.family
  network_mode             = local.task_definition.networkMode
  requires_compatibilities = local.task_definition.requiresCompatibilities
  cpu                      = local.task_definition.cpu
  memory                   = local.task_definition.memory
  execution_role_arn       = local.task_definition.executionRoleArn
  task_role_arn            = local.task_definition.taskRoleArn
  container_definitions    = jsonencode(local.task_definition.containerDefinitions)

  runtime_platform {
    cpu_architecture        = local.task_definition.runtimePlatform.cpuArchitecture
    operating_system_family = local.task_definition.runtimePlatform.operatingSystemFamily
  }

  dynamic "ephemeral_storage" {
    for_each = var.ephemeral_storage_gib > 20 ? [1] : []

    content {
      size_in_gib = var.ephemeral_storage_gib
    }
  }

  # Volumen de tarea sin configuracion: en Fargate se respalda con el
  # almacenamiento efimero de la tarea. Es lo que hace que la cola del colector
  # este en disco y no en memoria, de modo que un reinicio del proceso no se
  # lleve lo pendiente. No sobrevive al reemplazo de la tarea -por eso el
  # stopTimeout de 120 segundos importa: el drenaje ordenado es la defensa, el
  # disco es solo el amortiguador-.
  dynamic "volume" {
    for_each = local.telemetry_enabled ? [1] : []

    content {
      name = local.telemetry_volume_name
    }
  }

  tags = var.tags

  lifecycle {
    precondition {
      condition     = !var.telemetry_sidecar_enabled || trimspace(var.telemetry_otlp_endpoint) != ""
      error_message = "telemetry_otlp_endpoint es obligatorio con el sidecar activo: sin destino el colector encola en disco hasta llenarse y descarta."
    }

    precondition {
      condition     = !var.telemetry_sidecar_enabled || trimspace(var.telemetry_credentials_secret_arn) != ""
      error_message = "telemetry_credentials_secret_arn es obligatorio con el sidecar activo: sin OTLP_USERNAME y OTLP_API_KEY cada entrega rebota con 401."
    }

    # Igualar el limite a la reserva no protege de nada: quien corta pasa a ser
    # el kernel, el contenedor muere por OOM sin escribir una linea y la cola que
    # este sidecar existe para proteger se queda sin quien la drene.
    precondition {
      condition     = !var.telemetry_sidecar_enabled || var.telemetry_sidecar_memory_limit_mib < var.telemetry_sidecar_memory
      error_message = "telemetry_sidecar_memory_limit_mib debe quedar por debajo de telemetry_sidecar_memory para que rechace el colector y no el kernel."
    }
  }
}

resource "aws_ecs_service" "backend" {
  name            = "backend"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.backend.arn
  desired_count   = var.desired_count

  enable_execute_command             = var.enable_execute_command
  health_check_grace_period_seconds  = var.health_check_grace_period_seconds
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200
  availability_zone_rebalancing      = "ENABLED"
  wait_for_steady_state              = true
  propagate_tags                     = "SERVICE"
  enable_ecs_managed_tags            = true

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  capacity_provider_strategy {
    capacity_provider = "FARGATE"
    base              = var.fargate_base
    weight            = var.fargate_weight
  }

  dynamic "capacity_provider_strategy" {
    for_each = var.fargate_spot_weight > 0 ? [1] : []

    content {
      capacity_provider = "FARGATE_SPOT"
      base              = 0
      weight            = var.fargate_spot_weight
    }
  }

  network_configuration {
    subnets          = var.subnet_ids
    security_groups  = var.security_group_ids
    assign_public_ip = var.assign_public_ip
  }

  tags = var.tags

  # Acota la espera de wait_for_steady_state. Sin esto rige el default del proveedor,
  # 20 minutos, y un servicio que no converge deja el apply colgado todo ese rato antes
  # de reportar el error. Diez minutos dejan margen sobre el arranque real —el
  # aprovisionamiento y el pull rondan el minuto y medio, el backend tarda otro tanto en
  # responder readiness, cloudflared solo arranca cuando el backend esta HEALTHY y el
  # scheduler todavia tarda en emitir el evento— sin castigar el diagnostico.
  timeouts {
    create = "10m"
    update = "10m"
  }

  lifecycle {
    # Application Auto Scaling and the dev scheduler own the runtime count.
    # Terraform sets the initial value but image deployments must not reset it.
    ignore_changes = [desired_count]

    precondition {
      condition     = var.fargate_weight > 0 || var.fargate_spot_weight > 0
      error_message = "Al menos un capacity provider debe tener peso mayor que cero."
    }

    precondition {
      condition     = var.cpu > (var.cloudflare_tunnel_cpu + local.telemetry_cpu) && var.memory > (var.cloudflare_tunnel_memory + local.telemetry_memory)
      error_message = "La tarea debe reservar CPU y memoria adicionales a las de sus sidecars."
    }
  }
}

resource "aws_appautoscaling_target" "backend" {
  max_capacity       = var.max_count
  min_capacity       = var.min_count
  resource_id        = "service/${aws_ecs_cluster.this.name}/${aws_ecs_service.backend.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "cpu" {
  name               = "${var.name}-backend-cpu"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.backend.resource_id
  scalable_dimension = aws_appautoscaling_target.backend.scalable_dimension
  service_namespace  = aws_appautoscaling_target.backend.service_namespace

  target_tracking_scaling_policy_configuration {
    target_value       = var.autoscaling_cpu_target
    scale_in_cooldown  = 300
    scale_out_cooldown = 60

    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
}

resource "aws_appautoscaling_policy" "memory" {
  name               = "${var.name}-backend-memory"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.backend.resource_id
  scalable_dimension = aws_appautoscaling_target.backend.scalable_dimension
  service_namespace  = aws_appautoscaling_target.backend.service_namespace

  target_tracking_scaling_policy_configuration {
    target_value       = var.autoscaling_memory_target
    scale_in_cooldown  = 300
    scale_out_cooldown = 60

    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageMemoryUtilization"
    }
  }
}
