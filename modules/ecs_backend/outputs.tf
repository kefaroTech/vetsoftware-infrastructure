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

output "cloudflare_tunnel_log_group_name" {
  value = aws_cloudwatch_log_group.cloudflare_tunnel.name
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
