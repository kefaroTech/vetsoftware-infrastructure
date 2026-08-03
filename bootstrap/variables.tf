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
  description = "Etiqueta del bootstrap. No pertenece a dev ni a prod: nombra la plataforma comun que ambos consumen antes de existir."
  type        = string
  default     = "shared"

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
  description = "Environment protegido de GitHub usado exclusivamente para publicar releases productivas."
  type        = string
  default     = "production"

  validation {
    condition     = var.github_environment == "production"
    error_message = "ECR es production-only: github_environment debe ser production."
  }
}

variable "existing_github_oidc_provider_arn" {
  description = "ARN del proveedor OIDC de GitHub Actions si ya existe en la cuenta AWS."
  type        = string
  default     = ""
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
    iac           = "VetSoftwareIaC"
  }
}

variable "github_repository_ids" {
  description = "IDs numéricos inmutables de los repositorios GitHub."
  type = object({
    backend       = string
    private_front = string
    public_front  = string
    iac           = string
  })
}

variable "github_iac_environments" {
  description = "GitHub Environments y state key exclusivos para plan/apply de cada entorno IaC."
  type = map(object({
    state_key                 = string
    github_plan_environment   = string
    github_apply_environment  = string
    additional_s3_bucket_arns = optional(set(string), [])
  }))
  default = {
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

  validation {
    condition     = toset(keys(var.github_iac_environments)) == toset(["dev", "prod"])
    error_message = "github_iac_environments debe definir exactamente dev y prod."
  }
}

variable "ecr_images_to_keep" {
  description = "Cantidad de imágenes de release productiva que conserva cada repositorio ECR."
  type        = number
  default     = 30
}

variable "tags" {
  description = "Etiquetas adicionales."
  type        = map(string)
  default     = {}
}
