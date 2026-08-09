mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
      arn        = "arn:aws:iam::123456789012:user/terraform-test"
      user_id    = "AIDATEST"
    }
  }

  mock_data "aws_availability_zones" {
    defaults = {
      names = ["us-east-1a", "us-east-1b", "us-east-1c"]
    }
  }

  mock_data "aws_region" {
    defaults = {
      name   = "us-east-1"
      region = "us-east-1"
    }
  }

  mock_data "aws_ssm_parameter" {
    defaults = {
      value = "ami-0123456789abcdef0"
    }
  }

  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
}

# El ARN de la CMK no existe hasta el apply, y sin el no se puede comprobar en
# plan que los log groups de RDS la usen en lugar de la clave de AWS.
override_resource {
  target          = module.kms.aws_kms_key.this
  override_during = plan

  values = {
    arn = "arn:aws:kms:us-east-1:123456789012:key/11111111-2222-3333-4444-555555555555"
  }
}

run "production_configuration_plans" {
  command = plan

  variables {
    backend_image_uri = "123456789012.dkr.ecr.us-east-1.amazonaws.com/vetsoftware-backend@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

    application_secrets_json = jsonencode({
      JWT_SECRET       = "test-only-jwt-secret-with-sufficient-length"
      RESEND_API_KEY   = "test-only-resend-key"
      RECAPTCHA_SECRET = "test-only-recaptcha-key"
    })

    grafana_secrets_json = jsonencode({
      OTLP_USERNAME = "test-only-user"
      OTLP_API_KEY  = "test-only-api-key"
    })

    cloudflare_tunnel_token = "test-only-cloudflare-tunnel-token-with-sufficient-length"

    grafana_otlp_endpoint         = "https://otlp.example.test/otlp"
    api_domain_name               = "api.example.test"
    cors_allowed_origins          = ["https://app.example.test"]
    email_from                    = "VetSoftware <noreply@example.test>"
    registration_verification_url = "https://app.example.test/verify"
    password_reset_url            = "https://app.example.test/reset"
    login_url                     = "https://app.example.test/login"

    monthly_budget_usd = 0
  }

  assert {
    condition     = output.monthly_budget_usd == 0
    error_message = "El presupuesto debe poder deshabilitarse para pruebas."
  }

  assert {
    condition = (
      output.database_hardening.backup_retention_period >= 7 &&
      output.database_hardening.deletion_protection &&
      output.database_hardening.iam_database_authentication_enabled &&
      !output.database_hardening.skip_final_snapshot
    )
    error_message = "RDS prod debe conservar backup, IAM DB Auth, deletion protection y snapshot final."
  }

  # El log general expone el texto de cada consulta y sus log groups, si los crea
  # RDS, nacen sin caducidad y con la clave de AWS. Prod no puede desplegarse asi.
  assert {
    condition = (
      !contains(output.database_logging.exports, "general") &&
      output.database_logging.retention_in_days == 30 &&
      output.database_logging.all_encrypted_with_cmk &&
      length(output.database_logging.log_group_names) == 2
    )
    error_message = "Los logs de RDS prod deben excluir general, caducar a 30 dias y cifrarse con la CMK del entorno."
  }

  # INF-49. La evidencia de prod tiene que cubrir el termino de firmeza fiscal, y
  # el Object Lock COMPLIANCE no permite alargar despues lo que se escriba corto.
  assert {
    condition = (
      output.traceability.multi_region &&
      output.traceability.global_service_events &&
      output.traceability.log_file_validation &&
      output.traceability.encrypted_with_cmk &&
      output.traceability.evidence_object_lock == "COMPLIANCE" &&
      output.traceability.evidence_retention >= 1825 &&
      output.traceability.access_analyzer_enabled
    )
    error_message = "Prod debe conservar el rastro cinco anios bajo Object Lock COMPLIANCE, multi-region y con digests firmados."
  }

  assert {
    condition = (
      !output.traceability.guardduty_enabled &&
      !output.traceability.s3_data_events
    )
    error_message = "Ni GuardDuty ni los data events pueden encenderse sin decidirlo: los dos se facturan."
  }

  # Una shell en el contenedor de produccion lee DB_PASSWORD, JWT_SECRET y
  # DIAN_ENC_KEY. Que este apagada es parte del hallazgo, no un detalle aparte.
  assert {
    condition     = !var.enable_execute_command
    error_message = "ECS Exec debe venir apagado en produccion; se activa con un apply deliberado cuando haya que diagnosticar."
  }

  assert {
    condition = (
      output.network_egress_profile.assign_public_ip &&
      output.network_egress_profile.interface_endpoints == 0 &&
      output.network_egress_profile.s3_gateway_endpoint &&
      output.network_egress_profile.backend_cidr == "0.0.0.0/0" &&
      output.network_egress_profile.backend_port == 443 &&
      output.network_egress_profile.alloy_cidr == "0.0.0.0/0" &&
      output.network_egress_profile.alloy_port == 443
    )
    error_message = "Prod debe usar salida HTTPS publica explicita, Fargate con IP publica, cero Interface Endpoints y S3 Gateway."
  }

  assert {
    condition     = output.cloudflare_tunnel_origin_url == "http://localhost:8080"
    error_message = "El hostname prod de Cloudflare Tunnel debe apuntar al backend local de la misma tarea."
  }
}
