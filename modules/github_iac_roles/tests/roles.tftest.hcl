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
    backend_repository_name  = "vetsoftware-backend"
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
      strcontains(data.aws_iam_policy_document.apply_identity["dev_apply"].json, "secret:vetsoftware-dev*"),
      strcontains(data.aws_iam_policy_document.apply_identity["prod_apply"].json, "secret:vetsoftware-prod*"),
    ])
    error_message = "Apply administra secretos por entorno, pero nunca puede leer sus valores."
  }

  assert {
    condition = alltrue([
      strcontains(data.aws_iam_policy_document.infrastructure_read["dev_plan"].json, "secret:vetsoftware-dev*"),
      !strcontains(data.aws_iam_policy_document.infrastructure_read["dev_plan"].json, "secret:vetsoftware-prod*"),
      strcontains(data.aws_iam_policy_document.infrastructure_read["prod_plan"].json, "arn:aws:s3:::vetsoftware-prod-*"),
      !strcontains(data.aws_iam_policy_document.infrastructure_read["prod_plan"].json, "arn:aws:s3:::vetsoftware-dev-*"),
    ])
    error_message = "Las lecturas de secretos y buckets deben conservar el límite de su entorno."
  }

  assert {
    condition = alltrue([
      strcontains(data.aws_iam_policy_document.infrastructure_read["dev_plan"].json, "ecr:DescribeImages"),
      strcontains(data.aws_iam_policy_document.infrastructure_read["prod_apply"].json, "ecr:DescribeImageScanFindings"),
      strcontains(data.aws_iam_policy_document.infrastructure_read["dev_plan"].json, "arn:aws:ecr:us-east-1:123456789012:repository/vetsoftware-backend"),
      !strcontains(data.aws_iam_policy_document.infrastructure_read["dev_plan"].json, "repository/*"),
    ])
    error_message = "Plan y apply deben certificar únicamente la imagen ECR del backend."
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

  assert {
    condition     = alltrue([for count in values(output.inline_policy_character_counts) : count <= 9500])
    error_message = format("Las políticas inline deben conservar margen bajo el límite IAM de 10.240 caracteres; conteos=%s.", jsonencode(output.inline_policy_character_counts))
  }

  assert {
    condition = alltrue([
      !strcontains(data.aws_iam_policy_document.infrastructure_read["dev_plan"].json, "elasticloadbalancing:"),
      !strcontains(data.aws_iam_policy_document.infrastructure_read["prod_plan"].json, "elasticloadbalancing:"),
      !strcontains(data.aws_iam_policy_document.apply_regional["dev_apply"].json, "elasticloadbalancing:"),
      !strcontains(data.aws_iam_policy_document.apply_regional["prod_apply"].json, "elasticloadbalancing:"),
      strcontains(data.aws_iam_policy_document.apply_regional["dev_apply"].json, "logs:*MetricFilter"),
      strcontains(data.aws_iam_policy_document.apply_regional["prod_apply"].json, "logs:*MetricFilter"),
    ])
    error_message = "Los roles IaC no deben conservar permisos ELB y sí deben administrar métricas de errores del túnel."
  }

  assert {
    condition = alltrue([
      strcontains(data.aws_iam_policy_document.infrastructure_read["dev_plan"].json, "ce:GetAnomaly*"),
      strcontains(data.aws_iam_policy_document.infrastructure_read["dev_plan"].json, "chatbot:DescribeSlackChannelConfigurations"),
      strcontains(data.aws_iam_policy_document.apply_global["dev_apply"].json, "ce:CreateAnomalyMonitor"),
      strcontains(data.aws_iam_policy_document.apply_global["dev_apply"].json, "chatbot:CreateSlackChannelConfiguration"),
      strcontains(data.aws_iam_policy_document.apply_identity["dev_apply"].json, "chatbot.amazonaws.com"),
      strcontains(data.aws_iam_policy_document.apply_identity["dev_apply"].json, "management.chatbot.amazonaws.com"),
    ])
    error_message = "Plan y apply deben poder leer y administrar Cost Anomaly Detection y el canal Slack sin ampliar prod desde dev."
  }

  assert {
    condition = alltrue([
      !strcontains(data.aws_iam_policy_document.apply_identity["dev_apply"].json, "secret:vetsoftware-dev/*"),
      !strcontains(data.aws_iam_policy_document.infrastructure_read["dev_plan"].json, "secret:vetsoftware-dev/*"),
      !strcontains(data.aws_iam_policy_document.apply_identity["dev_apply"].json, "secret:vetsoftware-prod*"),
    ])
    error_message = "El prefijo de secretos no debe llevar separador: vetsoftware-dev-valkey/connection queda fuera de secret:vetsoftware-dev/*."
  }

  assert {
    condition = alltrue([
      strcontains(data.aws_iam_policy_document.apply_identity["dev_apply"].json, "secret:rds!*"),
      strcontains(data.aws_iam_policy_document.apply_identity["prod_apply"].json, "secret:rds!*"),
      length([
        for statement in jsondecode(data.aws_iam_policy_document.apply_identity["dev_apply"].json).Statement :
        statement if statement.Sid == "CreateRdsManagedMasterSecret"
      ]) == 1,
    ])
    error_message = "Apply debe poder crear y etiquetar el secreto que RDS genera para el master user."
  }
}
