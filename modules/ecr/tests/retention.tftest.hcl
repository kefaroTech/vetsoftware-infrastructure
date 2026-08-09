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
      development_publication = false
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

run "production_registries_are_immutable" {
  command = plan

  assert {
    condition = length(aws_ecr_repository.this) == 3 && alltrue([
      for repository in aws_ecr_repository.this :
      repository.image_tag_mutability == "IMMUTABLE" &&
      repository.image_scanning_configuration[0].scan_on_push &&
      !strcontains(repository.name, "-dev")
    ])
    error_message = "Prod debe crear solo sus tres repositorios inmutables y escaneados."
  }

  assert {
    condition = (
      aws_ecr_repository.this["backend"].tags["RetentionScope"] == "production-only" &&
      aws_ecr_repository.this["private_front"].tags["RetentionScope"] == "production-only" &&
      aws_ecr_repository.this["public_front"].tags["RetentionScope"] == "production-only"
    )
    error_message = "Todos los repositorios del bootstrap prod deben ser production-only."
  }
}

run "production_has_no_development_identity" {
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
      length(aws_iam_role.github_ecr) == 3 &&
      length(aws_iam_role.github_ecr_development) == 0
    )
    error_message = "Prod debe crear solo publicadores production y ninguna identidad development."
  }
}

run "retention_separates_release_from_development" {
  command = plan

  # La retencion de desarrollo se mide en TIEMPO, no en compilaciones. Lo que hay
  # que proteger es que la imagen fijada en la task definition siga existiendo
  # cuando haya que colocar una tarea nueva, y ese riesgo depende de cuanto lleva
  # el ambiente sin desplegar. Contando builds, una jornada de merges basta para
  # expulsar la imagen que esta corriendo: paso el 8 de agosto de 2026 y dev no
  # levanto al dia siguiente.
  assert {
    condition = alltrue([
      for policy in aws_ecr_lifecycle_policy.this :
      jsondecode(policy.policy).rules[1].selection.tagPrefixList == ["dev-"] &&
      jsondecode(policy.policy).rules[1].selection.countType == "sinceImagePushed" &&
      jsondecode(policy.policy).rules[1].selection.countUnit == "days" &&
      jsondecode(policy.policy).rules[1].selection.countNumber >= 30
    ])
    error_message = "Las imágenes de desarrollo deben retenerse por tiempo -30 días o más-, no por número de compilaciones."
  }

  # El tope solo acota el coste ante una racha anomala. Si baja al punto de poder
  # morder en una semana normal de trabajo, vuelve a ser una retencion por
  # cantidad disfrazada y el fallo regresa.
  assert {
    condition = alltrue([
      for policy in aws_ecr_lifecycle_policy.this :
      jsondecode(policy.policy).rules[2].selection.tagPrefixList == ["dev-"] &&
      jsondecode(policy.policy).rules[2].selection.countType == "imageCountMoreThan" &&
      jsondecode(policy.policy).rules[2].selection.countNumber >= 100
    ])
    error_message = "El tope de imágenes de desarrollo debe quedar muy por encima de una semana de compilaciones; si no, sustituye a la ventana de tiempo."
  }

  assert {
    condition = alltrue([
      for policy in aws_ecr_lifecycle_policy.this :
      jsondecode(policy.policy).rules[3].selection.tagPrefixList == ["sha-"] &&
      jsondecode(policy.policy).rules[3].selection.countType == "imageCountMoreThan" &&
      jsondecode(policy.policy).rules[3].selection.countNumber == 30
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

run "development_registry_has_no_production_identity" {
  command = plan

  variables {
    repositories = {
      backend = {
        name                    = "vetsoftware-dev-backend"
        github_repository       = "VetSoftware"
        github_repository_id    = "100000001"
        production_publication  = false
        development_publication = true
      }
    }
  }

  assert {
    condition = (
      toset(keys(aws_ecr_repository.this)) == toset(["backend"]) &&
      aws_ecr_repository.this["backend"].name == "vetsoftware-dev-backend" &&
      aws_ecr_repository.this["backend"].tags["RetentionScope"] == "development-only"
    )
    error_message = "Dev debe tener un repositorio backend propio y marcado como development-only."
  }

  assert {
    condition = (
      length(aws_iam_role.github_ecr) == 0 &&
      length(aws_iam_role.github_ecr_development) == 1 &&
      strcontains(data.aws_iam_policy_document.github_assume_development["backend"].json, ":environment:development")
    )
    error_message = "El bootstrap dev no debe crear ninguna identidad publicadora de produccion."
  }
}
