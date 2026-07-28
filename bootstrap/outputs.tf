output "state_bucket_name" {
  description = "Bucket para backend.hcl."
  value       = aws_s3_bucket.state.id
}

output "state_kms_key_arn" {
  description = "KMS key para backend.hcl; null cuando SSE-S3 está habilitado."
  value       = var.enable_kms ? aws_kms_key.state[0].arn : null
}

output "backend_hcl" {
  description = "Configuración sugerida del backend remoto."
  value = {
    bucket       = aws_s3_bucket.state.id
    key          = "${var.project_name}/${var.environment}/terraform.tfstate"
    region       = var.aws_region
    encrypt      = true
    use_lockfile = true
    kms_key_id   = var.enable_kms ? aws_kms_key.state[0].arn : null
  }
}
