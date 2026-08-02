mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
      arn        = "arn:aws:iam::123456789012:user/terraform-test"
      user_id    = "AIDATEST"
    }
  }

  mock_data "aws_vpc" {
    defaults = {
      id = "vpc-0123456789abcdef0"
    }
  }

  mock_data "aws_subnets" {
    defaults = {
      ids = ["subnet-00000000000000001", "subnet-00000000000000002"]
    }
  }

  mock_data "aws_lb" {
    defaults = {
      arn        = "arn:aws:elasticloadbalancing:us-east-1:123456789012:loadbalancer/app/vetsoftware-prod/1234567890abcdef"
      arn_suffix = "app/vetsoftware-prod/1234567890abcdef"
      dns_name   = "vetsoftware-prod.us-east-1.elb.amazonaws.com"
      zone_id    = "Z35SXDOTRQ7X7K"
    }
  }

  mock_data "aws_lb_listener" {
    defaults = {
      arn = "arn:aws:elasticloadbalancing:us-east-1:123456789012:listener/app/vetsoftware-prod/1234567890abcdef/abcdef1234567890"
    }
  }

  mock_data "aws_security_group" {
    defaults = {
      id = "sg-0123456789abcdef0"
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
    backend_image_uri = "123456789012.dkr.ecr.us-east-1.amazonaws.com/vetsoftware@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

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

    grafana_otlp_endpoint                    = "https://otlp.example.test/otlp"
    cors_allowed_origins                     = ["https://dev.example.test"]
    email_from                               = "VetSoftware Dev <noreply@example.test>"
    registration_verification_url            = "https://dev.example.test/verify"
    password_reset_url                       = "https://dev.example.test/reset"
    login_url                                = "https://dev.example.test/login"
    api_domain_name                          = "dev-api.example.test"
    route53_zone_id                          = "Z0000000000000000000"
    confirm_shared_certificate_covers_domain = true
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
    condition     = output.cost_profile.database_class == "db.t4g.micro" && output.cost_profile.database_backup_days == 1
    error_message = "RDS dev debe usar db.t4g.micro y un día de backup."
  }

  assert {
    condition     = output.cost_profile.valkey_storage_gb == 1 && output.cost_profile.valkey_ecpu_per_second == 1000
    error_message = "Valkey dev debe mantener los límites mínimos."
  }

  assert {
    condition     = output.cost_profile.log_retention_days == 3 && !output.cost_profile.dedicated_alb && !output.cost_profile.dedicated_alloy
    error_message = "Dev debe retener logs tres días y compartir ALB sin desplegar Alloy."
  }

  assert {
    condition     = length(output.scheduled_shutdown_names) == 4
    error_message = "El apagado programado debe crear cuatro acciones ordenadas para ECS y RDS."
  }
}
