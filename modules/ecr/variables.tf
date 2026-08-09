variable "project_name" {
  description = "Nombre corto usado en roles IAM y etiquetas."
  type        = string
}

variable "repositories" {
  description = "Repositorios ECR y repositorios GitHub autorizados para publicar en cada uno."
  type = map(object({
    name                    = string
    github_repository       = string
    github_repository_id    = string
    production_publication  = optional(bool, true)
    development_publication = optional(bool, false)
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
    error_message = "El rol publicador de releases solo puede confiar en el environment production."
  }
}

variable "github_development_environment" {
  description = "Environment GitHub que publica imágenes de desarrollo. Solo aplica a los repositorios con development_publication activo y usa un rol propio, distinto del de release."
  type        = string
  default     = "development"

  validation {
    condition     = var.github_development_environment == "development"
    error_message = "El rol publicador de desarrollo solo puede confiar en el environment development."
  }
}

variable "development_retention_days" {
  description = "Días que se conservan las imágenes de desarrollo. Es el tiempo que un ambiente puede pasar sin desplegar y seguir pudiendo arrancar con la imagen que tiene fijada."
  type        = number
  default     = 30

  # El minimo no es arbitrario: por debajo de una semana, un ambiente apagado el
  # viernes y encendido tras un puente ya podria no encontrar su imagen.
  validation {
    condition     = var.development_retention_days >= 7 && var.development_retention_days <= 365
    error_message = "development_retention_days debe estar entre 7 y 365."
  }
}

variable "development_images_to_keep" {
  description = "Tope de imágenes de desarrollo por repositorio. Acota el coste ante una racha de compilaciones; la retención normal la fija development_retention_days."
  type        = number
  default     = 150

  # Cada imagen de mas cuesta ~1 centavo al mes: comparten siete de sus ocho
  # capas y solo la del aplicativo es exclusiva, unos 106 MiB. El tope existe
  # para que una racha anomala no se desborde, no para ahorrar.
  validation {
    condition     = var.development_images_to_keep >= 10 && var.development_images_to_keep <= 1000
    error_message = "development_images_to_keep debe estar entre 10 y 1000."
  }
}

variable "development_tag_prefix" {
  description = "Prefijo obligatorio de los tags publicados desde develop. Aísla los artefactos de dev de los tags de release."
  type        = string
  default     = "dev-"

  validation {
    condition     = can(regex("^[a-z0-9]+-$", var.development_tag_prefix))
    error_message = "development_tag_prefix debe ser minúsculas y terminar en guion."
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
