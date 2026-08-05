locals {
  production_repositories = {
    for key, repository in var.repositories : key => repository
    if repository.production_publication
  }

  development_repositories = {
    for key, repository in var.repositories : key => repository
    if repository.development_publication
  }
}

resource "aws_ecr_repository" "this" {
  for_each = var.repositories

  name                 = each.value.name
  image_tag_mutability = "IMMUTABLE"

  encryption_configuration {
    encryption_type = "AES256"
  }

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = merge(var.tags, {
    Component        = "container-registry"
    GitHubRepository = each.value.github_repository
    RetentionScope = (
      each.value.production_publication && each.value.development_publication ? "release-and-development" :
      each.value.development_publication ? "development-only" : "production-only"
    )
  })

  lifecycle {
    prevent_destroy = true
  }
}

# El scan_on_push de cada repositorio es la configuracion heredada, y queda
# sombreada en cuanto el registro tiene una configuracion propia: Terraform sigue
# mostrando true mientras AWS no escanea nada. Eso fue exactamente lo que paso —
# el primer despliegue real se rechazo porque ninguna imagen del backend llegaba
# a tener escaneo— asi que la configuracion del registro se declara aca en vez de
# depender de como quedo la cuenta.
#
# Es un recurso unico por cuenta y region. No colisiona entre ambientes porque
# dev y prod viven en cuentas distintas, cada una con su propio registro.
resource "aws_ecr_registry_scanning_configuration" "this" {
  scan_type = "BASIC"

  rule {
    scan_frequency = "SCAN_ON_PUSH"

    repository_filter {
      filter      = "*"
      filter_type = "WILDCARD"
    }
  }
}

resource "aws_ecr_lifecycle_policy" "this" {
  for_each = aws_ecr_repository.this

  repository = each.value.name
  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after ${var.untagged_retention_days} days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = var.untagged_retention_days
        }
        action = {
          type = "expire"
        }
      },
      {
        rulePriority = 2
        description  = "Keep the ${var.development_images_to_keep} newest development images"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = [var.development_tag_prefix]
          countType     = "imageCountMoreThan"
          countNumber   = var.development_images_to_keep
        }
        action = {
          type = "expire"
        }
      },
      {
        rulePriority = 3
        description  = "Keep the ${var.images_to_keep} newest production release images"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["sha-"]
          countType     = "imageCountMoreThan"
          countNumber   = var.images_to_keep
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}

data "aws_iam_policy_document" "github_assume" {
  for_each = local.production_repositories

  statement {
    sid     = "GitHubEnvironment"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.github_oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_organization}@${var.github_organization_id}/${each.value.github_repository}@${each.value.github_repository_id}:environment:${var.github_environment}"]
    }
  }
}

resource "aws_iam_role" "github_ecr" {
  for_each = local.production_repositories

  name                 = "${var.project_name}-${each.key}-github-ecr"
  assume_role_policy   = data.aws_iam_policy_document.github_assume[each.key].json
  max_session_duration = 3600

  tags = merge(var.tags, {
    Component        = "github-ecr-publisher"
    GitHubRepository = each.value.github_repository
    RetentionScope   = "production-only"
  })
}

data "aws_iam_policy_document" "github_ecr" {
  for_each = var.repositories

  statement {
    sid       = "GetRegistryToken"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid    = "PushRepositoryImage"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload",
      "ecr:DescribeImages",
      "ecr:DescribeImageScanFindings",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
    ]
    resources = [aws_ecr_repository.this[each.key].arn]
  }
}

resource "aws_iam_role_policy" "github_ecr" {
  for_each = local.production_repositories

  name   = "publish-${each.value.name}"
  role   = aws_iam_role.github_ecr[each.key].id
  policy = data.aws_iam_policy_document.github_ecr[each.key].json
}

# Publicacion de desarrollo: rol propio y environment propio, para que develop
# nunca dependa de una release productiva ni comparta credenciales con ella.
data "aws_iam_policy_document" "github_assume_development" {
  for_each = local.development_repositories

  statement {
    sid     = "GitHubDevelopmentEnvironment"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.github_oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_organization}@${var.github_organization_id}/${each.value.github_repository}@${each.value.github_repository_id}:environment:${var.github_development_environment}"]
    }
  }
}

resource "aws_iam_role" "github_ecr_development" {
  for_each = local.development_repositories

  name                 = "${var.project_name}-${each.key}-github-ecr-dev"
  assume_role_policy   = data.aws_iam_policy_document.github_assume_development[each.key].json
  max_session_duration = 3600

  tags = merge(var.tags, {
    Component        = "github-ecr-publisher-development"
    GitHubRepository = each.value.github_repository
    RetentionScope   = "development-only"
  })
}

resource "aws_iam_role_policy" "github_ecr_development" {
  for_each = local.development_repositories

  name   = "publish-development-${each.value.name}"
  role   = aws_iam_role.github_ecr_development[each.key].id
  policy = data.aws_iam_policy_document.github_ecr[each.key].json
}
