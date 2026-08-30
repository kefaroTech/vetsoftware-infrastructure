variable "project_name" {
  type    = string
  default = "vetsoftware"

  validation {
    condition     = can(regex("^[a-z0-9-]{3,20}$", var.project_name))
    error_message = "project_name debe usar minúsculas, números y guiones."
  }
}

variable "environment" {
  type    = string
  default = "prod"

  validation {
    condition     = can(regex("^[a-z0-9-]{2,12}$", var.environment))
    error_message = "environment debe usar minúsculas, números y guiones."
  }
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "tags" {
  type = map(string)
  default = {
    Owner      = "VetSoftware"
    CostCenter = "production"
  }
}

variable "vpc_cidr" {
  type    = string
  default = "10.40.0.0/16"
}

variable "availability_zone_count" {
  type    = number
  default = 2
}

variable "api_domain_name" {
  type = string

  validation {
    condition     = length(trimspace(var.api_domain_name)) > 0
    error_message = "api_domain_name es obligatorio para Cloudflare Tunnel."
  }
}

variable "backend_image_uri" {
  description = "Imagen Spring Boot de vetsoftware-backend fijada por digest ECR."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}\\.dkr\\.ecr\\.[a-z0-9-]+\\.amazonaws\\.com(\\.cn)?/vetsoftware-backend@sha256:[0-9a-f]{64}$", var.backend_image_uri))
    error_message = "backend_image_uri debe usar vetsoftware-backend@sha256:<64 hex>; los tags no son desplegables."
  }
}

variable "backend_health_check_path" {
  description = "Endpoint de readiness usado por ECS antes de iniciar cloudflared."
  type        = string
  default     = "/api/v1/actuator/health/readiness"
}

variable "backend_cpu_architecture" {
  type    = string
  default = "ARM64"
}

variable "backend_cpu" {
  type    = number
  default = 1024
}

variable "backend_memory" {
  type    = number
  default = 4096
}

variable "backend_desired_count" {
  type    = number
  default = 1
}

variable "backend_min_count" {
  type    = number
  default = 1
}

variable "backend_max_count" {
  type    = number
  default = 4
}

variable "backend_fargate_spot_weight" {
  type    = number
  default = 0
}

variable "backend_container_insights" {
  type    = bool
  default = false
}

variable "backend_extra_environment" {
  type    = map(string)
  default = {}
}

variable "pdf_max_concurrent_renders" {
  description = "Máximo de PDFs renderizados simultáneamente por tarea Fargate."
  type        = number
  default     = 2

  validation {
    condition     = var.pdf_max_concurrent_renders >= 1
    error_message = "pdf_max_concurrent_renders debe ser al menos 1."
  }
}

variable "pdf_acquire_timeout" {
  description = "Tiempo máximo que una solicitud espera por un cupo de render."
  type        = string
  default     = "30s"
}

variable "pdf_max_html_size" {
  description = "Tamaño máximo del HTML procesado por OpenHTMLToPDF."
  type        = string
  default     = "5MB"
}

variable "pdf_max_pdf_size" {
  description = "Tamaño máximo del PDF generado en memoria."
  type        = string
  default     = "25MB"
}

variable "alloy_instance_type" {
  type    = string
  default = "t4g.micro"
}

variable "alloy_instance_count" {
  description = "Mantenga 1 mientras use un gateway único; escalar requiere distribución consciente de trazas."
  type        = number
  default     = 1
}

variable "alloy_root_volume_size" {
  type    = number
  default = 8
}

variable "alloy_image" {
  type    = string
  default = "grafana/alloy:v1.18.0"
}

variable "alloy_container_memory_limit" {
  type    = string
  default = "700m"
}

variable "alloy_container_cpu_limit" {
  type    = string
  default = "1.0"
}

variable "alloy_pipeline_memory_limit" {
  type    = string
  default = "450MiB"
}

variable "alloy_pipeline_spike_limit" {
  type    = string
  default = "90MiB"
}

variable "database_name" {
  type    = string
  default = "vetsoftware"
}

variable "database_master_username" {
  type    = string
  default = "vetsoftware_admin"
}

variable "database_engine_version" {
  type    = string
  default = "8.4"
}

variable "database_parameter_group_family" {
  type    = string
  default = "mysql8.4"
}

variable "database_instance_class" {
  type    = string
  default = "db.t4g.small"
}

variable "database_allocated_storage" {
  type    = number
  default = 20
}

variable "database_max_allocated_storage" {
  type    = number
  default = 100
}

variable "database_multi_az" {
  type    = bool
  default = false
}

variable "database_backup_retention_days" {
  type    = number
  default = 7
}

# PROVISIONAL, igual que en dev: reconfirmar con
# SHOW GLOBAL VARIABLES LIKE 'max_connections' contra la instancia arrancada.
#
# Esta variable NO configura el motor -el parameter group deja la formula de
# sistema {DBInstanceClassMemory/12582880}-: solo declara el limite efectivo del
# que el modulo de monitoreo deriva los umbrales de las alarmas de conexiones.
# Hay que pasarla porque el default del modulo, 60, es el de una clase micro:
# aplicado a la db.t4g.small de produccion abriria la advertencia a 42
# conexiones y la critica a 54, muy por debajo del limite real del motor.
variable "database_max_connections" {
  description = "max_connections efectivo de la instancia de produccion; los umbrales de conexiones de las alarmas se derivan de aqui."
  type        = number
  default     = 120

  validation {
    condition     = var.database_max_connections > 0
    error_message = "database_max_connections debe ser mayor que cero."
  }
}

variable "valkey_major_engine_version" {
  type    = string
  default = "8"
}

variable "valkey_password_version" {
  type    = number
  default = 1
}

variable "valkey_maximum_data_storage_gb" {
  type    = number
  default = 10
}

variable "valkey_maximum_ecpu_per_second" {
  type    = number
  default = 5000
}

# El secreto de aplicacion es write-only: Terraform solo lo reescribe cuando cambia
# esta version. Subirla a 3 empuja el JSON que ahora COMPONE el modulo a partir de
# cuatro variables sueltas -jwt_secret, resend_api_key, recaptcha_secret y
# dian_enc_key- en lugar del blob APPLICATION_SECRETS_JSON. Sin el bump el apply
# sale verde y Secrets Manager sigue sirviendo el contenido viejo.
variable "application_secret_version" {
  type    = number
  default = 3
}

# Sube a 2 por el mismo motivo: el JSON de Grafana ya no llega armado desde
# GRAFANA_SECRETS_JSON, lo compone el modulo con otlp_username, otlp_api_key y
# otel_exporter_otlp_headers.
variable "grafana_secret_version" {
  type    = number
  default = 2
}

variable "cloudflare_tunnel_token_version" {
  type    = number
  default = 1
}

# ---------------------------------------------------------------------------
# Los siete secretos de runtime, uno por variable.
#
# Antes eran dos blobs JSON -APPLICATION_SECRETS_JSON y GRAFANA_SECRETS_JSON-
# armados a mano en los secretos de GitHub. El JSON lo compone ahora
# modules/secrets, que fija los nombres de clave; aqui solo viajan los valores.
# Las claves NO cambian: las leen por sufijo las definiciones de tarea de ECS en
# locals.tf.
#
# otel_exporter_otlp_headers es NUEVA en produccion. El secreto de Grafana de
# prod tenia solo OTLP_USERNAME y OTLP_API_KEY, que son las dos que Alloy extrae
# con jq en su user-data -templates/alloy-user-data.sh.tftpl:22-; la tercera
# clave le es indiferente porque lee por nombre, pero el modulo es compartido y
# compone el JSON entero. Sin valor, el apply de produccion se detiene en la
# validacion del modulo.
# ---------------------------------------------------------------------------

variable "jwt_secret" {
  description = "Clave de firma de los JWT de produccion, minimo 32 caracteres; inyectar mediante TF_VAR_jwt_secret."
  type        = string
  sensitive   = true
  ephemeral   = true
}

variable "resend_api_key" {
  description = "Clave de API de Resend usada por produccion para enviar correo; inyectar mediante TF_VAR_resend_api_key."
  type        = string
  sensitive   = true
  ephemeral   = true
}

variable "recaptcha_secret" {
  description = "Secreto de servidor de reCAPTCHA de produccion; inyectar mediante TF_VAR_recaptcha_secret."
  type        = string
  sensitive   = true
  ephemeral   = true
}

variable "dian_enc_key" {
  description = "Clave AES-256 -32 bytes en base64- del cifrado de campos DIAN; la lee EncryptedStringConverter con System.getenv al cargar la clase, no como propiedad de Spring."
  type        = string
  sensitive   = true
  ephemeral   = true
}

variable "otlp_username" {
  description = "Numeric instance ID de Grafana Cloud usado como usuario OTLP; Alloy lo extrae del secreto en su user-data."
  type        = string
  sensitive   = true
  ephemeral   = true
}

variable "otlp_api_key" {
  description = "Token de la Cloud Access Policy de Grafana Cloud usado como contrasena OTLP; Alloy lo extrae del secreto en su user-data."
  type        = string
  sensitive   = true
  ephemeral   = true
}

variable "otel_exporter_otlp_headers" {
  description = "Cabecera Authorization=Basic <base64 usuario:token>; la escribe el secreto compartido aunque en produccion la telemetria salga por Alloy."
  type        = string
  sensitive   = true
  ephemeral   = true
}

variable "cloudflare_tunnel_token" {
  description = "Token del tunel remoto de produccion; inyectar mediante TF_VAR."
  type        = string
  sensitive   = true
  ephemeral   = true
}

variable "grafana_otlp_endpoint" {
  description = "Base OTLP, por ejemplo https://...grafana.net/otlp."
  type        = string
}

variable "cors_allowed_origins" {
  type = list(string)
}

variable "email_from" {
  type = string
}

# Los tres enlaces del pie de TODOS los correos (HELP_URL / PRIVACY_URL /
# TERMS_URL de las plantillas). Hasta ahora no llegaban por entorno: vivian como
# default del application.yml apuntando a https://vetsoftware.co/..., de modo que
# un correo disparado desde dev llevaba a quien estuviera probando al sitio de
# PRODUCCION. Se declaran aqui para que cada entorno diga a donde manda.
variable "email_help_url" {
  description = "Enlace de ayuda del pie de los correos."
  type        = string
  default     = "https://vetsoftware.co/ayuda"
}

# En prod los tres conservan el destino que ya tenian como default del backend,
# ahora explicito y sobreescribible. Cual sea el correcto -el sitio de marketing
# vetsoftware.co o las paginas /legal/... del front productivo app.vetsoftware.co-
# es una decision de producto que nadie ha tomado, y no la invento aqui.
variable "email_privacy_url" {
  description = "Enlace de la politica de privacidad del pie de los correos."
  type        = string
  default     = "https://vetsoftware.co/privacidad"
}

variable "email_terms_url" {
  description = "Enlace de los terminos del pie de los correos."
  type        = string
  default     = "https://vetsoftware.co/terminos"
}

variable "registration_verification_url" {
  description = "Pagina del front publico a la que apunta el enlace de verificacion de registro; recibe ?token=..."
  type        = string

  validation {
    condition     = startswith(var.registration_verification_url, "https://") && length(var.registration_verification_url) > 8 && !endswith(var.registration_verification_url, "/")
    error_message = "Tiene que ser una URL https sin barra final, por ejemplo https://app.vetsoftware.co/verify-email. Ojo al caso que motiva esta validacion: una variable de GitHub que no existe NO llega como ausente sino como cadena vacia, y una cadena vacia era hasta hoy un valor aceptado que dejaba el correo saliendo con un enlace a ninguna parte."
  }
}

variable "password_reset_url" {
  description = "Pagina del front publico a la que apunta el enlace de restablecimiento de contrasena; recibe ?token=..."
  type        = string

  validation {
    condition     = startswith(var.password_reset_url, "https://") && length(var.password_reset_url) > 8 && !endswith(var.password_reset_url, "/")
    error_message = "Tiene que ser una URL https sin barra final, por ejemplo https://app.vetsoftware.co/restablecer-contrasena. Ojo al caso que motiva esta validacion: una variable de GitHub que no existe NO llega como ausente sino como cadena vacia, y una cadena vacia era hasta hoy un valor aceptado que dejaba el correo saliendo con un enlace a ninguna parte."
  }
}

variable "login_url" {
  description = "Login de la aplicacion del tenant; viaja en el correo de recuperacion de codigo y en el de alta de empleado."
  type        = string

  validation {
    condition     = startswith(var.login_url, "https://") && length(var.login_url) > 8 && !endswith(var.login_url, "/")
    error_message = "Tiene que ser una URL https sin barra final, por ejemplo https://app.vetsoftware.co/login. Ojo al caso que motiva esta validacion: una variable de GitHub que no existe NO llega como ausente sino como cadena vacia, y una cadena vacia era hasta hoy un valor aceptado que dejaba el correo saliendo con un enlace a ninguna parte."
  }
}

# Los cuatro UUID de plantilla de Resend del producto: verificacion de registro,
# restablecimiento de contrasena, invitacion de empleado y confirmacion de cita. Hasta
# ahora NO llegaban por entorno: viajaban como default commiteado en el application.yml
# del backend y ningun perfil los sobreescribia, asi que el identificador iba dentro de
# la imagen y los tres entornos apuntaban siempre a la misma plantilla de Resend.
#
# Se declaran sin default, para que la falta salte en el plan. Y ojo al modo de fallo,
# porque cambio: el backend ya NO descarta el correo en silencio. Sus cuatro remitentes
# validan la clave al construir el bean y lanzan IllegalStateException, guardados por el
# interruptor del correo, asi que un entorno con el correo habilitado y una de estas
# variables vacia NO ARRANCA y ECS entra en bucle de health check. Desplegar esta
# configuracion ANTES que la imagen del backend deja de ser una recomendacion.
variable "registration_verification_template_id" {
  description = "UUID de la plantilla de Resend del correo de verificacion de registro; alimenta vetsoftware.registration.verification-template-id en el backend."
  type        = string
}

variable "password_reset_template_id" {
  description = "UUID de la plantilla de Resend del correo de restablecimiento de contrasena; alimenta vetsoftware.password-reset.template-id en el backend."
  type        = string
}

variable "employee_invitation_template_id" {
  description = "UUID de la plantilla de Resend del correo de invitacion a un empleado; alimenta vetsoftware.employee.invitation-template-id en el backend."
  type        = string
}

variable "appointment_confirmation_template_id" {
  description = "UUID de la plantilla de Resend del correo de confirmacion de cita; alimenta vetsoftware.appointment.confirmation-template-id en el backend."
  type        = string
}

variable "recaptcha_enabled" {
  type    = bool
  default = true
}

variable "tracing_sampling" {
  type    = number
  default = 1.0

  validation {
    condition     = var.tracing_sampling >= 0 && var.tracing_sampling <= 1
    error_message = "tracing_sampling debe estar entre 0 y 1."
  }
}

variable "audit_retention_days" {
  type    = number
  default = 365
}

variable "application_bucket_name" {
  type    = string
  default = ""
}

variable "audit_bucket_name" {
  type    = string
  default = ""
}

# Sin destino no hay topic, y sin topic las alarmas se crean igual pero con
# alarm_actions vacio: el plan sale verde, el apply sale verde, la consola de
# CloudWatch muestra las alarmas bien configuradas y ninguna puede avisar a
# nadie. Por eso no tiene default -produccion no se despliega sin canal- y la
# validacion rechaza la cadena vacia antes de que llegue a AWS.
#
# El correo tambien es lo que hace existir los dos topicos de severidad, de los
# que cuelgan el ruteo de hallazgos de GuardDuty y cualquier notificacion
# futura: modules/monitoring/main.tf:8 deriva notification_topic_enabled de el.
variable "alarm_email" {
  description = "Correo que recibe las alarmas de produccion. Obligatorio: sin destino no se crea el topic SNS y las alarmas quedan sin accion. La suscripcion exige confirmacion manual desde el buzon."
  type        = string

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[a-zA-Z]{2,}$", var.alarm_email))
    error_message = "alarm_email debe ser una direccion de correo valida: produccion no puede desplegarse sin canal de alerta."
  }
}

# Los IDs de Slack no viven en el repositorio: se inyectan por TF_VAR desde el
# environment iac-apply-prod. Vacios dejan Slack apagado, y eso ya no vuelve a
# dejar produccion sin destino -alarm_email es obligatorio, asi que los topicos
# existen siempre-. El modulo valida que workspace y canal se configuren juntos.
variable "slack_workspace_id" {
  description = "ID T... del workspace autorizado en Amazon Q Developer; configurar junto con slack_channel_id."
  type        = string
  default     = ""
}

variable "slack_channel_id" {
  description = "ID C... o G... del canal Slack base de produccion; configurar junto con slack_workspace_id."
  type        = string
  default     = ""
}

variable "slack_alerts_channel_id" {
  description = "Canal Slack de alarmas de produccion -criticas y advertencias-. Vacio reutiliza slack_channel_id."
  type        = string
  default     = ""
}

variable "slack_infra_channel_id" {
  description = "Canal Slack de despliegues y eventos de ECS y RDS de produccion. Vacio reutiliza slack_channel_id."
  type        = string
  default     = ""
}

# Solo hace falta el dia que exista guardia: separa lo critico de las
# advertencias dentro del canal de alarmas.
variable "slack_critical_channel_id" {
  description = "Canal Slack dedicado a alarmas criticas de produccion. Vacio las deja en el canal de alarmas."
  type        = string
  default     = ""
}

variable "runbook_url" {
  description = "URL del runbook citada en cada notificacion enviada a Slack."
  type        = string
  default     = ""
}

variable "monthly_budget_usd" {
  type    = number
  default = 180
}

# Apagado a proposito, no por olvido. ce:CreateAnomalyMonitor exige que Cost
# Explorer este habilitado a mano en la cuenta -no se puede por API- y responde
# "User not enabled for cost explorer access" mientras no lo este. Ademas, al
# habilitarlo AWS crea por su cuenta un monitor de servicios y la cuota es de
# uno por cuenta: encender esto sin importar o borrar antes ese monitor rompe el
# apply de produccion a mitad. Dev ya pago ese peaje; la cuenta de prod es otra
# y todavia no.
variable "cost_anomaly_detection_enabled" {
  description = "Crea el monitor por servicio y la suscripcion de Cost Anomaly Detection. Requiere Cost Explorer habilitado en la cuenta de produccion."
  type        = bool
  default     = false
}

variable "cost_anomaly_threshold_usd" {
  description = "Impacto absoluto minimo en USD para avisar una anomalia de costo en produccion."
  type        = number
  default     = 10

  validation {
    condition     = var.cost_anomaly_threshold_usd > 0
    error_message = "cost_anomaly_threshold_usd debe ser mayor que cero."
  }
}

variable "log_retention_days" {
  type    = number
  default = 30
}

variable "enable_execute_command" {
  description = "ECS Exec en produccion. Da shell interactiva en el contenedor, con acceso a los secretos de runtime; activarlo enciende tambien el registro de las sesiones."
  type        = bool
  default     = false
}
