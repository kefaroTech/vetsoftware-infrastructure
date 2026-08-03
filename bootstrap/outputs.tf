output "state_bucket_name" {
  description = "Bucket para backend.hcl."
  value       = aws_s3_bucket.state.id
}

output "state_kms_key_arn" {
  description = "KMS key para backend.hcl; null cuando SSE-S3 está habilitado."
  value       = var.enable_kms ? aws_kms_key.state[0].arn : null
}

output "backend_hcl" {
  description = "Configuración del state de prod en una key propia del bucket compartido."
  value = {
    bucket       = aws_s3_bucket.state.id
    key          = "${var.project_name}/prod/terraform.tfstate"
    region       = var.aws_region
    encrypt      = true
    use_lockfile = true
    kms_key_id   = var.enable_kms ? aws_kms_key.state[0].arn : null
  }
}

output "dev_backend_hcl" {
  description = "Configuración del state de dev en una key separada del mismo bucket protegido."
  value = {
    bucket       = aws_s3_bucket.state.id
    key          = "${var.project_name}/dev/terraform.tfstate"
    region       = var.aws_region
    encrypt      = true
    use_lockfile = true
    kms_key_id   = var.enable_kms ? aws_kms_key.state[0].arn : null
  }
}

output "ecr_repository_urls" {
  description = "URI de cada repositorio de imágenes."
  value       = module.ecr.repository_urls
}

output "github_ecr_publisher_role_arns" {
  description = "Configure cada valor como AWS_ECR_PUBLISH_ROLE_ARN en el environment production del repositorio GitHub correspondiente."
  value       = module.ecr.publisher_role_arns
}

output "github_ecr_development_publisher_role_arns" {
  description = "Configure cada valor como AWS_ECR_PUBLISH_ROLE_ARN en el environment development del repositorio GitHub correspondiente. Hoy solo aplica al backend."
  value       = module.ecr.development_publisher_role_arns
}

output "github_iac_role_arns" {
  description = "Configure cada ARN en el GitHub Environment IaC indicado para dev/prod y plan/apply."
  value       = module.github_iac_roles.role_arns
}

output "github_iac_environments" {
  description = "Nombres exactos de los GitHub Environments vinculados por las trust policies."
  value       = module.github_iac_roles.github_environments
}

output "github_oidc_provider_arn" {
  description = "Proveedor OIDC único de GitHub Actions reutilizado por publicación y Terraform."
  value       = local.github_oidc_provider_arn
}
