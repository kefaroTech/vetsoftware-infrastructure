variable "project_name" {
  description = "Nombre corto del proyecto."
  type        = string
  default     = "vetsoftware"

  validation {
    condition     = can(regex("^[a-z0-9-]{3,30}$", var.project_name))
    error_message = "project_name debe usar minúsculas, números y guiones."
  }
}

variable "environment" {
  description = "Nombre del ambiente."
  type        = string
  default     = "prod"

  validation {
    condition     = can(regex("^[a-z0-9-]{2,15}$", var.environment))
    error_message = "environment debe usar minúsculas, números y guiones."
  }
}

variable "aws_region" {
  description = "Región donde se almacena el estado."
  type        = string
  default     = "us-east-1"
}

variable "state_bucket_name" {
  description = "Nombre opcional del bucket. Vacío genera uno estable con account ID."
  type        = string
  default     = ""
}

variable "enable_kms" {
  description = "Crea una KMS key dedicada para el estado. Agrega aproximadamente USD 1/mes."
  type        = bool
  default     = true
}

variable "github_organization" {
  description = "Organización GitHub autorizada para publicar imágenes mediante OIDC."
  type        = string
  default     = "kefaroTech"
}

variable "github_organization_id" {
  description = "ID numérico inmutable de la organización GitHub."
  type        = string
}

variable "github_environment" {
  description = "Environment protegido de GitHub usado por los workflows de release."
  type        = string
  default     = "production"
}

variable "existing_github_oidc_provider_arn" {
  description = "ARN del proveedor OIDC de GitHub Actions si ya existe en la cuenta AWS."
  type        = string
  default     = ""
}

variable "github_repositories" {
  description = "Repositorios GitHub de cada componente publicable."
  type = object({
    backend       = string
    private_front = string
    public_front  = string
  })
  default = {
    backend       = "VetSoftware"
    private_front = "VetSoftwareFront"
    public_front  = "VetSoftwarePublicFront"
  }
}

variable "github_repository_ids" {
  description = "IDs numéricos inmutables de los repositorios GitHub."
  type = object({
    backend       = string
    private_front = string
    public_front  = string
  })
}

variable "ecr_images_to_keep" {
  description = "Cantidad de imágenes que conserva cada repositorio ECR."
  type        = number
  default     = 30
}

variable "tags" {
  description = "Etiquetas adicionales."
  type        = map(string)
  default     = {}
}
