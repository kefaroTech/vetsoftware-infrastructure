locals {
  name = "${var.project_name}-${var.environment}"

  common_tags = merge(var.tags, {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
    CostProfile = "development"
  })

  application_bucket_name = var.application_bucket_name != "" ? var.application_bucket_name : "${local.name}-app-${data.aws_caller_identity.current.account_id}-${var.aws_region}"

  # Misma condicion que aplica el modulo de monitoreo: sin los dos IDs no hay
  # configuracion de Amazon Q, y sin ella el topic de alertas no llega a Slack.
  slack_notifications_enabled = trimspace(var.slack_workspace_id) != "" && trimspace(var.slack_channel_id) != ""

  # El rol que asume "Deploy backend image dev" para aplicar. Es el mismo que
  # publica el aviso de despliegue en Slack, y el nombre lo fija el bootstrap:
  # <proyecto>-iac-<funcion>-<ambiente>.
  deployment_notifier_role_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.project_name}-iac-apply-${var.environment}"

  # El informe diario de costos no cambia nada: consulta Cost Explorer y publica el
  # aviso. Por eso corre con el rol de plan y no con el de apply -un cron sin
  # supervision no tiene por que poder aplicar infraestructura-.
  cost_reporter_role_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.project_name}-iac-plan-${var.environment}"

  grafana_otlp_base = trimsuffix(var.grafana_otlp_endpoint, "/")

  # Los tres endpoints OTLP, y por que solo dos de ellos se mueven.
  #
  # TRAZAS y METRICAS son las senales que este cambio existe para proteger:
  # salian por OTLP directo con una cola en memoria que descarta en silencio en
  # cuanto Grafana Cloud tarda en responder. Con el sidecar activo apuntan al
  # colector local, que las guarda en disco y reintenta media hora.
  #
  # LOGS no se mueve, y no es un olvido. Su durabilidad ya esta resuelta fuera de
  # la tarea -stdout -> CloudWatch -> Firehose -> Grafana Cloud, modules/
  # log_shipping-, asi que meterlos en el sidecar no anadiria una sola garantia y
  # si duplicaria la ruta. El sidecar no declara pipeline de logs a proposito:
  # apuntar esta variable al colector daria 404 en /v1/logs y la exportacion OTLP
  # de logs -que sigue encendida en la aplicacion, apagarla es una fase
  # posterior- se romperia sin que nada mas lo notara. Se queda en el gateway.
  #
  # El interruptor tiene que ser reversible de verdad: con
  # telemetry_sidecar_enabled = false, estas tres lineas producen exactamente los
  # mismos valores que antes de este cambio. Un interruptor que deja localhost
  # cableado no apaga el sidecar, corta la telemetria.
  otlp_traces_endpoint  = var.telemetry_sidecar_enabled ? "http://localhost:4318/v1/traces" : "${local.grafana_otlp_base}/v1/traces"
  otlp_metrics_endpoint = var.telemetry_sidecar_enabled ? "http://localhost:4318/v1/metrics" : "${local.grafana_otlp_base}/v1/metrics"
  otlp_logs_endpoint    = "${local.grafana_otlp_base}/v1/logs"

  # Las regiones a las que el dato del prospecto puede viajar.
  #
  # No es una preferencia nuestra ni una lista de conveniencia: es lo que
  # publica el propio perfil de inferencia. Verificado el 2026-08-29 con
  # `aws bedrock get-inference-profile --inference-profile-identifier
  # us.anthropic.claude-sonnet-5`, cuya descripcion dice literalmente "Routes
  # requests to Anthropic Claude Sonnet 5 in us-east-1, us-east-2 and
  # us-west-2" y cuyo array `models` devuelve los tres ARN correspondientes.
  #
  # Esta escrita, y no derivada de var.aws_region, porque tiene dos lectores
  # distintos y ninguno de los dos puede adivinarla:
  #
  #  - IAM. El perfil enruta a tres regiones y la politica necesita el modelo
  #    base de LAS TRES. Omitir una no da error de apply ni de despliegue: da un
  #    AccessDeniedException intermitente que solo aparece cuando el enrutador
  #    elige la region que falta.
  #  - El texto legal. El dueno decidio que el dato puede salir de Colombia y
  #    que el consentimiento del prospecto declara la transferencia
  #    internacional de forma expresa. Lo que ese consentimiento tiene que
  #    nombrar es exactamente esta lista: ampliarla -o pasar al perfil global.,
  #    que enruta a todas las regiones soportadas- obliga a cambiar la politica
  #    de privacidad antes, no despues.
  #
  # OJO AL CAMBIAR DE MODELO. Esta lista NO se deriva del identificador y no hay
  # nada en este repositorio que pueda derivarla: el conjunto de regiones lo
  # publica cada perfil por separado y no es el mismo para todas las familias.
  # Cambiar el modelo es cambiar un valor -ver bedrock_inference_profile_id- MAS
  # volver a ejecutar `aws bedrock get-inference-profile
  # --inference-profile-identifier <perfil nuevo>` y contrastar su array
  # `models` con estas tres regiones. Si el perfil nuevo enruta a un conjunto
  # distinto, hay dos consecuencias y las dos son caras: la politica concede
  # modelos base de regiones que no son -AccessDenied intermitente en las que
  # falten- y el consentimiento del prospecto nombra regiones que ya no
  # describen el sistema. El gate no puede verlo: no llama a la API de AWS.
  bedrock_routing_regions = ["us-east-1", "us-east-2", "us-west-2"]

  # El modelo base y el proveedor NO se escriben: se parten del identificador del
  # perfil, que ya los lleva dentro.
  #
  # POR QUE. Un perfil de inferencia entre regiones se nombra
  # "<geografia>.<proveedor>.<modelo>", y el modelo base al que enruta es
  # literalmente ese mismo identificador sin el prefijo de geografia:
  # "us.anthropic.claude-sonnet-5" enruta a "anthropic.claude-sonnet-5", igual
  # que "us.deepseek.r1-v1:0" enruta a "deepseek.r1-v1:0". Mientras el modelo
  # base fue una VARIABLE aparte, cambiar de familia eran dos ediciones que
  # podian separarse -y separarlas no da error de apply: da un perfil de una
  # familia con los modelos base de otra, o sea AccessDeniedException en la
  # primera invocacion real, con un mensaje que no nombra el desajuste-.
  # Derivandolo, cambiar de Sonnet a un modelo de DeepSeek es cambiar UN valor y
  # la politica de IAM lo sigue sola.
  #
  # QUE ASUME, y hay que decirlo porque es una convencion de AWS y no una ley:
  # que el perfil regional se llama igual que su modelo base con el prefijo
  # delante. Es cierto para todos los perfiles us.* publicados hasta hoy, y la
  # forma de comprobarlo para uno nuevo es el mismo `get-inference-profile` que
  # ya hay que ejecutar para las regiones. Si algun dia AWS rompiera esa
  # convencion, lo que hay que cambiar es esta linea, no la politica.
  bedrock_foundation_model_id = trimprefix(var.bedrock_inference_profile_id, "us.")

  # El proveedor, para el contrato. No compone ningun ARN: existe para que
  # tests/configuration.tftest.hcl pueda afirmar que el perfil y el modelo base
  # concedido son de la MISMA familia sin escribir en ninguna parte cual es esa
  # familia. La validacion de forma de bedrock_inference_profile_id garantiza que
  # este indice existe.
  bedrock_model_provider = split(".", var.bedrock_inference_profile_id)[1]

  # Cuatro ARN, no uno, y los cuatro con forma distinta a proposito.
  #
  # El del perfil LLEVA account-id y va en la region desde la que se invoca. Los
  # de los modelos base NO llevan account-id -de ahi los dos puntos seguidos- y
  # va uno por region de destino.
  #
  # Se componen aqui en vez de escribirse a mano porque el account-id sale del
  # data source de la cuenta: es lo unico que garantiza que prod, que es otra
  # cuenta, no herede el ARN de dev por un copiar y pegar. Encender Bedrock en
  # prod es poner bedrock_enabled = true en su root; no hay ningun numero que
  # trasladar.
  #
  # Y desde hoy tampoco hay ningun NOMBRE DE MODELO que trasladar: los cuatro
  # cuelgan de var.bedrock_inference_profile_id. Ninguna cadena de esta politica
  # nombra a Anthropic.
  bedrock_model_arns = var.bedrock_enabled ? concat(
    [
      "arn:aws:bedrock:${var.aws_region}:${data.aws_caller_identity.current.account_id}:inference-profile/${var.bedrock_inference_profile_id}",
    ],
    [
      for region in local.bedrock_routing_regions :
      "arn:aws:bedrock:${region}::foundation-model/${local.bedrock_foundation_model_id}"
    ]
  ) : []

  # El presupuesto no se escribe: se deriva del tope diario, y el tope diario es
  # ahora el que la aplicacion aplica de verdad.
  #
  # QUE DECIA ESTE COMENTARIO Y POR QUE ERA FALSO. Afirmaba que derivarlo hacia
  # la desalineacion "imposible por construccion". No lo era, y la frase es
  # exactamente lo que hizo que nadie mirara: el numero de aqui alimentaba el
  # presupuesto de AWS, pero AI_PROPOSAL_DAILY_SPEND_CAP_USD nunca se publicaba
  # en el contenedor, asi que la aplicacion cortaba por su propio defecto
  # -USD 1,00/dia en application-prod.yml, que es el perfil que corren dev Y
  # prod- contra un presupuesto derivado de USD 0,33. El triple del aviso.
  #
  # QUE LO SOSTIENE AHORA, con el mecanismo senalado con el dedo:
  #   1. backend_environment publica AI_PROPOSAL_DAILY_SPEND_CAP_USD desde ESTA
  #      misma variable: la aplicacion ya no puede cortar por otro numero.
  #   2. outputs.tf expone el valor publicado y el contrato
  #      "bedrock_concede_los_cuatro_arn_y_ninguno_mas" de
  #      tests/configuration.tftest.hcl afirma que published_cap_env coincide con
  #      daily_spend_cap_usd y que budget_usd == ceil(cap * 30). Separarlos ya no
  #      lo descubre la factura: lo para el gate.
  #   3. La variable prohibe el cero. No por simetria: el cero significa cosas
  #      distintas en cada extremo -la guarda rechaza toda reserva, el cubo
  #      global del filtro lo lee como ausencia de limite, y el presupuesto se
  #      queda sin aviso-, asi que como interruptor es lo peor de los tres
  #      mundos. El interruptor de verdad es bedrock_enabled.
  #
  # QUE SIGUE SIN CUBRIR, y hay que saberlo: nadie comprueba que el default de
  # application-prod.yml siga siendo este mismo numero. En dev y prod da igual
  # -la variable de entorno lo sobreescribe-, pero el arranque local y los tests
  # del backend seguiran usando el suyo, y volverian a divergir en silencio.
  bedrock_budget_usd = ceil(var.bedrock_daily_spend_cap_usd * 30)

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
    OTEL_EXPORTER_OTLP_METRICS_ENDPOINT = local.otlp_metrics_endpoint
    OTEL_EXPORTER_OTLP_LOGS_ENDPOINT    = local.otlp_logs_endpoint
    OTEL_EXPORTER_OTLP_TRACES_ENDPOINT  = local.otlp_traces_endpoint
    DEPLOYMENT_ENVIRONMENT              = var.environment
    VETSOFTWARE_INSTANCE_ID             = "ecs-fargate-spot"
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
    # EL MISMO numero del que sale bedrock_budget_usd, formateado a texto porque
    # una variable de entorno no tiene tipo. La aplicacion lo lee en
    # ValkeyDailySpendGuard y LoginRateLimitFilter deriva de el su cupo por IP;
    # sin esta linea ambos usaban su defecto y el presupuesto de AWS vigilaba
    # otra cifra distinta.
    AI_PROPOSAL_DAILY_SPEND_CAP_USD = format("%.2f", var.bedrock_daily_spend_cap_usd)
    # EL identificador con el que se invoca, y la linea que cierra la
    # incoherencia mas cara de esta feature.
    #
    # QUE PASABA. bedrock_inference_profile_id solo entraba en los ARN de IAM
    # (local.bedrock_model_arns). Al contenedor NO viajaba nada, asi que
    # GenerateProposalService y RefineProposalService leian
    # vetsoftware.ai.proposal.model-id por su defecto del application.yml del
    # backend: "anthropic.claude-sonnet-5", el MODELO BASE PELADO. Y como la
    # politica concede tambien los tres ARN de modelo base -que hacen falta para
    # que el perfil enrute-, IAM no habria parado esa invocacion: habria salido
    # por la ruta equivocada sin un solo error.
    #
    # POR QUE IMPORTA Y NO ES ESTETICA. Invocando el modelo base directamente no
    # hay perfil de inferencia, luego no hay enrutado entre us-east-1, us-east-2
    # y us-west-2: hay una llamada a la region desde la que se invoca. El
    # conjunto de regiones que el consentimiento del prospecto declara deja de
    # describir el sistema, y la validacion del prefijo "us." de
    # variables.tf:935 pasa a vigilar una cadena que no llegaba a ninguna parte.
    # Hoy no hay exposicion solo porque ModelAccessNotEnabledInvoker no invoca;
    # el dia que entre el invocador real, la primera generacion ya sale mal.
    #
    # QUE LO SOSTIENE, con el mecanismo y no con la intencion:
    #   1. El valor se DERIVA de var.bedrock_inference_profile_id, la misma que
    #      compone el ARN del perfil. No hay un segundo sitio donde escribirlo,
    #      asi que no hay dos cadenas que puedan separarse.
    #   2. Esa variable lleva la validacion del prefijo "us.", que ahora si
    #      gobierna lo que se invoca de verdad y no solo un ARN.
    #   3. outputs.tf publica el valor tal y como sale hacia el contenedor
    #      (published_model_env) y el contrato
    #      "bedrock_concede_los_cuatro_arn_y_ninguno_mas" afirma tres cosas:
    #      que coincide con el perfil, que NO es el modelo base, y que existe un
    #      ARN concedido de inference-profile que termina exactamente en el.
    #      Borrar esta linea deja de ser invisible: pone el gate en rojo.
    #
    # QUE SIGUE SIN CUBRIR, y hay que decirlo con la fecha delante porque el otro
    # repositorio se movio mientras esto se escribia. A 2026-08-30, en HEAD del
    # backend el defecto seguia siendo el modelo base pelado
    # -application.yml:366-, y en su arbol de trabajo ya esta alineado con el
    # perfil -application.yml:411 y los @Value de GenerateProposalService,
    # RefineProposalService y BedrockInvokerConfig-. Publicar esta variable no
    # depende de cual de los dos estados acabe integrandose: la sobreescribe en
    # los dos. Lo que no cubre nadie desde aqui es el arranque local y los tests
    # del backend, que usan el defecto que ese repositorio tenga ese dia.
    #
    # Y LO QUE NO VIAJA, que importa mas al cambiar de familia: las tarifas. El
    # backend calcula el gasto con usd-per-million-*-tokens y priced-model-id
    # -application.yml:381-397-, cuyos defectos son los de Sonnet, y la
    # infraestructura NO los publica por decision escrita alli mismo. Cambiar
    # aqui el modelo a otra familia deja a la aplicacion cobrando contra el tope
    # con las tarifas de la anterior; ModelPricing lo avisa con un WARN en el
    # arranque -no revienta a proposito- y nada en este gate lo ve.
    AI_PROPOSAL_MODEL_ID = var.bedrock_inference_profile_id
    # Los cuatro UUID de plantilla de Resend del producto. Hasta ahora eran default
    # commiteado en el application.yml del backend: el identificador viajaba dentro de la
    # imagen y los tres entornos apuntaban siempre a la misma plantilla. Entran por
    # variable de entorno, que es justo lo que el placeholder del application.yml lee.
    REGISTRATION_VERIFICATION_TEMPLATE_ID = var.registration_verification_template_id
    PASSWORD_RESET_TEMPLATE_ID            = var.password_reset_template_id
    EMPLOYEE_INVITATION_TEMPLATE_ID       = var.employee_invitation_template_id
    APPOINTMENT_CONFIRMATION_TEMPLATE_ID  = var.appointment_confirmation_template_id
    # Alta de superadministradores de plataforma. Sin estas cuatro el contenedor NO
    # arranca: con el correo habilitado ResendPlatformAccessEmailSender las valida al
    # construir el bean y lanza IllegalStateException, el health check falla y ECS
    # reintenta en bucle. Van a la CONSOLA DE PLATAFORMA (dev-admin), no a la app del
    # tenant de las dos lineas de arriba: reutilizar var.login_url mandaria al
    # superadministrador recien creado a una aplicacion donde su codigo no sirve.
    PLATFORM_APPROVER_EMAIL         = var.platform_approver_email
    PLATFORM_ACCESS_REVIEW_BASE_URL = var.platform_access_review_base_url
    PLATFORM_INVITATION_BASE_URL    = var.platform_invitation_base_url
    PLATFORM_ACCESS_LOGIN_URL       = var.platform_access_login_url
    # Los cuatro UUID de plantilla de Resend de ese mismo flujo. Las plantillas se crean
    # A MANO en el panel de Resend; aqui solo viaja el identificador. Sin ellas el bean
    # tampoco se construye: valida las OCHO claves de vetsoftware.platform-access de una
    # vez, y en el application.yml del backend las cuatro llegan con default vacio.
    PLATFORM_ACCESS_REQUEST_TEMPLATE_ID  = var.platform_access_request_template_id
    PLATFORM_ACCESS_APPROVED_TEMPLATE_ID = var.platform_access_approved_template_id
    PLATFORM_ACCESS_REJECTED_TEMPLATE_ID = var.platform_access_rejected_template_id
    PLATFORM_ACCESS_WELCOME_TEMPLATE_ID  = var.platform_access_welcome_template_id
    RECAPTCHA_ENABLED                    = tostring(var.recaptcha_enabled)
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
    DIAN_ENC_KEY = "${module.secrets.application_secret_arn}:DIAN_ENC_KEY::"

    # Se queda SIEMPRE, con sidecar o sin el, por dos razones independientes y
    # cada una suficiente.
    #
    # La primera: la exportacion OTLP de logs sigue apuntando al gateway de
    # Grafana Cloud y sin esta cabecera cada envio rebota con 401.
    #
    # La segunda es mas dura. RemoteConnectionValidator -perfiles dev y prod,
    # BeanFactoryPostProcessor con HIGHEST_PRECEDENCE- exige que
    # OTEL_EXPORTER_OTLP_HEADERS tenga texto y lanza IllegalStateException si no.
    # Quitarla con el sidecar activo no degradaria la telemetria: impediria
    # arrancar la aplicacion.
    #
    # Con el sidecar activo la cabecera tambien viaja hacia 127.0.0.1, donde el
    # colector la ignora. Es inofensivo y es el precio de que la variable sea
    # global a las tres senales en el SDK.
    OTEL_EXPORTER_OTLP_HEADERS = "${module.secrets.grafana_secret_arn}:OTEL_EXPORTER_OTLP_HEADERS::"
  }
}
