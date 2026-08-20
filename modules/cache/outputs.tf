output "endpoint" {
  description = "Direccion del endpoint TLS del cache Valkey."
  value       = aws_elasticache_serverless_cache.this.endpoint[0].address
}

output "port" {
  description = "Puerto del endpoint TLS del cache Valkey."
  value       = aws_elasticache_serverless_cache.this.endpoint[0].port
}

output "connection_secret_arn" {
  description = "ARN del secreto que publica la REDIS_URL completa que consume el backend."
  value       = aws_secretsmanager_secret.connection.arn
}

output "name" {
  description = "Nombre del cache serverless creado."
  value       = aws_elasticache_serverless_cache.this.name
}

# Contrato explicito para las raices: permite afirmar desde environments/* que el
# cache quedo cifrado con la CMK del entorno y no con la clave de AWS, igual que
# hacen database y account_baseline con sus propios recursos.
output "encrypted_with_cmk" {
  description = "Verdadero cuando el cache cifra en reposo con la CMK del entorno en lugar de la clave gestionada por AWS."
  value       = var.kms_key_arn != null
}
