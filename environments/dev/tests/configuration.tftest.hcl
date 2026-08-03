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

  mock_data "aws_partition" {
    defaults = {
      partition = "aws"
    }
  }

  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
}

run "development_cost_profile_plans" {
  command = plan

  variables {
    backend_image_uri = "123456789012.dkr.ecr.us-east-1.amazonaws.com/vetsoftware-backend@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

    application_secrets_json = jsonencode({
      JWT_SECRET       = "test-only-jwt-secret-with-sufficient-length"
      RESEND_API_KEY   = "test-only-resend-key"
      RECAPTCHA_SECRET = "test-only-recaptcha-key"
    })

    grafana_secrets_json = jsonencode({
      OTLP_USERNAME              = "test-only-user"
      OTLP_API_KEY               = "test-only-api-key"
      OTEL_EXPORTER_OTLP_HEADERS = "Authorization=Basic dGVzdDp0ZXN0"
    })

    cloudflare_tunnel_token = "test-only-cloudflare-tunnel-token-with-sufficient-length"

    grafana_otlp_endpoint         = "https://otlp.example.test/otlp"
    cors_allowed_origins          = ["https://dev.example.test"]
    email_from                    = "VetSoftware Dev <noreply@example.test>"
    registration_verification_url = "https://dev.example.test/verify"
    password_reset_url            = "https://dev.example.test/reset"
    login_url                     = "https://dev.example.test/login"
    api_domain_name               = "dev-api.example.test"
  }

  assert {
    condition     = output.cost_profile.backend_cpu_mib == 512 && output.cost_profile.backend_memory_mib == 2048
    error_message = "Dev debe conservar 512 CPU y 2048 MiB."
  }

  assert {
    condition     = output.cost_profile.fargate_spot_only && output.cost_profile.backend_min_tasks == 0 && output.cost_profile.backend_max_tasks == 1
    error_message = "Dev debe usar solo Fargate Spot y limitar el servicio entre cero y una tarea."
  }

  assert {
    condition     = output.cost_profile.database_class == "db.t4g.micro" && output.cost_profile.database_backup_days == 7
    error_message = "RDS dev debe conservar db.t4g.micro y siete dias de backup."
  }

  assert {
    condition = (
      output.cost_profile.database_hardening.deletion_protection &&
      output.cost_profile.database_hardening.iam_database_authentication_enabled &&
      !output.cost_profile.database_hardening.skip_final_snapshot
    )
    error_message = "RDS dev debe conservar IAM DB Auth, deletion protection y snapshot final."
  }

  assert {
    condition     = output.cost_profile.valkey_storage_gb == 1 && output.cost_profile.valkey_ecpu_per_second == 1000
    error_message = "Valkey dev debe mantener los límites mínimos."
  }

  assert {
    condition     = output.cost_profile.log_retention_days == 3 && output.cost_profile.load_balancer_count == 0 && !output.cost_profile.dedicated_alloy
    error_message = "Dev debe retener logs tres días y operar sin ALB ni Alloy dedicado."
  }

  assert {
    condition     = output.cost_profile.dedicated_vpc && output.vpc_cidr == "10.50.0.0/16"
    error_message = "Dev debe crear su propia VPC y no depender de la red de otro entorno."
  }

  assert {
    condition     = output.cloudflare_tunnel_origin_url == "http://localhost:8080"
    error_message = "El hostname dev de Cloudflare Tunnel debe apuntar al backend local de la misma tarea."
  }

  assert {
    condition = (
      output.cost_profile.assign_public_ip &&
      output.cost_profile.interface_endpoints == 0 &&
      output.cost_profile.public_https_cidr == "0.0.0.0/0" &&
      output.cost_profile.public_https_port == 443
    )
    error_message = "Dev debe usar Fargate con IP publica, cero Interface Endpoints y salida HTTPS publica explicita."
  }

  assert {
    condition     = length(output.scheduled_shutdown_names) == 4
    error_message = "El apagado programado debe crear cuatro acciones ordenadas para ECS y RDS."
  }
}
