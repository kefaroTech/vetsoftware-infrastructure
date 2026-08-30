locals {
  name = "${var.project_name}-${var.environment}"

  common_tags = merge(var.tags, {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
  })

  private_zone_name = "${var.environment}.${var.project_name}.internal"

  # El rol que asume "Terraform apply prod" y que sera tambien el que publique el
  # aviso de despliegue. El nombre lo fija el bootstrap:
  # <proyecto>-iac-<funcion>-<ambiente> -modules/github_iac_roles/main.tf:302-.
  deployment_notifier_role_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.project_name}-iac-apply-${var.environment}"

  # El informe de costos no cambia nada: consulta Cost Explorer y publica el
  # aviso. Por eso se autoriza al rol de plan y no al de apply -un cron sin
  # supervision no tiene por que poder aplicar infraestructura-.
  cost_reporter_role_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.project_name}-iac-plan-${var.environment}"

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
    # Enlaces del pie de todos los correos. Estaban solo como default del
    # application.yml -https://vetsoftware.co/...-, asi que los correos de dev
    # mandaban a quien probaba al sitio de PRODUCCION.
    EMAIL_HELP_URL                = var.email_help_url
    EMAIL_PRIVACY_URL             = var.email_privacy_url
    EMAIL_TERMS_URL               = var.email_terms_url
    REGISTRATION_VERIFICATION_URL = var.registration_verification_url
    PASSWORD_RESET_URL            = var.password_reset_url
    CODE_RECOVERY_LOGIN_URL       = var.login_url
    EMPLOYEE_LOGIN_URL            = var.login_url
    # Enlace del correo de la propuesta del asistente: el backend concatena
    # <base> + "/?token=<43 caracteres>" y la landing publica lo recoge. Estaba
    # declarada en el application.yml con default vacio y NO llegaba por entorno,
    # asi que ResendProposalLinkEmailSender escribia un warning y retornaba sin
    # enviar: el correo del prospecto anonimo no salia en ningun entorno.
    AI_PROPOSAL_LINK_BASE_URL = var.ai_proposal_link_base_url
    # Los cuatro UUID de plantilla de Resend del producto. Hasta ahora eran default
    # commiteado en el application.yml del backend: el identificador viajaba dentro de la
    # imagen y los tres entornos apuntaban siempre a la misma plantilla. Entran por
    # variable de entorno, que es justo lo que el placeholder del application.yml lee.
    REGISTRATION_VERIFICATION_TEMPLATE_ID = var.registration_verification_template_id
    PASSWORD_RESET_TEMPLATE_ID            = var.password_reset_template_id
    EMPLOYEE_INVITATION_TEMPLATE_ID       = var.employee_invitation_template_id
    APPOINTMENT_CONFIRMATION_TEMPLATE_ID  = var.appointment_confirmation_template_id
    RECAPTCHA_ENABLED                     = tostring(var.recaptcha_enabled)
    AUDIT_FIREHOSE_DELIVERY_STREAM        = module.storage_audit.delivery_stream_name
    S3_BUCKET                             = module.storage_audit.application_bucket_name
    AWS_REGION                            = var.aws_region
    JAVA_TOOL_OPTIONS                     = "-XX:MaxRAMPercentage=75.0 -XX:InitialRAMPercentage=25.0 -XX:+ExitOnOutOfMemoryError"
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
    DIAN_ENC_KEY = "${module.secrets.application_secret_arn}:DIAN_ENC_KEY::"
  }
}
