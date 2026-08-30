output "api_url" {
  description = "URL pública de desarrollo servida por Cloudflare Tunnel."
  value       = "https://${var.api_domain_name}"
}

output "vpc_id" {
  description = "VPC exclusiva de desarrollo; dev no depende de la red de ningun otro entorno."
  value       = module.network.vpc_id
}

output "vpc_cidr" {
  value = module.network.vpc_cidr
}

output "cloudflare_tunnel_origin_url" {
  description = "Origen local que debe configurarse en el hostname dev del túnel remoto."
  value       = module.backend.cloudflare_tunnel_origin_url
}

output "ecs_cluster_name" {
  value = module.backend.cluster_name
}

output "ecs_service_name" {
  value = module.backend.service_name
}

output "database_endpoint" {
  value = module.database.endpoint
}

output "valkey_endpoint" {
  value = module.cache.endpoint
}

output "application_bucket_name" {
  value = aws_s3_bucket.application.id
}

output "scheduled_shutdown_names" {
  value = module.scheduled_shutdown.schedule_names
}

output "finops_alerts" {
  description = "Configuración multicanal de alertas de costo del entorno dev."
  value = {
    monthly_budget_usd       = var.monthly_budget_usd
    forecast_threshold_usd   = var.monthly_budget_usd * 0.8
    actual_threshold_usd     = var.monthly_budget_usd
    anomaly_threshold_usd    = var.cost_anomaly_threshold_usd
    email_enabled            = trimspace(var.alarm_email) != ""
    slack_enabled            = local.slack_notifications_enabled
    topic_arn                = module.monitoring.finops_topic_arn
    anomaly_monitor_arn      = module.monitoring.cost_anomaly_monitor_arn
    slack_configuration_arns = module.monitoring.slack_chat_configuration_arns
  }
}

output "alerting" {
  description = "Contrato de alertas operativas de dev: severidades, umbrales derivados y circuitos de eventos activos."
  value       = module.monitoring.alerting
}

# Cobertura del silencio programado. Se expone aparte del contrato de alertas
# porque la pregunta que responde es distinta: no "que se vigila" sino "que se
# calla y cuando". El numero de alarmas cubiertas tiene que incluir las de
# log_shipping; si no las incluye, el apagado nocturno vuelve a producir ruido
# desde un modulo que nadie mira al revisar el de monitoreo.
output "maintenance_mute" {
  description = "Ventanas de silencio programado de dev, alarmas cubiertas y reglas creadas."
  value = {
    enabled      = module.monitoring.alerting.maintenance_mute.enabled
    timezone     = module.monitoring.alerting.maintenance_mute.timezone
    windows      = module.monitoring.alerting.maintenance_mute.windows
    muted_alarms = module.monitoring.alerting.maintenance_mute.muted_alarms
    excluded     = module.monitoring.alerting.maintenance_mute.excluded_alarms
    rule_arns    = module.monitoring.maintenance_mute_rule_arns
    alarm_names  = module.monitoring.muted_alarm_names
    log_shipping = var.log_shipping_enabled ? module.log_shipping[0].alarm_names : []
  }
}

output "cost_profile" {
  value = {
    backend_cpu_mib    = var.backend_cpu
    backend_memory_mib = var.backend_memory
    fargate_spot_only = (
      module.backend.capacity_provider_strategy.fargate_base == 0 &&
      module.backend.capacity_provider_strategy.fargate_weight == 0 &&
      module.backend.capacity_provider_strategy.fargate_spot_weight > 0
    )
    backend_min_tasks      = module.backend.autoscaling_range.min
    backend_max_tasks      = module.backend.autoscaling_range.max
    database_class         = var.database_instance_class
    database_backup_days   = var.database_backup_retention_days
    database_hardening     = module.database.hardening
    database_logging       = module.database.logging
    valkey_storage_gb      = var.valkey_maximum_data_storage_gb
    valkey_ecpu_per_second = var.valkey_maximum_ecpu_per_second
    log_retention_days     = var.log_retention_days
    # El unico grupo que se sale de la retencion del entorno: es el origen del
    # envio durable a Grafana Cloud y tiene que sobrevivir a un atasco largo.
    backend_log_retention_days = module.backend.backend_log_retention_days
    load_balancer_count        = 0
    dedicated_alloy            = false
    dedicated_vpc              = true
    assign_public_ip           = module.backend.assign_public_ip
    public_https_cidr          = aws_vpc_security_group_egress_rule.backend_public_https.cidr_ipv4
    public_https_port          = aws_vpc_security_group_egress_rule.backend_public_https.to_port
    interface_endpoints        = 0
  }
}

output "traceability" {
  value = module.account_baseline.traceability
}

output "cmk_authorized_services" {
  value = module.kms.authorized_services
}

output "cost_reporting" {
  value = module.cost_report.reporting
}

output "log_shipping" {
  description = "Contrato del envio durable de logs del backend a Grafana Cloud; nulo cuando el envio esta apagado."
  value = var.log_shipping_enabled ? merge(module.log_shipping[0].shipping, {
    # El nombre del secreto lo aporta el entorno porque el modulo solo recibe su
    # ARN. Es lo que permite fijar en el contrato que la clave del envio vive en
    # un secreto propio y no dentro del que comparten OTLP y el sidecar.
    access_key_secret_name = module.secrets.grafana_logs_secret_name
  }) : null
}

# Contrato del sidecar de trazas y metricas.
#
# Los tres endpoints se exponen tal cual llegan al contenedor porque el modo de
# fallo de este cambio es exactamente ese: que apagar el interruptor no devuelva
# el sistema a donde estaba y la telemetria quede cortada en silencio, apuntando
# a un colector que ya no existe. Es un valor que hay que poder afirmar en las
# dos ramas, no una intencion documentada.
output "telemetry" {
  description = "Contrato del sidecar colector y de los tres endpoints OTLP que recibe el backend en cada rama del interruptor."
  value = {
    sidecar = module.backend.telemetry_sidecar

    otlp_endpoints = {
      traces  = local.otlp_traces_endpoint
      metrics = local.otlp_metrics_endpoint
      logs    = local.otlp_logs_endpoint
    }

    # Requerida siempre: la exportacion OTLP de logs sigue yendo directa al
    # gateway y RemoteConnectionValidator rechaza arrancar sin ella.
    otlp_headers_from_secret = contains(keys(local.backend_secrets), "OTEL_EXPORTER_OTLP_HEADERS")

    tracing_sampling = var.tracing_sampling

    alarm_names = module.monitoring.telemetry_sidecar_alarm_names
  }
}

# Contrato de Bedrock en dev.
#
# Se publica entero -y no solo un booleano- porque los tres modos de fallo de
# este cambio son silenciosos y ninguno se ve en un apply verde:
#
#  1. Faltar una region en la lista de ARN. El despliegue queda verde y la
#     primera invocacion que el enrutador mande a esa region devuelve
#     AccessDeniedException. Intermitente, y el mensaje no nombra el recurso.
#  2. Cambiar "us." por "global." en el perfil. Se invoca igual, funciona igual,
#     y el dato pasa a poder salir a cualquier region soportada mientras el
#     consentimiento del prospecto sigue nombrando tres.
#  3. Mover el tope de gasto sin mover el presupuesto. El control que corta y el
#     que avisa dejan de hablar del mismo sistema y nadie se entera hasta la
#     factura.
#
# Los tres se afirman en tests/configuration.tftest.hcl contra este output.
output "bedrock" {
  description = "Permiso de invocacion, regiones alcanzables y controles de gasto de Bedrock en dev."
  value = {
    enabled             = var.bedrock_enabled
    inference_profile   = var.bedrock_inference_profile_id
    foundation_model    = var.bedrock_foundation_model_id
    invoked_from        = var.aws_region
    routing_regions     = local.bedrock_routing_regions
    global_profile      = startswith(var.bedrock_inference_profile_id, "global.")
    daily_spend_cap_usd = var.bedrock_daily_spend_cap_usd

    # Tal y como el modulo los recibio, no como el root los penso.
    access = module.backend.bedrock_access

    cost_controls = module.monitoring.bedrock_cost_controls
  }
}
