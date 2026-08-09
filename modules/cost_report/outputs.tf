output "function_name" {
  value = aws_lambda_function.this.function_name
}

output "function_arn" {
  value = aws_lambda_function.this.arn
}

output "schedule_name" {
  value = aws_scheduler_schedule.this.name
}

# Inventario declarativo para los contratos de entorno: que se informa, cuando y
# con que reloj. El punto del cambio es la puntualidad, asi que la zona horaria y
# la ausencia de ventana flexible son parte del contrato, no un detalle.
output "reporting" {
  description = "Contrato del informe de costos."
  value = {
    schedule_expression = aws_scheduler_schedule.this.schedule_expression
    timezone            = aws_scheduler_schedule.this.schedule_expression_timezone
    flexible_window     = one(aws_scheduler_schedule.this.flexible_time_window).mode
    enabled             = aws_scheduler_schedule.this.state == "ENABLED"
    runtime             = aws_lambda_function.this.runtime
    log_retention_days  = aws_cloudwatch_log_group.this.retention_in_days
  }
}
