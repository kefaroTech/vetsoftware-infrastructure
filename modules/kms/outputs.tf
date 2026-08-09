output "key_arn" {
  value = aws_kms_key.this.arn
}

output "key_id" {
  value = aws_kms_key.this.key_id
}

output "alias_arn" {
  value = aws_kms_alias.this.arn
}

# Cada servicio que cifra con esta clave pide la data key con SU propia
# identidad, no con la de quien crea el recurso. Un servicio que falte aqui no da
# un error de permisos legible: da un fallo del servicio que lo usa -CloudTrail
# responde InsufficientEncryptionPolicyException y nombra el bucket antes que la
# clave-. Exponer la lista permite fijarla desde los contratos de entorno.
output "authorized_services" {
  description = "Servicios AWS autorizados a usar la CMK."
  value = sort(distinct(flatten([
    for statement in jsondecode(data.aws_iam_policy_document.this.json).Statement :
    try(flatten([statement.Principal.Service]), [])
  ])))
}
