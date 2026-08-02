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
    cpu       = var.cpu
    memory    = var.memory

    portMappings = [{
      name          = "http"
      containerPort = var.container_port
      hostPort      = var.container_port
      protocol      = "tcp"
      appProtocol   = "http"
    }]

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
    containerDefinitions = [local.container_definition]
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

  load_balancer {
    target_group_arn = var.target_group_arn
    container_name   = local.container_definition.name
    container_port   = var.container_port
  }

  tags = var.tags

  lifecycle {
    precondition {
      condition     = var.fargate_weight > 0 || var.fargate_spot_weight > 0
      error_message = "Al menos un capacity provider debe tener peso mayor que cero."
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
