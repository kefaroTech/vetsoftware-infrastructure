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
  default = "dev"

  validation {
    condition     = var.environment == "dev"
    error_message = "Este root module administra exclusivamente el entorno dev."
  }
}

variable "vpc_cidr" {
  description = "CIDR exclusivo de la VPC de desarrollo. No debe solaparse con el de produccion."
  type        = string
  default     = "10.50.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr debe ser un bloque CIDR IPv4 valido."
  }
}

variable "availability_zone_count" {
  description = "Cantidad de AZ propias de dev. Las subredes de datos exigen al menos dos."
  type        = number
  default     = 2

  validation {
    condition     = var.availability_zone_count >= 2 && var.availability_zone_count <= 3
    error_message = "availability_zone_count debe estar entre 2 y 3."
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
    CostCenter = "development"
  }
}

variable "api_domain_name" {
  description = "Host publico exclusivo de dev publicado mediante Cloudflare Tunnel."
  type        = string

  validation {
    condition     = length(trimspace(var.api_domain_name)) > 0
    error_message = "api_domain_name es obligatorio para enrutar dev por host."
  }
}

variable "backend_image_uri" {
  description = "Imagen ARM64 de vetsoftware-dev-backend fijada por digest ECR."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}\\.dkr\\.ecr\\.[a-z0-9-]+\\.amazonaws\\.com(\\.cn)?/vetsoftware-dev-backend@sha256:[0-9a-f]{64}$", var.backend_image_uri))
    error_message = "backend_image_uri debe usar vetsoftware-dev-backend@sha256:<64 hex>; los tags no son desplegables."
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
  default = 512
}

# 2048 -> 3072. La tarea gana un sidecar colector de 256 MiB y, aun asi, el
# backend sube en vez de bajar: de 2048 - 128 = 1920 MiB efectivos pasa a
# 3072 - 128 - 256 = 2688. No se reparte la misma tarta, se agranda.
variable "backend_memory" {
  description = "Memoria de la tarea Fargate en MiB, repartida entre backend, cloudflared y el sidecar colector."
  type        = number
  default     = 3072
}

variable "backend_extra_environment" {
  type    = map(string)
  default = {}
}

variable "backend_container_insights" {
  type    = bool
  default = false
}

variable "pdf_max_concurrent_renders" {
  type    = number
  default = 1
}

variable "pdf_acquire_timeout" {
  type    = string
  default = "30s"
}

variable "pdf_max_html_size" {
  type    = string
  default = "5MB"
}

variable "pdf_max_pdf_size" {
  type    = string
  default = "15MB"
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

# Subida de db.t4g.micro (1 GiB) a db.t4g.small (2 GiB) por crisis de memoria: seis
# RDS-EVENT-0403 con el InnoDB buffer pool forzado a 27 MiB, FreeableMemory minimo de
# 71,9 MB y SwapUsage medio de 380,9 MB. El cuello es RAM, no CPU ni disco: el storage
# gp3 sigue en 20 GiB, la instancia sigue Single-AZ y el backup sigue en siete dias.
# Al cambiar de clase hay que reconfirmar database_max_connections.
variable "database_instance_class" {
  type    = string
  default = "db.t4g.small"
}

variable "database_allocated_storage" {
  type    = number
  default = 20
}

variable "database_max_allocated_storage" {
  description = "Cero deshabilita Storage Autoscaling para fijar el costo de dev."
  type        = number
  default     = 0
}

variable "database_backup_retention_days" {
  type    = number
  default = 7

  validation {
    condition     = var.database_backup_retention_days >= 7 && var.database_backup_retention_days <= 35
    error_message = "database_backup_retention_days debe estar entre 7 y 35 dias."
  }
}

variable "valkey_major_engine_version" {
  type    = string
  default = "8"
}

# La contrasena de Valkey se genera en un recurso ephemeral y la consumen dos
# recursos distintos, ambos gobernados por esta version. Una serie de applies
# cortados los dejo escritos en ejecuciones distintas: cada uno capturo un valor
# distinto del ephemeral y, al no cambiar la version, ninguno se reescribio. El
# backend fallaba con "WRONGPASS invalid username-password pair". Subirla a 2
# fuerza a que los dos vuelvan a escribirse en el mismo apply, con el mismo valor.
variable "valkey_password_version" {
  type    = number
  default = 2
}

variable "valkey_maximum_data_storage_gb" {
  type    = number
  default = 1
}

variable "valkey_maximum_ecpu_per_second" {
  type    = number
  default = 1000
}

# El secreto de aplicacion es write-only: Terraform solo lo reescribe cuando cambia
# esta version. Subirla a 3 empuja el JSON que ahora COMPONE el modulo a partir de
# cuatro variables sueltas -jwt_secret, resend_api_key, recaptcha_secret y
# dian_enc_key- en lugar del blob APPLICATION_SECRETS_JSON. Sin el bump el apply
# sale verde y Secrets Manager sigue sirviendo el contenido viejo: el cambio
# entero seria invisible.
variable "application_secret_version" {
  type    = number
  default = 3
}

# El envio de logs por Firehose NO vive en este secreto: tiene el suyo propio
# -grafana_logs_access_key-, y por eso no aparece entre las tres variables que
# ahora componen este JSON.
#
# Sube a 2 porque el contenido ya no viene de GRAFANA_SECRETS_JSON: lo compone el
# modulo con otlp_username, otlp_api_key y otel_exporter_otlp_headers. El
# atributo es write-only, asi que sin este bump el secreto se quedaria con el
# blob anterior y el cambio no llegaria a Secrets Manager.
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
# modules/secrets, que es quien fija los nombres de clave; aqui solo viajan los
# valores. Las claves del secreto NO cambian: las leen por sufijo las
# definiciones de tarea de ECS en locals.tf.
#
# Todas son ephemeral: no entran al state ni al plan.
# ---------------------------------------------------------------------------

variable "jwt_secret" {
  description = "Clave de firma de los JWT de dev, minimo 32 caracteres; inyectar mediante TF_VAR_jwt_secret."
  type        = string
  sensitive   = true
  ephemeral   = true
}

variable "resend_api_key" {
  description = "Clave de API de Resend usada por dev para enviar correo; inyectar mediante TF_VAR_resend_api_key."
  type        = string
  sensitive   = true
  ephemeral   = true
}

variable "recaptcha_secret" {
  description = "Secreto de servidor de reCAPTCHA de dev; inyectar mediante TF_VAR_recaptcha_secret."
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

# El sidecar no usa la cabecera OTLP ya construida: se autentica con la extension
# basicauth, que quiere usuario y contrasena por separado. Son estas dos
# -otlp_username es el numeric ID de la instancia, otlp_api_key el token- y de
# ellas sale precisamente el Basic de otel_exporter_otlp_headers. Si faltan, el
# colector arranca, encola en disco y cada entrega rebota con 401: un fallo que
# solo se ve en su propio log group, nunca en la aplicacion, y que ademas llena
# la cola hasta empezar a descartar.
variable "otlp_username" {
  description = "Numeric instance ID de Grafana Cloud usado como usuario OTLP; lo consume el sidecar colector con basicauth."
  type        = string
  sensitive   = true
  ephemeral   = true

  validation {
    condition     = !var.telemetry_sidecar_enabled || length(var.otlp_username) > 0
    error_message = "Con telemetry_sidecar_enabled, otlp_username es obligatoria: el sidecar se autentica con basicauth, no con la cabecera ya construida."
  }
}

variable "otlp_api_key" {
  description = "Token de la Cloud Access Policy de Grafana Cloud usado como contrasena OTLP; lo consume el sidecar colector con basicauth."
  type        = string
  sensitive   = true
  ephemeral   = true

  validation {
    condition     = !var.telemetry_sidecar_enabled || length(var.otlp_api_key) > 0
    error_message = "Con telemetry_sidecar_enabled, otlp_api_key es obligatoria: el sidecar se autentica con basicauth, no con la cabecera ya construida."
  }
}

variable "otel_exporter_otlp_headers" {
  description = "Cabecera Authorization=Basic <base64 usuario:token> con la que el backend exporta directo a Grafana Cloud; sin ella cada envio rebota con 401 y RemoteConnectionValidator impide arrancar."
  type        = string
  sensitive   = true
  ephemeral   = true

  validation {
    condition     = length(var.otel_exporter_otlp_headers) > 0
    error_message = "otel_exporter_otlp_headers es obligatoria para la exportación directa."
  }
}

variable "cloudflare_tunnel_token" {
  description = "Token del tunel remoto de desarrollo; inyectar mediante TF_VAR."
  type        = string
  sensitive   = true
  ephemeral   = true
}

variable "cloudflare_tunnel_ipv4_cidrs" {
  description = "Rangos oficiales usados por los endpoints de Cloudflare Tunnel en el puerto 7844."
  type        = list(string)
  default = [
    "198.41.192.7/32",
    "198.41.192.27/32",
    "198.41.192.37/32",
    "198.41.192.47/32",
    "198.41.192.57/32",
    "198.41.192.67/32",
    "198.41.192.77/32",
    "198.41.192.107/32",
    "198.41.192.167/32",
    "198.41.192.227/32",
    "198.41.200.13/32",
    "198.41.200.23/32",
    "198.41.200.33/32",
    "198.41.200.43/32",
    "198.41.200.53/32",
    "198.41.200.63/32",
    "198.41.200.73/32",
    "198.41.200.113/32",
    "198.41.200.193/32",
    "198.41.200.233/32",
  ]
}

variable "grafana_otlp_endpoint" {
  description = "Base OTLP de Grafana Cloud, terminada normalmente en /otlp."
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

# Privacidad y terminos SI tienen pagina propia en el front publico, y son las
# rutas reales del router: /legal/privacidad y /legal/terminos. Ayuda no la tiene
# -no existe ninguna ruta /ayuda en ninguno de los dos fronts-, asi que ese unico
# enlace se queda apuntando al sitio de marketing a falta de un destino que
# exista; inventarle una URL en dev solo produciria un 404.
variable "email_privacy_url" {
  description = "Enlace de la politica de privacidad del pie de los correos."
  type        = string
  default     = "https://dev-public.kefaro.tech/legal/privacidad"
}

variable "email_terms_url" {
  description = "Enlace de los terminos del pie de los correos."
  type        = string
  default     = "https://dev-public.kefaro.tech/legal/terminos"
}

variable "registration_verification_url" {
  description = "Pagina del front publico a la que apunta el enlace de verificacion de registro; recibe ?token=..."
  type        = string

  validation {
    condition     = startswith(var.registration_verification_url, "https://") && length(var.registration_verification_url) > 8 && !endswith(var.registration_verification_url, "/")
    error_message = "Tiene que ser una URL https sin barra final, por ejemplo https://dev-public.kefaro.tech/verify-email. Ojo al caso que motiva esta validacion: una variable de GitHub que no existe NO llega como ausente sino como cadena vacia, y una cadena vacia era hasta hoy un valor aceptado que dejaba el correo saliendo con un enlace a ninguna parte."
  }
}

variable "password_reset_url" {
  description = "Pagina del front publico a la que apunta el enlace de restablecimiento de contrasena; recibe ?token=..."
  type        = string

  validation {
    condition     = startswith(var.password_reset_url, "https://") && length(var.password_reset_url) > 8 && !endswith(var.password_reset_url, "/")
    error_message = "Tiene que ser una URL https sin barra final, por ejemplo https://dev-public.kefaro.tech/restablecer-contrasena. Ojo al caso que motiva esta validacion: una variable de GitHub que no existe NO llega como ausente sino como cadena vacia, y una cadena vacia era hasta hoy un valor aceptado que dejaba el correo saliendo con un enlace a ninguna parte."
  }
}

variable "login_url" {
  description = "Login de la aplicacion del tenant; viaja en el correo de recuperacion de codigo y en el de alta de empleado."
  type        = string

  validation {
    condition     = startswith(var.login_url, "https://") && length(var.login_url) > 8 && !endswith(var.login_url, "/")
    error_message = "Tiene que ser una URL https sin barra final, por ejemplo https://dev-public.kefaro.tech/login. Ojo al caso que motiva esta validacion: una variable de GitHub que no existe NO llega como ausente sino como cadena vacia, y una cadena vacia era hasta hoy un valor aceptado que dejaba el correo saliendo con un enlace a ninguna parte."
  }
}

# Landing publica a la que apunta el enlace del correo de la propuesta del
# asistente. El prospecto es ANONIMO: no hay sesion, y lo unico que lo separa de
# la propuesta de otro son los 43 caracteres del token. El backend construye el
# enlace concatenando en ResendProposalLinkEmailSender.send:
#
#     baseUrl + (baseUrl termina en "/" ? "" : "/") + "?token=" + token
#
# o sea que la barra final la normaliza el propio backend y no puede salir
# doble. Lo que si importa es que el valor sea el ORIGEN pelado, sin ruta: quien
# recoge el token es la landing (ruta "/") a traves de useRecuperarPropuesta, que
# lo lee de la cadena de consulta, hidrata la propuesta y sustituye la entrada
# del historial para que el token desaparezca de la barra de direcciones. Sus dos
# hermanas de arriba si llevan ruta -/verify-email, /restablecer-contrasena-
# porque apuntan a pantallas concretas; esta no, y por eso tampoco lleva barra
# final: las tres quedan sin barra al final.
#
# LLEVA DEFAULT A PROPOSITO. Con el valor vacio -que es como llega hoy desde el
# application.yml del backend, con default ""- el remitente escribe un warning y
# RETORNA SIN ENVIAR: el correo no sale, no hay excepcion, no hay metrica y no
# hay alarma. Un default por entorno hace que el enlace funcione sin depender de
# que alguien cree la variable de GitHub, y la validacion impide que un
# TF_VAR_ai_proposal_link_base_url vacio vuelva a apagarlo en silencio.
variable "ai_proposal_link_base_url" {
  description = "Origen https de la landing publica que recibe el ?token= del correo de la propuesta, sin ruta ni barra final."
  type        = string
  default     = "https://dev-public.kefaro.tech"

  validation {
    condition     = can(regex("^https://[^/]+$", var.ai_proposal_link_base_url))
    error_message = "Debe ser un origen https sin ruta ni barra final, por ejemplo https://dev-public.kefaro.tech."
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

# Alta de superadministradores de plataforma. En el perfil que carga el contenedor de
# dev estas cuatro claves NO tienen default a proposito: con el correo habilitado,
# ResendPlatformAccessEmailSender las valida al construir el bean y lanza
# IllegalStateException si falta una, asi que el contenedor no arranca, el health
# check falla y ECS entra en bucle. Antes arrancaba, respondia 202 y descartaba el
# correo con un warn: la solicitud moria sin que nadie se enterase.
#
# Las tres URLs apuntan a la CONSOLA DE PLATAFORMA (dev-admin.kefaro.tech) y NO se
# pueden sustituir por var.login_url, que es la app del tenant (dev-public): las
# pantallas /aprobar-acceso, /aceptar-invitacion y /login de este flujo solo existen
# en la consola, y el correo de bienvenida es el unico sitio donde el
# superadministrador recien creado conoce su codigo de usuario.
variable "platform_approver_email" {
  description = "Destinatario del correo de solicitud de acceso de plataforma; quien aprueba o rechaza el alta de un superadministrador."
  type        = string
}

variable "platform_access_review_base_url" {
  description = "URL base de la pantalla de revision de solicitudes en la consola de plataforma; recibe ?token=... para aprobar o rechazar."
  type        = string

  validation {
    condition     = startswith(var.platform_access_review_base_url, "https://") && length(var.platform_access_review_base_url) > 8 && !endswith(var.platform_access_review_base_url, "/")
    error_message = "Tiene que ser una URL https sin barra final. Esta variable no figura en la lista de Assert-RequiredEnvironmentVariable de .github/scripts/terraform-cycle.ps1, asi que si su variable de GitHub desaparece llega como cadena vacia y el plan la aceptaba sin decir nada."
  }
}

variable "platform_invitation_base_url" {
  description = "URL base de la pantalla de aceptacion de invitacion en la consola de plataforma; recibe ?token=... para aceptar el alta."
  type        = string

  validation {
    condition     = startswith(var.platform_invitation_base_url, "https://") && length(var.platform_invitation_base_url) > 8 && !endswith(var.platform_invitation_base_url, "/")
    error_message = "Tiene que ser una URL https sin barra final. Esta variable no figura en la lista de Assert-RequiredEnvironmentVariable de .github/scripts/terraform-cycle.ps1, asi que si su variable de GitHub desaparece llega como cadena vacia y el plan la aceptaba sin decir nada."
  }
}

variable "platform_access_login_url" {
  description = "URL de login de la consola de plataforma que viaja en el correo de bienvenida; unico canal por el que el superadministrador conoce su codigo de acceso."
  type        = string

  validation {
    condition     = startswith(var.platform_access_login_url, "https://") && length(var.platform_access_login_url) > 8 && !endswith(var.platform_access_login_url, "/")
    error_message = "Tiene que ser una URL https sin barra final. Esta variable no figura en la lista de Assert-RequiredEnvironmentVariable de .github/scripts/terraform-cycle.ps1, asi que si su variable de GitHub desaparece llega como cadena vacia y el plan la aceptaba sin decir nada."
  }
}

# Los cuatro UUID de plantilla de Resend del mismo flujo. Las plantillas se crean A
# MANO en el panel de Resend y ningun test las cubre: aqui solo viaja su identificador.
# Se declaran sin default, igual que las cuatro de arriba, para que la falta salte en el
# plan y no en el arranque: ResendPlatformAccessEmailSender valida las OCHO claves de
# vetsoftware.platform-access al construirse, y el application.yml del backend las trae
# con default vacio a proposito.
variable "platform_access_request_template_id" {
  description = "UUID de la plantilla de Resend del aviso de solicitud que recibe el aprobador; variables FULL_NAME, REQUESTER_EMAIL, REASON, REQUESTED_AT y REVIEW_URL."
  type        = string
}

variable "platform_access_approved_template_id" {
  description = "UUID de la plantilla de Resend del correo de invitacion que recibe el solicitante aprobado; variables FULL_NAME e INVITATION_URL."
  type        = string
}

variable "platform_access_rejected_template_id" {
  description = "UUID de la plantilla de Resend del correo de rechazo de la solicitud de acceso de plataforma; variable FULL_NAME."
  type        = string
}

variable "platform_access_welcome_template_id" {
  description = "UUID de la plantilla de Resend del correo de bienvenida tras aceptar la invitacion; unico canal por el que la cuenta nueva conoce el SYSTEM_USER_CODE con el que entra."
  type        = string
}

variable "recaptcha_enabled" {
  type    = bool
  default = true
}

# 0,25 -> 1,0. Muestrear en el emisor era la unica defensa cuando cada span
# viajaba directo a Grafana Cloud, y costaba caro: tres de cada cuatro trazas no
# existian, incluidas las que documentaban un error. Medido en el stack real, el
# pico fue de 0,225 spans/s al 25 %, o sea ~0,9 spans/s al 100 %, contra un
# limite de ~1.250 spans/s: tres ordenes de magnitud de margen. Lo que conservar
# lo decide despues Adaptive Traces en Grafana Cloud, que ve la traza entera; el
# emisor no puede decidirlo porque no la ve.
variable "tracing_sampling" {
  description = "Probabilidad de muestreo de trazas en el emisor; 1,0 delega la decision en Adaptive Traces."
  type        = number
  default     = 1.0

  validation {
    condition     = var.tracing_sampling >= 0 && var.tracing_sampling <= 1
    error_message = "tracing_sampling debe estar entre 0 y 1."
  }
}

variable "application_bucket_name" {
  type    = string
  default = ""
}

variable "log_retention_days" {
  type    = number
  default = 3
}

variable "alarm_email" {
  description = "Correo que recibe las notificaciones del topic SNS dev; requiere confirmar la suscripción."
  type        = string
  default     = ""
}

variable "monthly_budget_usd" {
  description = "Presupuesto mensual dev usado por AWS Budgets."
  type        = number
  default     = 35

  validation {
    condition     = var.monthly_budget_usd > 0
    error_message = "monthly_budget_usd debe ser mayor que cero en dev."
  }
}

variable "cost_anomaly_threshold_usd" {
  description = "Impacto absoluto mínimo para avisar una anomalía de costo dev."
  type        = number
  default     = 3

  validation {
    condition     = var.cost_anomaly_threshold_usd > 0
    error_message = "cost_anomaly_threshold_usd debe ser mayor que cero."
  }
}

variable "slack_workspace_id" {
  description = "ID T... del workspace autorizado en Amazon Q Developer; configurar junto con slack_channel_id."
  type        = string
  default     = ""
}

variable "slack_channel_id" {
  description = "ID C... o G... del canal Slack de alertas; configurar junto con slack_workspace_id."
  type        = string
  default     = ""
}

variable "slack_alerts_channel_id" {
  description = "Canal Slack de alarmas de dev -criticas y advertencias-. Vacio reutiliza slack_channel_id."
  type        = string
  default     = ""
}

variable "slack_infra_channel_id" {
  description = "Canal Slack de despliegues, apagados y eventos de ECS y RDS. Vacio reutiliza slack_channel_id."
  type        = string
  default     = ""
}

# Solo hace falta el dia que exista guardia: separa lo critico de las
# advertencias dentro del canal de alarmas.
variable "slack_critical_channel_id" {
  description = "Canal Slack dedicado a alarmas criticas de dev. Vacio las deja en el canal de alarmas."
  type        = string
  default     = ""
}

variable "runbook_url" {
  description = "URL del runbook citada en cada notificacion enviada a Slack."
  type        = string
  default     = ""
}

# PROVISIONAL: reconfirmar tras el primer arranque en db.t4g.small con
# SHOW GLOBAL VARIABLES LIKE 'max_connections' y ajustar este valor al medido.
#
# El parameter group deja max_connections en su formula de sistema
# -{DBInstanceClassMemory/12582880}, source: system-, asi que el motor lo
# recalcula solo al doblar la RAM: esta variable NO configura nada, solo declara
# el limite efectivo del que cuelgan los umbrales de las alarmas de conexiones.
#
# La aritmetica pura da 85 para 1 GiB y 170 para 2 GiB, pero en db.t4g.micro lo
# medido fueron 60, no 85: RDS reserva memoria y el efectivo sale en torno a 0,70
# del aritmetico. Extrapolando ese mismo factor, db.t4g.small deberia quedar
# alrededor de 120. DBInstanceClassMemory no lo expone ningun describe-*, asi que
# 120 es estimacion, no dato.
#
# Se declara por lo bajo a proposito: quedarse corto adelanta las alarmas, que es
# ruido corregible; pasarse las deja mudas y el cliente recibe "Too many
# connections" sin aviso previo.
variable "database_max_connections" {
  description = "max_connections efectivo de la instancia dev; los umbrales de conexiones se derivan de aqui."
  type        = number
  default     = 120

  validation {
    condition     = var.database_max_connections > 0
    error_message = "database_max_connections debe ser mayor que cero."
  }
}

# Con 1 GiB el swap sostenido era cronico -380,9 MB de media, pico de 540,1 MB- y
# el umbral de 128 MiB del modulo llegaba tarde: para cuando se cruzaba, la
# instancia ya estaba en el crash loop. Con 2 GiB el swap sostenido deberia
# desaparecer, asi que cualquier swap significativo vuelve a ser una senal
# temprana y no un sintoma terminal. Se endurece a 64 MiB, por encima de los
# pocos MB de paginas ociosas que Linux mueve en reposo y muy por debajo del
# territorio donde el motor ya esta perdido. La ventana sigue siendo de 15
# minutos sostenidos para que un pico aislado no despierte a nadie.
#
# Solo dev. Prod conserva el default del modulo -128 MiB- y no cambia con esto.
variable "database_swap_warning_bytes" {
  description = "Swap sostenido de RDS que confirma presion de memoria en dev; endurecido tras subir a db.t4g.small."
  type        = number
  default     = 67108864

  validation {
    condition     = var.database_swap_warning_bytes > 0
    error_message = "database_swap_warning_bytes debe ser mayor que cero."
  }
}

# Solo apaga. El encendido es manual, con el workflow "Start dev environment".
variable "scheduled_shutdown_enabled" {
  type    = bool
  default = true
}

variable "schedule_timezone" {
  type    = string
  default = "America/Bogota"
}

variable "backend_stop_schedule" {
  type    = string
  default = "cron(0 20 ? * MON-FRI *)"
}

variable "database_stop_schedule" {
  type    = string
  default = "cron(15 20 ? * MON-FRI *)"
}

# El log group del backend deja de ser un buffer de depuracion y pasa a ser la
# frontera de durabilidad del envio a Grafana Cloud: si Firehose se atasca, el
# original tiene que seguir aqui cuando alguien lo vaya a buscar. Se declara
# aparte de log_retention_days a proposito -esa la comparten flow logs, RDS,
# account_baseline y el informe de costos, y el contrato afirma que RDS retiene
# tres dias-.
variable "backend_log_retention_days" {
  description = "Retencion del log group del contenedor backend, origen del envio durable de logs."
  type        = number
  default     = 14

  validation {
    condition     = var.backend_log_retention_days >= var.log_retention_days
    error_message = "backend_log_retention_days no puede ser menor que la retencion general del entorno."
  }
}

variable "log_shipping_enabled" {
  description = "Activa el envio durable de logs del backend a Grafana Cloud por Kinesis Firehose."
  type        = bool
  default     = true
}

# La clave de acceso del endpoint de logs, en su propio secreto y no como una
# cuarta clave del de Grafana Cloud. Va aparte porque AWS solo documenta que Firehose "falla al
# conectar si el secreto no tiene el formato JSON correcto", sin aclarar si
# tolera claves hermanas, y ese fallo es silencioso y en tiempo de entrega.
#
# El formato NO es el token a secas. La plantilla oficial de CloudFormation de
# Grafana Labs lo compone como '${LogsInstanceID}:${LogsWriteToken}', y para este
# stack el instance ID de Loki es 1706326: el valor correcto es
# "1706326:glc_...". Con solo el token el apply sale verde, el stream se crea y
# no entrega absolutamente nada.
variable "grafana_logs_access_key" {
  description = "Clave de acceso del endpoint de logs de Grafana Cloud, con formato <loki_instance_id>:<token>; inyectar mediante TF_VAR."
  type        = string
  sensitive   = true
  ephemeral   = true
  default     = null

  validation {
    condition     = !var.log_shipping_enabled || can(regex("^[0-9]+:.+$", var.grafana_logs_access_key))
    error_message = "Con log_shipping_enabled, grafana_logs_access_key debe ser <loki_instance_id>:<token> -para dev, 1706326:glc_...-; solo el token no entrega nada y no da error."
  }
}

variable "grafana_logs_secret_version" {
  description = "Incremente para rotar la clave de acceso del envio durable de logs."
  type        = number
  default     = 1
}

# El endpoint es especifico del stack de Grafana Cloud y no es un secreto. Se fija
# aqui como unica fuente de verdad porque este entorno ya arrastro una vez tres
# endpoints distintos entre el plan, el apply y la documentacion.
variable "grafana_logs_firehose_endpoint" {
  description = "Endpoint de ingesta de logs por Firehose del stack de Grafana Cloud."
  type        = string
  default     = "https://aws-logs-prod-042.grafana.net/aws-logs/api/v1/push"

  validation {
    condition     = can(regex("^https://[a-z0-9.-]+/aws-logs/api/v1/push$", var.grafana_logs_firehose_endpoint))
    error_message = "grafana_logs_firehose_endpoint debe ser el endpoint HTTPS terminado en /aws-logs/api/v1/push."
  }
}

variable "log_shipping_backup_retention_days" {
  description = "Dias que sobreviven en S3 los logs que Firehose no logro entregar a Grafana Cloud."
  type        = number
  default     = 30

  validation {
    condition     = var.log_shipping_backup_retention_days >= 7
    error_message = "log_shipping_backup_retention_days debe ser al menos 7 dias."
  }
}

# ---------------------------------------------------------------------------
# Sidecar colector de trazas y metricas
#
# SE ENTREGA APAGADO, y el motivo no es prudencia generica. RemoteConnectionValidator
# -VetSoftware, @Profile({"dev","prod"}), BeanFactoryPostProcessor con
# HIGHEST_PRECEDENCE- rechaza localhost, 127.0.0.1, 0.0.0.0 y ::1 en
# management.otlp.metrics.export.url y en
# management.opentelemetry.tracing.export.otlp.endpoint, que son exactamente las
# dos propiedades que alimentan OTEL_EXPORTER_OTLP_{METRICS,TRACES}_ENDPOINT.
# Encender esto contra la imagen actual del backend no degrada la telemetria:
# impide arrancar la aplicacion, y lo hace antes de crear el DataSource.
#
# El sidecar es, por definicion, un destino local: esa validacion tiene que
# aprender a permitir loopback para las dos rutas OTLP antes de que este
# interruptor se pueda poner en true. Ese cambio vive en el repositorio de la
# aplicacion y queda fuera del alcance de este.
# ---------------------------------------------------------------------------

variable "telemetry_sidecar_enabled" {
  description = "Enruta trazas y metricas por el sidecar colector con cola en disco en lugar de exportarlas directo."
  type        = bool
  default     = false
}

variable "telemetry_sidecar_memory" {
  description = "Memoria en MiB reservada al sidecar colector dentro de la tarea."
  type        = number
  default     = 256
}

variable "telemetry_sidecar_cpu" {
  description = "Unidades de CPU reservadas al sidecar colector dentro de la tarea."
  type        = number
  default     = 64
}

# Ventanas en las que las alarmas de dev no notifican. No apagan la alarma: la
# alarma sigue evaluando y se ve en el panel, lo que se suspende son sus
# acciones. Al cerrarse la ventana CloudWatch re-evalua y re-notifica lo que siga
# mal, asi que callar no equivale a perder.
#
# El reparto sale del apagado real del entorno -ECS a las 20:00 y RDS a las
# 20:15, de lunes a viernes- mas el hecho de que dev no se enciende solo: el
# encendido es el workflow "Start dev environment", asi que los fines de semana
# el ambiente esta apagado entero.
#
#   nightly : 19:55 -> 08:05 del dia siguiente, todos los dias. Empieza cinco
#             minutos antes del primer schedule para no depender del segundo
#             exacto en que ECS baja a cero.
#   weekend : 08:00 -> 20:00 de sabado y domingo, que es el hueco que la ventana
#             nocturna no cubre.
#
# Union: dev solo notifica de lunes a viernes entre las 08:05 y las 19:55, que es
# cuando alguien lo esta usando y puede actuar. Fuera de ahi el estado sigue
# siendo visible en CloudWatch, simplemente no despierta a nadie.
#
# Lo que estas ventanas NO cubren, y hay que tenerlo presente antes de mover
# ninguna alarma a treat_missing_data = "breaching": dev apagado en horario
# habil. Pasa -el arranque es manual- y ninguna ventana programada puede
# preverlo.
variable "maintenance_mute_windows" {
  description = "Ventanas de silencio programado de las alarmas de dev; se aplican solo si scheduled_shutdown_enabled es true."
  type = map(object({
    expression  = string
    duration    = string
    description = optional(string, "")
  }))

  default = {
    nightly = {
      expression  = "cron(55 19 * * *)"
      duration    = "PT12H10M"
      description = "Apagado programado de dev: ECS a las 20:00 y RDS a las 20:15, hasta el arranque manual de la manana."
    }

    weekend = {
      expression  = "cron(0 8 * * SAT,SUN)"
      duration    = "PT12H"
      description = "Fin de semana: dev queda apagado entero porque el arranque es manual y no se ejecuta."
    }
  }

  # CloudWatch usa cron de CINCO campos -Minutes Hours Day-of-month Month
  # Day-of-week-, NO el de seis de EventBridge que usa el resto de este repo
  # para scheduled_shutdown. No lleva campo de ano y no admite "?": de hecho
  # el ejemplo de AWS es cron(0 2 * * *), con "*" a la vez en dia-del-mes y
  # dia-de-semana, que es justo lo que EventBridge prohibe.
  #
  # Esta validacion existe porque el proveedor NO valida la expresion en
  # cliente: una expresion del dialecto equivocado pasa fmt, validate, tflint,
  # los contratos y el plan, y solo revienta en el apply -despues de haber
  # modificado las alarmas-, con un "ValidationError: not valid" que no dice
  # que le molesta. Paso exactamente eso.
  validation {
    condition = alltrue([
      for w in values(var.maintenance_mute_windows) :
      can(regex("^cron\\([^ ?]+ [^ ?]+ [^ ?]+ [^ ?]+ [^ ?)]+\\)$", w.expression))
      || can(regex("^at\\(\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}\\)$", w.expression))
    ])
    error_message = "expression debe ser cron de CINCO campos -cron(Minutes Hours Day-of-month Month Day-of-week)- sin '?' ni campo de ano, o at(YYYY-MM-DDTHH:MM). El dialecto de seis campos de EventBridge que usa scheduled_shutdown NO vale aqui: CloudWatch lo rechaza en el apply, no en el plan."
  }

  # ISO 8601, minimo PT1M y maximo P15D segun la API.
  validation {
    condition = alltrue([
      for w in values(var.maintenance_mute_windows) :
      can(regex("^P(\\d+D)?(T(\\d+H)?(\\d+M)?(\\d+S)?)?$", w.duration)) && w.duration != "P"
    ])
    error_message = "duration debe ir en formato ISO 8601 entre PT1M y P15D, por ejemplo PT12H10M o P2DT12H."
  }
}

# ─── Bedrock ────────────────────────────────────────────────────────────────
#
# Fase 2.1 del plan de la propuesta comercial generada por IA: el permiso, el
# presupuesto y la alarma. Nada de esto invoca el modelo todavia, y el acceso al
# modelo en la cuenta es un formulario manual que a 2026-08-29 NO esta hecho
# (verificado: `aws bedrock get-use-case-for-model-access` sigue devolviendo
# ResourceNotFoundException y las seis cuotas de Sonnet 5 estan a 0.0).

variable "bedrock_enabled" {
  description = "Concede al rol de tarea el permiso para invocar el modelo. En false no se genera el statement y el rol no puede invocar nada; el presupuesto y la alarma NO dependen de esta bandera y siguen armados."
  type        = bool
  default     = true
}

variable "bedrock_inference_profile_id" {
  description = "Perfil de inferencia que se invoca. Verificado el 2026-08-29 en la cuenta de dev: SYSTEM_DEFINED, ACTIVE, y enruta a us-east-1, us-east-2 y us-west-2."
  type        = string
  default     = "us.anthropic.claude-sonnet-5"

  validation {
    condition     = startswith(var.bedrock_inference_profile_id, "us.")
    error_message = "El perfil tiene que empezar por \"us.\". El perfil \"global.\" existe, se invoca exactamente igual -solo cambia el prefijo- y enruta a todas las regiones soportadas. El consentimiento del prospecto declara la transferencia internacional nombrando un conjunto concreto de regiones; cambiar seis caracteres aqui deja ese texto legal describiendo algo que ya no es cierto."
  }
}

variable "bedrock_foundation_model_id" {
  description = "Modelo base al que enruta el perfil. Va en el ARN de cada region de destino, y ese ARN no lleva account-id."
  type        = string
  default     = "anthropic.claude-sonnet-5"
}

variable "bedrock_daily_spend_cap_usd" {
  description = "Tope de gasto diario en USD del asistente. Es UN solo numero con dos consumidores: se publica al contenedor como AI_PROPOSAL_DAILY_SPEND_CAP_USD -el corte que la aplicacion aplica antes de invocar- y multiplicado por 30 es el presupuesto mensual de Bedrock -el aviso-. Hasta hoy solo alimentaba el segundo. El cero esta prohibido porque no significa lo mismo en los tres sitios -bloquea toda reserva en la guarda, desarma el cubo global del filtro y deja el presupuesto sin aviso-; para apagar la funcionalidad esta bedrock_enabled."
  type        = number
  default     = 1.00

  validation {
    condition     = var.bedrock_daily_spend_cap_usd > 0 && var.bedrock_daily_spend_cap_usd <= 5
    error_message = "El tope diario de dev vive entre 0 (excluido) y 5 USD. El cero no es una forma limpia de apagar nada, y deja el sistema diciendo tres cosas distintas a la vez: ValkeyDailySpendGuard.reserve rechaza TODA reserva porque cualquier gasto supera cero; el cubo global de LoginRateLimitFilter se calculaba como financiadas*25 = 0 y consumirDiario lee el cero como AUSENCIA de limite (por eso ese calculo lleva hoy un Math.max); y el presupuesto de AWS se queda en cero, o sea sin aviso. Para retirar la funcionalidad, bedrock_enabled = false. Y pasar de 5 sin revisar el plan es como se llega a los USD 345/mes que el tope existe para impedir."
  }
}

variable "bedrock_invocation_surge_threshold" {
  description = "Invocaciones de Bedrock en cinco minutos que hacen sonar la alarma. Respaldo del tope de la aplicacion, no sustituto: solo se cruza cuando ese tope ya no corta."
  type        = number
  default     = 20
}
