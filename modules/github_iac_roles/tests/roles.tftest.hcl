provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test-only-access-key"
  secret_key                  = "test-only-secret-key"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_region_validation      = true
  skip_requesting_account_id  = true
}

run "environment_and_function_roles_are_isolated" {
  command = plan

  variables {
    project_name             = "vetsoftware"
    aws_account_id           = "123456789012"
    aws_region               = "us-east-1"
    github_oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
    github_organization      = "kefaroTech"
    github_organization_id   = "12345678"
    github_repository        = "VetSoftwareIaC"
    github_repository_id     = "100000004"
    state_bucket_name        = "vetsoftware-prod-tfstate-123456789012"
    state_kms_key_arn        = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000000"
    environments = {
      dev = {
        state_key                = "vetsoftware/dev/terraform.tfstate"
        github_plan_environment  = "iac-plan-dev"
        github_apply_environment = "iac-apply-dev"
      }
      prod = {
        state_key                = "vetsoftware/prod/terraform.tfstate"
        github_plan_environment  = "iac-plan-prod"
        github_apply_environment = "iac-apply-prod"
      }
    }
  }

  assert {
    condition = length(aws_iam_role.this) == 4 && toset(keys(aws_iam_role.this)) == toset([
      "dev_apply",
      "dev_plan",
      "prod_apply",
      "prod_plan",
    ])
    error_message = "Deben existir exactamente cuatro roles: plan y apply para dev y prod."
  }

  assert {
    condition = alltrue([
      aws_iam_role.this["dev_plan"].name == "vetsoftware-iac-plan-dev",
      aws_iam_role.this["dev_apply"].name == "vetsoftware-iac-apply-dev",
      aws_iam_role.this["prod_plan"].name == "vetsoftware-iac-plan-prod",
      aws_iam_role.this["prod_apply"].name == "vetsoftware-iac-apply-prod",
    ])
    error_message = "Los nombres de los roles deben conservar entorno y función."
  }

  assert {
    condition = alltrue([
      strcontains(data.aws_iam_policy_document.assume["dev_plan"].json, "repo:kefaroTech@12345678/VetSoftwareIaC@100000004:environment:iac-plan-dev"),
      strcontains(data.aws_iam_policy_document.assume["dev_apply"].json, "repo:kefaroTech@12345678/VetSoftwareIaC@100000004:environment:iac-apply-dev"),
      strcontains(data.aws_iam_policy_document.assume["prod_plan"].json, "repo:kefaroTech@12345678/VetSoftwareIaC@100000004:environment:iac-plan-prod"),
      strcontains(data.aws_iam_policy_document.assume["prod_apply"].json, "repo:kefaroTech@12345678/VetSoftwareIaC@100000004:environment:iac-apply-prod"),
    ])
    error_message = "Cada trust policy debe exigir el subject inmutable y su GitHub Environment exclusivo."
  }

  assert {
    condition = alltrue([
      length([for statement in jsondecode(data.aws_iam_policy_document.state["dev_plan"].json).Statement : statement if statement.Sid == "WriteEnvironmentState"]) == 0,
      length([for statement in jsondecode(data.aws_iam_policy_document.state["prod_plan"].json).Statement : statement if statement.Sid == "WriteEnvironmentState"]) == 0,
      length([for statement in jsondecode(data.aws_iam_policy_document.state["dev_apply"].json).Statement : statement if statement.Sid == "WriteEnvironmentState"]) == 1,
      length([for statement in jsondecode(data.aws_iam_policy_document.state["prod_apply"].json).Statement : statement if statement.Sid == "WriteEnvironmentState"]) == 1,
    ])
    error_message = "Plan debe leer state sin escribirlo; solo apply puede actualizar su state."
  }

  assert {
    condition = alltrue([
      strcontains(data.aws_iam_policy_document.state["dev_plan"].json, "vetsoftware/dev/terraform.tfstate"),
      !strcontains(data.aws_iam_policy_document.state["dev_plan"].json, "vetsoftware/prod/terraform.tfstate"),
      strcontains(data.aws_iam_policy_document.state["prod_plan"].json, "vetsoftware/prod/terraform.tfstate"),
      !strcontains(data.aws_iam_policy_document.state["prod_plan"].json, "vetsoftware/dev/terraform.tfstate"),
    ])
    error_message = "Cada rol debe quedar limitado a la key y lockfile de su entorno."
  }

  assert {
    condition = alltrue([
      toset(keys(aws_iam_role_policy.apply_regional)) == toset(["dev_apply", "prod_apply"]),
      toset(keys(aws_iam_role_policy.apply_identity)) == toset(["dev_apply", "prod_apply"]),
      toset(keys(aws_iam_role_policy.apply_storage)) == toset(["dev_apply", "prod_apply"]),
      toset(keys(aws_iam_role_policy.apply_global)) == toset(["dev_apply", "prod_apply"]),
    ])
    error_message = "Los roles plan no deben recibir ninguna política de mutación."
  }

  assert {
    condition = alltrue([
      !strcontains(data.aws_iam_policy_document.apply_identity["dev_apply"].json, "secretsmanager:GetSecretValue"),
      !strcontains(data.aws_iam_policy_document.apply_identity["prod_apply"].json, "secretsmanager:GetSecretValue"),
      strcontains(data.aws_iam_policy_document.apply_identity["dev_apply"].json, "secret:vetsoftware-dev/*"),
      strcontains(data.aws_iam_policy_document.apply_identity["prod_apply"].json, "secret:vetsoftware-prod/*"),
    ])
    error_message = "Apply administra secretos por entorno, pero nunca puede leer sus valores."
  }

  assert {
    condition = alltrue([
      strcontains(data.aws_iam_policy_document.infrastructure_read["dev_plan"].json, "secret:vetsoftware-dev/*"),
      !strcontains(data.aws_iam_policy_document.infrastructure_read["dev_plan"].json, "secret:vetsoftware-prod/*"),
      strcontains(data.aws_iam_policy_document.infrastructure_read["prod_plan"].json, "arn:aws:s3:::vetsoftware-prod-*"),
      !strcontains(data.aws_iam_policy_document.infrastructure_read["prod_plan"].json, "arn:aws:s3:::vetsoftware-dev-*"),
    ])
    error_message = "Las lecturas de secretos y buckets deben conservar el límite de su entorno."
  }

  assert {
    condition = alltrue(concat(
      [for policy in data.aws_iam_policy_document.infrastructure_read : length(policy.json) <= 10240],
      [for policy in data.aws_iam_policy_document.state : length(policy.json) <= 10240],
      [for policy in data.aws_iam_policy_document.apply_regional : length(policy.json) <= 10240],
      [for policy in data.aws_iam_policy_document.apply_identity : length(policy.json) <= 10240],
      [for policy in data.aws_iam_policy_document.apply_storage : length(policy.json) <= 10240],
      [for policy in data.aws_iam_policy_document.apply_global : length(policy.json) <= 10240],
    ))
    error_message = "Cada política inline debe respetar el máximo de 10.240 caracteres de IAM."
  }
}
