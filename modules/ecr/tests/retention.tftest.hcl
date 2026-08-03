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
      name                    = "vetsoftware-backend"
      github_repository       = "VetSoftware"
      github_repository_id    = "100000001"
      development_publication = true
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

run "registry_stays_single_and_immutable" {
  command = plan

  assert {
    condition = length(aws_ecr_repository.this) == 3 && alltrue([
      for repository in aws_ecr_repository.this :
      repository.image_tag_mutability == "IMMUTABLE" &&
      repository.image_scanning_configuration[0].scan_on_push &&
      !strcontains(repository.name, "-dev")
    ])
    error_message = "Deben existir solo los tres repositorios, inmutables, escaneados y sin variantes dev separadas."
  }

  assert {
    condition = (
      aws_ecr_repository.this["backend"].tags["RetentionScope"] == "release-and-development" &&
      aws_ecr_repository.this["private_front"].tags["RetentionScope"] == "production-only" &&
      aws_ecr_repository.this["public_front"].tags["RetentionScope"] == "production-only"
    )
    error_message = "Solo el backend publica desde develop; los fronts siguen siendo production-only."
  }
}

run "release_and_development_publishers_stay_separated" {
  command = plan

  assert {
    condition = alltrue([
      for trust in data.aws_iam_policy_document.github_assume :
      strcontains(trust.json, ":environment:production") &&
      !strcontains(trust.json, ":environment:development")
    ])
    error_message = "El publicador de releases solo puede confiar en el environment production."
  }

  assert {
    condition = (
      length(data.aws_iam_policy_document.github_assume_development) == 1 &&
      strcontains(data.aws_iam_policy_document.github_assume_development["backend"].json, ":environment:development") &&
      !strcontains(data.aws_iam_policy_document.github_assume_development["backend"].json, ":environment:production")
    )
    error_message = "El publicador de desarrollo debe existir solo para el backend y confiar solo en el environment development."
  }

  assert {
    condition = (
      length(aws_iam_role.github_ecr_development) == 1 &&
      aws_iam_role.github_ecr_development["backend"].name == "vetsoftware-backend-github-ecr-dev" &&
      aws_iam_role.github_ecr_development["backend"].name != aws_iam_role.github_ecr["backend"].name
    )
    error_message = "Los dos ciclos deben usar roles IAM distintos; ninguna credencial se comparte."
  }
}

run "retention_separates_release_from_development" {
  command = plan

  assert {
    condition = alltrue([
      for policy in aws_ecr_lifecycle_policy.this :
      jsondecode(policy.policy).rules[1].selection.tagPrefixList == ["dev-"] &&
      jsondecode(policy.policy).rules[1].selection.countType == "imageCountMoreThan" &&
      jsondecode(policy.policy).rules[1].selection.countNumber == 10
    ])
    error_message = "Las imágenes de desarrollo deben expirar tras las 10 más recientes del prefijo dev-."
  }

  assert {
    condition = alltrue([
      for policy in aws_ecr_lifecycle_policy.this :
      jsondecode(policy.policy).rules[2].selection.tagPrefixList == ["sha-"] &&
      jsondecode(policy.policy).rules[2].selection.countType == "imageCountMoreThan" &&
      jsondecode(policy.policy).rules[2].selection.countNumber == 30
    ])
    error_message = "La retención debe conservar como máximo 30 imágenes productivas identificadas por sha-."
  }
}

run "reject_development_release_publisher" {
  command = plan

  variables {
    github_environment = "development"
  }

  expect_failures = [var.github_environment]
}

run "reject_production_development_publisher" {
  command = plan

  variables {
    github_development_environment = "production"
  }

  expect_failures = [var.github_development_environment]
}
