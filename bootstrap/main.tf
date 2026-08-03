data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  repository_definitions = {
    dev_backend = {
      environment             = "dev"
      logical_name            = "backend"
      name                    = "${var.project_name}-dev-backend"
      github_repository       = var.github_repositories.backend
      github_repository_id    = var.github_repository_ids.backend
      production_publication  = false
      development_publication = true
    }
    prod_backend = {
      environment             = "prod"
      logical_name            = "backend"
      name                    = "${var.project_name}-backend"
      github_repository       = var.github_repositories.backend
      github_repository_id    = var.github_repository_ids.backend
      production_publication  = true
      development_publication = false
    }
    prod_private_front = {
      environment             = "prod"
      logical_name            = "private_front"
      name                    = "${var.project_name}-front"
      github_repository       = var.github_repositories.private_front
      github_repository_id    = var.github_repository_ids.private_front
      production_publication  = true
      development_publication = false
    }
    prod_public_front = {
      environment             = "prod"
      logical_name            = "public_front"
      name                    = "${var.project_name}-public-front"
      github_repository       = var.github_repositories.public_front
      github_repository_id    = var.github_repository_ids.public_front
      production_publication  = true
      development_publication = false
    }
  }

  repositories = {
    for repository in values(local.repository_definitions) : repository.logical_name => {
      name                    = repository.name
      github_repository       = repository.github_repository
      github_repository_id    = repository.github_repository_id
      production_publication  = repository.production_publication
      development_publication = repository.development_publication
    } if repository.environment == var.environment
  }

  iac_environments = {
    (var.environment) = {
      state_key                = "${var.project_name}/${var.environment}/terraform.tfstate"
      github_plan_environment  = "iac-plan-${var.environment}"
      github_apply_environment = "iac-apply-${var.environment}"
    }
  }
}

module "ecr" {
  source = "../modules/ecr"

  project_name             = var.project_name
  github_organization      = var.github_organization
  github_organization_id   = var.github_organization_id
  github_environment       = "production"
  github_oidc_provider_arn = var.existing_github_oidc_provider_arn
  images_to_keep           = var.ecr_images_to_keep
  repositories             = local.repositories
  tags                     = var.tags
}

module "github_iac_roles" {
  source = "../modules/github_iac_roles"

  project_name             = var.project_name
  aws_partition            = data.aws_partition.current.partition
  aws_account_id           = data.aws_caller_identity.current.account_id
  aws_region               = var.aws_region
  backend_repository_name  = local.repositories.backend.name
  github_oidc_provider_arn = var.existing_github_oidc_provider_arn
  github_organization      = var.github_organization
  github_organization_id   = var.github_organization_id
  github_repository        = var.github_repositories.iac
  github_repository_id     = var.github_repository_ids.iac
  state_bucket_name        = var.state_bucket_name
  state_kms_key_arn        = var.state_kms_key_arn
  environments             = local.iac_environments
  tags                     = var.tags
}
