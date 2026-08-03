output "repository_names" {
  description = "Nombre ECR por componente lógico."
  value       = { for key, repository in aws_ecr_repository.this : key => repository.name }
}

output "repository_urls" {
  description = "URI base ECR por componente lógico."
  value       = { for key, repository in aws_ecr_repository.this : key => repository.repository_url }
}

output "publisher_role_arns" {
  description = "Role ARN productivo por repositorio habilitado."
  value       = { for key, role in aws_iam_role.github_ecr : key => role.arn }
}

output "development_publisher_role_arns" {
  description = "Role ARN de desarrollo por repositorio habilitado."
  value       = { for key, role in aws_iam_role.github_ecr_development : key => role.arn }
}

output "development_tag_prefix" {
  description = "Prefijo que deben usar los tags publicados desde develop."
  value       = var.development_tag_prefix
}
