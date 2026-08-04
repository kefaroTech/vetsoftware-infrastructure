data "aws_region" "current" {}

resource "aws_ecs_cluster" "this" {
  name = var.name

  setting {
    name  = "containerInsights"
    value = var.enable_container_insights ? "enhanced" : "disabled"
  }

  tags = var.tags
}

resource "aws_cloudwatch_log_group" "backend" {
  name              = "/ecs/${var.name}/backend"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn
  tags              = var.tags
}

resource "aws_cloudwatch_log_group" "cloudflare_tunnel" {
  name              = "/ecs/${var.name}/cloudflare-tunnel"
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
}

resource "aws_iam_role_policy" "task" {
  name   = "application-runtime"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.task.json
}

locals {
  container_definition = {
    name      = "backend"
    image     = var.image_uri
    essential = true
    cpu       = var.cpu - var.cloudflare_tunnel_cpu
    memory    = var.memory - var.cloudflare_tunnel_memory

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
  }

  cloudflare_tunnel_definition = {
    name      = "cloudflare-tunnel"
    image     = var.cloudflare_tunnel_image
    essential = true
    cpu       = var.cloudflare_tunnel_cpu
    memory    = var.cloudflare_tunnel_memory

    command = [
      "tunnel",
      "--protocol",
      "http2",
      "--loglevel",
      "info",
      "--logformat",
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
      containerName = local.container_definition.name
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
    containerDefinitions = [local.container_definition, local.cloudflare_tunnel_definition]
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

  tags = var.tags
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
      condition     = var.cpu > var.cloudflare_tunnel_cpu && var.memory > var.cloudflare_tunnel_memory
      error_message = "La tarea debe reservar CPU y memoria adicionales al sidecar Cloudflare Tunnel."
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
