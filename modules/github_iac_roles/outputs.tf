output "role_arns" {
  description = "ARNs separados por entorno y función."
  value = {
    for environment, config in var.environments : environment => {
      plan  = aws_iam_role.this["${environment}_plan"].arn
      apply = aws_iam_role.this["${environment}_apply"].arn
    }
  }
}

output "role_names" {
  description = "Nombres de roles separados por entorno y función."
  value = {
    for environment, config in var.environments : environment => {
      plan  = aws_iam_role.this["${environment}_plan"].name
      apply = aws_iam_role.this["${environment}_apply"].name
    }
  }
}

output "github_environments" {
  description = "GitHub Environments que deben asociarse a cada rol."
  value = {
    for environment, config in var.environments : environment => {
      plan  = config.github_plan_environment
      apply = config.github_apply_environment
    }
  }
}

output "inline_policy_character_counts" {
  description = "Caracteres agregados de políticas inline por rol; IAM limita cada rol a 10.240."
  value = {
    for key, role in local.role_definitions : key => nonsensitive(sum(concat(
      [
        length(replace(data.aws_iam_policy_document.infrastructure_read[key].json, "/\\s/", "")),
        length(replace(data.aws_iam_policy_document.state[key].json, "/\\s/", "")),
      ],
      role.function == "apply" ? [
        length(replace(data.aws_iam_policy_document.apply_regional[key].json, "/\\s/", "")),
        length(replace(data.aws_iam_policy_document.apply_identity[key].json, "/\\s/", "")),
        length(replace(data.aws_iam_policy_document.apply_storage[key].json, "/\\s/", "")),
        length(replace(data.aws_iam_policy_document.apply_global[key].json, "/\\s/", "")),
      ] : [],
    )))
  }
}
