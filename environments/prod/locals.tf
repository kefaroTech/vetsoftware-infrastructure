locals {
  name = "${var.project_name}-${var.environment}"

  common_tags = merge(var.tags, {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
  })

  private_zone_name = "${var.environment}.${var.project_name}.internal"

  backend_environment = merge({
    SPRING_PROFILES_ACTIVE              = "prod"
    SERVER_FORWARD_HEADERS_STRATEGY     = "framework"
    DB_URL                              = "jdbc:mysql://${module.database.endpoint}:${module.database.port}/${module.database.database_name}?sslMode=VERIFY_IDENTITY&enabledTLSProtocols=TLSv1.2,TLSv1.3&serverTimezone=UTC"
    DB_USERNAME                         = module.database.master_username
    PDF_MAX_CONCURRENT_RENDERS          = tostring(var.pdf_max_concurrent_renders)
    PDF_ACQUIRE_TIMEOUT                 = var.pdf_acquire_timeout
    PDF_MAX_HTML_SIZE                   = var.pdf_max_html_size
    PDF_MAX_PDF_SIZE                    = var.pdf_max_pdf_size
    OTEL_EXPORTER_OTLP_METRICS_ENDPOINT = "http://${aws_route53_record.alloy.fqdn}:4318/v1/metrics"
    OTEL_EXPORTER_OTLP_LOGS_ENDPOINT    = "http://${aws_route53_record.alloy.fqdn}:4318/v1/logs"
    OTEL_EXPORTER_OTLP_TRACES_ENDPOINT  = "http://${aws_route53_record.alloy.fqdn}:4318/v1/traces"
    OTEL_EXPORTER_OTLP_HEADERS          = "x-vetsoftware-source=fargate"
    DEPLOYMENT_ENVIRONMENT              = var.environment
    VETSOFTWARE_INSTANCE_ID             = "ecs-fargate"
    TRACING_SAMPLING                    = tostring(var.tracing_sampling)
    CORS_ALLOWED_ORIGINS                = join(",", var.cors_allowed_origins)
    EMAIL_FROM                          = var.email_from
    REGISTRATION_VERIFICATION_URL       = var.registration_verification_url
    PASSWORD_RESET_URL                  = var.password_reset_url
    CODE_RECOVERY_LOGIN_URL             = var.login_url
    EMPLOYEE_LOGIN_URL                  = var.login_url
    RECAPTCHA_ENABLED                   = tostring(var.recaptcha_enabled)
    AUDIT_FIREHOSE_DELIVERY_STREAM      = module.storage_audit.delivery_stream_name
    S3_BUCKET                           = module.storage_audit.application_bucket_name
    AWS_REGION                          = var.aws_region
    JAVA_TOOL_OPTIONS                   = "-XX:MaxRAMPercentage=75.0 -XX:InitialRAMPercentage=25.0 -XX:+ExitOnOutOfMemoryError"
  }, var.backend_extra_environment)

  backend_secrets = {
    DB_PASSWORD      = "${module.database.master_secret_arn}:password::"
    REDIS_URL        = "${module.cache.connection_secret_arn}:REDIS_URL::"
    JWT_SECRET       = "${module.secrets.application_secret_arn}:JWT_SECRET::"
    RESEND_API_KEY   = "${module.secrets.application_secret_arn}:RESEND_API_KEY::"
    RECAPTCHA_SECRET = "${module.secrets.application_secret_arn}:RECAPTCHA_SECRET::"
  }
}
