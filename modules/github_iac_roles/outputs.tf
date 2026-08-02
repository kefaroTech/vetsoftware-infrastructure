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
