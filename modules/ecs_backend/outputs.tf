output "cluster_name" {
  value = aws_ecs_cluster.this.name
}

output "cluster_arn" {
  value = aws_ecs_cluster.this.arn
}

output "service_name" {
  value = aws_ecs_service.backend.name
}

output "service_arn" {
  value = aws_ecs_service.backend.id
}

output "task_role_arn" {
  value = aws_iam_role.task.arn
}

output "execution_role_arn" {
  value = aws_iam_role.execution.arn
}

output "log_group_name" {
  value = aws_cloudwatch_log_group.backend.name
}

# Lo consume la condicion aws:SourceArn del rol con el que CloudWatch Logs empuja
# la suscripcion hacia Firehose: sin ARN concreto, la proteccion contra el
# confused deputy se queda en "cualquier log group de la cuenta".
output "log_group_arn" {
  description = "ARN del log group del backend, para acotar por origen quien puede asumir roles en su nombre."
  value       = aws_cloudwatch_log_group.backend.arn
}

output "cloudflare_tunnel_log_group_name" {
  value = aws_cloudwatch_log_group.cloudflare_tunnel.name
}

output "cloudflare_tunnel_origin_url" {
  description = "Origen local que debe configurarse en el hostname publico del tunel remoto."
  value       = "http://localhost:${var.container_port}"
}

output "assign_public_ip" {
  description = "Indica que Fargate usa IPv4 publica para salida directa sin NAT ni Interface Endpoints."
  value       = var.assign_public_ip
}

output "capacity_provider_strategy" {
  value = {
    fargate_base        = var.fargate_base
    fargate_weight      = var.fargate_weight
    fargate_spot_weight = var.fargate_spot_weight
  }
}

output "autoscaling_range" {
  value = {
    min = var.min_count
    max = var.max_count
  }
}

output "backend_log_retention_days" {
  description = "Retencion efectiva del log group del backend, ya resuelta la excepcion del entorno."
  value       = aws_cloudwatch_log_group.backend.retention_in_days
}

output "telemetry_sidecar_log_group_name" {
  description = "Log group del sidecar colector; vacio cuando el sidecar esta apagado."
  value       = var.telemetry_sidecar_enabled ? aws_cloudwatch_log_group.telemetry[0].name : ""
}

output "telemetry_sidecar_container_name" {
  description = "Nombre del contenedor colector dentro de la tarea, el que vigila la alarma de sidecar caido."
  value       = "telemetry"
}

output "task_container_count" {
  description = "Numero de contenedores de la definicion de tarea; la alarma de sidecar caido recorre esas posiciones."
  value       = length(local.container_definitions)
}

# Contrato del sidecar. Existe para que las pruebas afirmen sobre el reparto de
# recursos, el orden de arranque y las senales durables sin tener que releer el
# JSON de la definicion de tarea, y para que quede escrito que aqui no se
# procesan logs ni se hace tail sampling.
output "telemetry_sidecar" {
  description = "Contrato del sidecar colector de trazas y metricas: reparto de recursos, durabilidad y limites deliberados."
  value = {
    enabled = var.telemetry_sidecar_enabled
    image   = var.telemetry_sidecar_image
    cpu     = local.telemetry_cpu
    memory  = local.telemetry_memory

    backend_cpu    = var.cpu - var.cloudflare_tunnel_cpu - local.telemetry_cpu
    backend_memory = var.memory - var.cloudflare_tunnel_memory - local.telemetry_memory

    memory_limit_mib = var.telemetry_sidecar_memory_limit_mib
    stop_timeout     = 120
    runs_as_root     = true
    readonly_root    = true

    # Lo que ECS garantiza: el colector arranca antes que el backend, asi que
    # para despues. El drenaje ocurre cuando ya nadie emite.
    backend_starts_after_sidecar = local.telemetry_enabled

    queue_size             = var.telemetry_queue_size
    retry_max_elapsed_time = var.telemetry_retry_max_elapsed_time

    # Las tres decisiones que hay que poder afirmar y que un cambio distraido
    # revertiria sin ruido.
    pipelines            = local.telemetry_enabled ? sort(["traces", "metrics"]) : []
    processes_logs       = false
    tail_sampling        = false
    self_metrics_durable = local.telemetry_enabled

    receiver_endpoint = "127.0.0.1:4318"
    otlp_endpoint     = trimsuffix(var.telemetry_otlp_endpoint, "/")

    # El valor del secreto nunca esta en la definicion de tarea: solo el ARN y la
    # clave JSON que ECS resuelve con el rol de ejecucion.
    credentials_in_state = false
  }
}
