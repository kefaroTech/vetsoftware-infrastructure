mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
    }
  }

  mock_data "aws_partition" {
    defaults = {
      partition = "aws"
    }
  }
}

variables {
  aws_region                        = "us-east-1"
  github_organization               = "kefaroTech"
  github_organization_id            = "12345678"
  existing_github_oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
  github_repository_ids = {
    backend       = "100000001"
    private_front = "100000002"
    public_front  = "100000003"
    iac           = "100000004"
  }
}

run "development_bootstrap_owns_only_development" {
  command = plan

  variables {
    environment       = "dev"
    state_bucket_name = "vetsoftware-dev-tfstate-123456789012"
    state_kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000001"
  }

  assert {
    condition = (
      output.environment == "dev" &&
      output.state_bucket_name == "vetsoftware-dev-tfstate-123456789012" &&
      toset(keys(output.ecr_repository_urls)) == toset(["backend"]) &&
      toset(keys(output.github_iac_role_arns)) == toset(["dev"]) &&
      length(output.github_ecr_publisher_role_arns) == 0 &&
      toset(keys(output.github_ecr_development_publisher_role_arns)) == toset(["backend"])
    )
    error_message = "El bootstrap dev no debe crear ni emitir recursos de prod."
  }
}

run "production_bootstrap_owns_only_production" {
  command = plan

  variables {
    environment       = "prod"
    state_bucket_name = "vetsoftware-prod-tfstate-123456789012"
    state_kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000002"
  }

  assert {
    condition = (
      output.environment == "prod" &&
      output.state_bucket_name == "vetsoftware-prod-tfstate-123456789012" &&
      toset(keys(output.ecr_repository_urls)) == toset(["backend", "private_front", "public_front"]) &&
      toset(keys(output.github_iac_role_arns)) == toset(["prod"]) &&
      toset(keys(output.github_ecr_publisher_role_arns)) == toset(["backend", "private_front", "public_front"]) &&
      length(output.github_ecr_development_publisher_role_arns) == 0
    )
    error_message = "El bootstrap prod no debe crear ni emitir recursos de dev."
  }
}
