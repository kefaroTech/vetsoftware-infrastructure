variable "project_name" {
  description = "Nombre corto usado en roles IAM y etiquetas."
  type        = string
}

variable "repositories" {
  description = "Repositorios ECR y repositorios GitHub autorizados para publicar en cada uno."
  type = map(object({
    name                 = string
    github_repository    = string
    github_repository_id = string
  }))

  validation {
    condition = alltrue([
      for repository in values(var.repositories) :
      can(regex("^[a-z0-9]+(?:[._/-][a-z0-9]+)*$", repository.name)) &&
      can(regex("^[A-Za-z0-9_.-]+$", repository.github_repository)) &&
      can(regex("^[0-9]+$", repository.github_repository_id))
    ])
    error_message = "Los nombres ECR y GitHub no tienen un formato válido."
  }
}

variable "github_organization" {
  description = "Organización propietaria de los repositorios GitHub."
  type        = string
}

variable "github_organization_id" {
  description = "ID numérico inmutable de la organización GitHub."
  type        = string

  validation {
    condition     = can(regex("^[0-9]+$", var.github_organization_id))
    error_message = "github_organization_id debe ser el ID numérico inmutable de GitHub."
  }
}

variable "github_environment" {
  description = "Environment GitHub de producción cuyo subject OIDC puede publicar artefactos retenidos."
  type        = string
  default     = "production"

  validation {
    condition     = var.github_environment == "production"
    error_message = "Los roles publicadores ECR solo pueden confiar en el environment production."
  }
}

variable "github_oidc_provider_arn" {
  description = "ARN del proveedor token.actions.githubusercontent.com administrado por bootstrap."
  type        = string

  validation {
    condition     = can(regex("^arn:[^:]+:iam::[0-9]{12}:oidc-provider/token\\.actions\\.githubusercontent\\.com$", var.github_oidc_provider_arn))
    error_message = "github_oidc_provider_arn debe ser el ARN del proveedor OIDC de GitHub Actions."
  }
}

variable "images_to_keep" {
  description = "Cantidad máxima de imágenes de release productiva por repositorio antes de expirar las más antiguas."
  type        = number
  default     = 30

  validation {
    condition     = var.images_to_keep >= 5 && var.images_to_keep <= 500
    error_message = "images_to_keep debe estar entre 5 y 500."
  }
}

variable "untagged_retention_days" {
  description = "Días que se conservan imágenes sin tag, incluidas attestations huérfanas."
  type        = number
  default     = 7

  validation {
    condition     = var.untagged_retention_days >= 1 && var.untagged_retention_days <= 30
    error_message = "untagged_retention_days debe estar entre 1 y 30."
  }
}

variable "tags" {
  type    = map(string)
  default = {}
}
