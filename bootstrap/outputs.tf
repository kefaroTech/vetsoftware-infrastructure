output "environment" {
  description = "Ambiente propietario de este bootstrap."
  value       = var.environment
}

output "state_bucket_name" {
  description = "Bucket exclusivo del ambiente."
  value       = var.state_bucket_name
}

output "state_kms_key_arn" {
  description = "KMS key exclusiva del ambiente."
  value       = var.state_kms_key_arn
}

output "backend_hcl" {
  description = "Configuracion del state de infraestructura del ambiente."
  value = {
    bucket       = var.state_bucket_name
    key          = "${var.project_name}/${var.environment}/terraform.tfstate"
    region       = var.aws_region
    encrypt      = true
    use_lockfile = true
    kms_key_id   = var.state_kms_key_arn
  }
}

output "ecr_repository_urls" {
  description = "URI de los repositorios de imagenes exclusivos del ambiente."
  value       = module.ecr.repository_urls
}

output "github_ecr_publisher_role_arns" {
  description = "Roles productivos; el mapa queda vacio en el bootstrap de dev."
  value       = module.ecr.publisher_role_arns
}

output "github_ecr_development_publisher_role_arns" {
  description = "Roles de desarrollo; el mapa queda vacio en el bootstrap de prod."
  value       = module.ecr.development_publisher_role_arns
}

output "github_iac_role_arns" {
  description = "Roles plan/apply exclusivamente del ambiente."
  value       = module.github_iac_roles.role_arns
}

output "github_iac_environments" {
  description = "GitHub Environments vinculados por las trust policies del ambiente."
  value       = module.github_iac_roles.github_environments
}

output "github_oidc_provider_arn" {
  description = "Proveedor OIDC externo reutilizado sin transferir propiedad entre ambientes."
  value       = var.existing_github_oidc_provider_arn
}
