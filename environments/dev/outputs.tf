output "api_url" {
  description = "URL pública de desarrollo servida por el ALB compartido."
  value       = "${var.shared_alb_listener_port == 443 ? "https" : "http"}://${var.api_domain_name}"
}

output "shared_vpc_id" {
  value = data.aws_vpc.shared.id
}

output "shared_alb_arn" {
  value = data.aws_lb.shared.arn
}

output "ecs_cluster_name" {
  value = module.backend.cluster_name
}

output "ecs_service_name" {
  value = module.backend.service_name
}

output "database_endpoint" {
  value = module.database.endpoint
}

output "valkey_endpoint" {
  value = module.cache.endpoint
}

output "application_bucket_name" {
  value = aws_s3_bucket.application.id
}

output "scheduled_shutdown_names" {
  value = module.scheduled_shutdown.schedule_names
}

output "cost_profile" {
  value = {
    backend_cpu_mib    = var.backend_cpu
    backend_memory_mib = var.backend_memory
    fargate_spot_only = (
      module.backend.capacity_provider_strategy.fargate_base == 0 &&
      module.backend.capacity_provider_strategy.fargate_weight == 0 &&
      module.backend.capacity_provider_strategy.fargate_spot_weight > 0
    )
    backend_min_tasks      = module.backend.autoscaling_range.min
    backend_max_tasks      = module.backend.autoscaling_range.max
    database_class         = var.database_instance_class
    database_backup_days   = var.database_backup_retention_days
    valkey_storage_gb      = var.valkey_maximum_data_storage_gb
    valkey_ecpu_per_second = var.valkey_maximum_ecpu_per_second
    log_retention_days     = var.log_retention_days
    dedicated_alb          = false
    dedicated_alloy        = false
  }
}
