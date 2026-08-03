variable "project_name" {
  description = "Nombre corto del proyecto."
  type        = string
  default     = "vetsoftware"

  validation {
    condition     = can(regex("^[a-z0-9-]{3,30}$", var.project_name))
    error_message = "project_name debe usar minusculas, numeros y guiones."
  }
}

variable "environment" {
  description = "Ambiente exclusivo administrado por este state de bootstrap."
  type        = string

  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "environment debe ser dev o prod."
  }
}

variable "aws_region" {
  description = "Region AWS del ambiente."
  type        = string
  default     = "us-east-1"
}

variable "state_bucket_name" {
  description = "Bucket remoto exclusivo del ambiente, creado antes de Terraform por CloudFormation."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.state_bucket_name))
    error_message = "state_bucket_name debe ser un nombre de bucket S3 valido."
  }
}

variable "state_kms_key_arn" {
  description = "KMS key exclusiva que cifra el state del ambiente."
  type        = string

  validation {
    condition     = can(regex("^arn:[^:]+:kms:[a-z0-9-]+:[0-9]{12}:key/[0-9a-f-]+$", var.state_kms_key_arn))
    error_message = "state_kms_key_arn debe ser el ARN de una KMS key."
  }
}

variable "github_organization" {
  description = "Organizacion GitHub propietaria de los repositorios."
  type        = string
  default     = "kefaroTech"
}

variable "github_organization_id" {
  description = "ID numerico inmutable de la organizacion GitHub."
  type        = string

  validation {
    condition     = can(regex("^[0-9]+$", var.github_organization_id))
    error_message = "github_organization_id debe ser numerico."
  }
}

variable "existing_github_oidc_provider_arn" {
  description = "Proveedor OIDC de GitHub creado una sola vez fuera de Terraform."
  type        = string

  validation {
    condition     = can(regex("^arn:[^:]+:iam::[0-9]{12}:oidc-provider/token\\.actions\\.githubusercontent\\.com$", var.existing_github_oidc_provider_arn))
    error_message = "existing_github_oidc_provider_arn debe identificar el proveedor OIDC oficial de GitHub Actions."
  }
}

variable "github_repositories" {
  description = "Repositorios GitHub de aplicaciones e infraestructura."
  type = object({
    backend       = string
    private_front = string
    public_front  = string
    iac           = string
  })
  default = {
    backend       = "VetSoftware"
    private_front = "VetSoftwareFront"
    public_front  = "VetSoftwarePublicFront"
    iac           = "vetsoftware-infrastructure"
  }
}

variable "github_repository_ids" {
  description = "IDs numericos inmutables de los repositorios GitHub."
  type = object({
    backend       = string
    private_front = optional(string, "")
    public_front  = optional(string, "")
    iac           = string
  })

  validation {
    condition = (
      can(regex("^[0-9]+$", var.github_repository_ids.backend)) &&
      can(regex("^[0-9]+$", var.github_repository_ids.iac)) &&
      (var.github_repository_ids.private_front == "" || can(regex("^[0-9]+$", var.github_repository_ids.private_front))) &&
      (var.github_repository_ids.public_front == "" || can(regex("^[0-9]+$", var.github_repository_ids.public_front)))
    )
    error_message = "backend e iac requieren IDs numericos; los IDs de fronts son opcionales para dev."
  }
}

variable "ecr_images_to_keep" {
  description = "Cantidad de imagenes retenidas en los repositorios del ambiente."
  type        = number
  default     = 30
}

variable "tags" {
  description = "Etiquetas adicionales."
  type        = map(string)
  default     = {}
}
