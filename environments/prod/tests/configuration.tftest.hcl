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

run "production_configuration_plans" {
  command = plan

  variables {
    backend_image_uri = "123456789012.dkr.ecr.us-east-1.amazonaws.com/vetsoftware@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

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
