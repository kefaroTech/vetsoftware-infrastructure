provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test-only-access-key"
  secret_key                  = "test-only-secret-key"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_region_validation      = true
  skip_requesting_account_id  = true
}

variables {
  project_name             = "vetsoftware"
  github_organization      = "kefaroTech"
  github_organization_id   = "12345678"
  github_environment       = "production"
  github_oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
  repositories = {
    backend = {
      name                 = "vetsoftware-backend"
      github_repository    = "VetSoftware"
      github_repository_id = "100000001"
    }
    private_front = {
      name                 = "vetsoftware-front"
      github_repository    = "VetSoftwareFront"
      github_repository_id = "100000002"
    }
    public_front = {
      name                 = "vetsoftware-public-front"
      github_repository    = "VetSoftwarePublicFront"
      github_repository_id = "100000003"
    }
  }
}

run "only_production_releases_are_retained" {
  command = plan

  assert {
    condition = length(aws_ecr_repository.this) == 3 && alltrue([
      for repository in aws_ecr_repository.this :
      repository.image_tag_mutability == "IMMUTABLE" &&
      repository.image_scanning_configuration[0].scan_on_push &&
      repository.tags["RetentionScope"] == "production-only" &&
      !strcontains(repository.name, "-dev")
    ])
    error_message = "Deben existir solo los tres repositorios productivos, inmutables, escaneados y sin variantes dev."
  }

  assert {
    condition = alltrue([
      for trust in data.aws_iam_policy_document.github_assume :
      strcontains(trust.json, ":environment:production") &&
      !strcontains(trust.json, ":environment:development") &&
      !strcontains(trust.json, ":environment:dev")
    ])
    error_message = "Los publicadores ECR solo pueden confiar en el environment production."
  }

  assert {
    condition = alltrue([
      for policy in aws_ecr_lifecycle_policy.this :
      jsondecode(policy.policy).rules[1].selection.tagPrefixList == ["sha-"] &&
      jsondecode(policy.policy).rules[1].selection.countType == "imageCountMoreThan" &&
      jsondecode(policy.policy).rules[1].selection.countNumber == 30
    ])
    error_message = "La retención debe conservar como máximo 30 imágenes productivas identificadas por sha-."
  }
}

run "reject_development_publisher" {
  command = plan

  variables {
    github_environment = "development"
  }

  expect_failures = [var.github_environment]
}
