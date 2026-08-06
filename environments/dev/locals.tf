locals {
  name = "${var.project_name}-${var.environment}"

  common_tags = merge(var.tags, {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
    CostProfile = "development"
  })

  application_bucket_name = var.application_bucket_name != "" ? var.application_bucket_name : "${local.name}-app-${data.aws_caller_identity.current.account_id}-${var.aws_region}"

  # El rol que asume "Deploy backend image dev" para aplicar. Es el mismo que
  # publica el aviso de despliegue en Slack, y el nombre lo fija el bootstrap:
  # <proyecto>-iac-<funcion>-<ambiente>.
  deployment_notifier_role_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.project_name}-iac-apply-${var.environment}"

  backend_environment = merge({
    SPRING_PROFILES_ACTIVE          = "prod"
    SERVER_FORWARD_HEADERS_STRATEGY = "framework"
    # REQUIRED cifra pero no valida la identidad del servidor. VERIFY_IDENTITY exige que la
    # root de Amazon RDS este en el truststore del JVM, y ningun JDK la trae; hasta que la
    # imagen del backend incorpore el bundle de RDS, VERIFY_IDENTITY rompe el arranque.
    DB_URL                              = "jdbc:mysql://${module.database.endpoint}:${module.database.port}/${module.database.database_name}?sslMode=REQUIRED&enabledTLSProtocols=TLSv1.2,TLSv1.3&serverTimezone=UTC"
    DB_USERNAME                         = module.database.master_username
    PDF_MAX_CONCURRENT_RENDERS          = tostring(var.pdf_max_concurrent_renders)
    PDF_ACQUIRE_TIMEOUT                 = var.pdf_acquire_timeout
    PDF_MAX_HTML_SIZE                   = var.pdf_max_html_size
    PDF_MAX_PDF_SIZE                    = var.pdf_max_pdf_size
    OTEL_EXPORTER_OTLP_PROTOCOL         = "http/protobuf"
    OTEL_EXPORTER_OTLP_METRICS_ENDPOINT = "${trimsuffix(var.grafana_otlp_endpoint, "/")}/v1/metrics"
    OTEL_EXPORTER_OTLP_LOGS_ENDPOINT    = "${trimsuffix(var.grafana_otlp_endpoint, "/")}/v1/logs"
    OTEL_EXPORTER_OTLP_TRACES_ENDPOINT  = "${trimsuffix(var.grafana_otlp_endpoint, "/")}/v1/traces"
    DEPLOYMENT_ENVIRONMENT              = var.environment
    VETSOFTWARE_INSTANCE_ID             = "ecs-fargate-spot"
    TRACING_SAMPLING                    = tostring(var.tracing_sampling)
    CORS_ALLOWED_ORIGINS                = join(",", var.cors_allowed_origins)
    EMAIL_FROM                          = var.email_from
    REGISTRATION_VERIFICATION_URL       = var.registration_verification_url
    PASSWORD_RESET_URL                  = var.password_reset_url
    CODE_RECOVERY_LOGIN_URL             = var.login_url
    EMPLOYEE_LOGIN_URL                  = var.login_url
    RECAPTCHA_ENABLED                   = tostring(var.recaptcha_enabled)
    # dev no despliega el modulo storage_audit, asi que no hay delivery stream ni permiso
    # firehose:PutRecordBatch en el task role (ecs_backend.firehose_stream_arn queda vacio).
    # Ambas banderas deben ir apagadas: publisher-enabled es la que instancia el FirehoseClient.
    AUDIT_OUTBOX_ENABLED           = "false"
    AUDIT_OUTBOX_PUBLISHER_ENABLED = "false"
    S3_BUCKET                      = aws_s3_bucket.application.id
    AWS_REGION                     = var.aws_region
    JAVA_TOOL_OPTIONS              = "-XX:MaxRAMPercentage=70.0 -XX:InitialRAMPercentage=20.0 -XX:+ExitOnOutOfMemoryError"
  }, var.backend_extra_environment)

  backend_secrets = {
    DB_PASSWORD      = "${module.database.master_secret_arn}:password::"
    REDIS_URL        = "${module.cache.connection_secret_arn}:REDIS_URL::"
    JWT_SECRET       = "${module.secrets.application_secret_arn}:JWT_SECRET::"
    RESEND_API_KEY   = "${module.secrets.application_secret_arn}:RESEND_API_KEY::"
    RECAPTCHA_SECRET = "${module.secrets.application_secret_arn}:RECAPTCHA_SECRET::"
    # EncryptedStringConverter la lee con System.getenv en un inicializador estatico,
    # no como propiedad de Spring: sin ella Hibernate no puede cargar la clase y el
    # arranque muere antes del EntityManagerFactory.
    DIAN_ENC_KEY               = "${module.secrets.application_secret_arn}:DIAN_ENC_KEY::"
    OTEL_EXPORTER_OTLP_HEADERS = "${module.secrets.grafana_secret_arn}:OTEL_EXPORTER_OTLP_HEADERS::"
  }
}
