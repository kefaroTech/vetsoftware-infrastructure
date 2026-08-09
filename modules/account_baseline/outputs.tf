output "trail_arn" {
  value = aws_cloudtrail.this.arn
}

output "trail_bucket_name" {
  value = aws_s3_bucket.trail.id
}

output "access_logs_bucket_name" {
  description = "Destino del server access logging. Los roots lo cablean en cada bucket regulado."
  value       = aws_s3_bucket.access_logs.id
}

output "guardduty_detector_id" {
  value = length(aws_guardduty_detector.this) > 0 ? aws_guardduty_detector.this[0].id : null
}

# Inventario declarativo para que los contratos de entorno afirmen sobre la
# trazabilidad sin leer cada recurso, igual que hace el modulo de monitoreo con
# su contrato de alertas.
output "traceability" {
  description = "Que queda registrado en la cuenta, con que garantias y que cuesta."
  value = {
    multi_region          = aws_cloudtrail.this.is_multi_region_trail
    global_service_events = aws_cloudtrail.this.include_global_service_events
    log_file_validation   = aws_cloudtrail.this.enable_log_file_validation
    encrypted_with_cmk    = aws_cloudtrail.this.kms_key_id == var.kms_key_arn
    evidence_retention    = var.trail_retention_days
    evidence_object_lock  = "COMPLIANCE"
    access_logs_bucket    = aws_s3_bucket.access_logs.id
    access_log_retention  = var.access_log_retention_days

    # Las tres que cuestan dinero. Un contrato de entorno que las fije en false
    # convierte "no genera coste" en algo verificable y no en una intencion.
    s3_data_events          = var.enable_s3_data_events
    guardduty_enabled       = var.enable_guardduty
    access_analyzer_enabled = var.enable_access_analyzer
  }
}
