variable "project_name" {
  description = "Nombre corto usado como prefijo de los roles y recursos administrados."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9-]{3,30}$", var.project_name))
    error_message = "project_name debe usar minúsculas, números y guiones."
  }
}

variable "aws_partition" {
  description = "Partición AWS de la cuenta objetivo."
  type        = string
  default     = "aws"
}

variable "aws_account_id" {
  description = "ID de la cuenta AWS donde Terraform administra la infraestructura."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "aws_account_id debe contener exactamente 12 dígitos."
  }
}

variable "aws_region" {
  description = "Única región permitida para mutaciones de infraestructura regional."
  type        = string
}

variable "backend_repository_name" {
  description = "Repositorio ECR del backend que este ambiente puede inspeccionar."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]+(?:[._/-][a-z0-9]+)*$", var.backend_repository_name))
    error_message = "backend_repository_name debe ser un nombre ECR valido."
  }
}

variable "github_oidc_provider_arn" {
  description = "ARN del proveedor OIDC token.actions.githubusercontent.com."
  type        = string

  validation {
    condition     = can(regex("^arn:[^:]+:iam::[0-9]{12}:oidc-provider/token\\.actions\\.githubusercontent\\.com$", var.github_oidc_provider_arn))
    error_message = "github_oidc_provider_arn debe identificar al proveedor OIDC oficial de GitHub Actions."
  }
}

variable "github_organization" {
  description = "Organización propietaria del repositorio IaC."
  type        = string
}

variable "github_organization_id" {
  description = "ID numérico inmutable de la organización GitHub."
  type        = string

  validation {
    condition     = can(regex("^[0-9]+$", var.github_organization_id))
    error_message = "github_organization_id debe ser numérico."
  }
}

variable "github_repository" {
  description = "Nombre del repositorio GitHub que contiene Terraform."
  type        = string
}

variable "github_repository_id" {
  description = "ID numérico inmutable del repositorio GitHub IaC."
  type        = string

  validation {
    condition     = can(regex("^[0-9]+$", var.github_repository_id))
    error_message = "github_repository_id debe ser numérico."
  }
}

variable "state_bucket_name" {
  description = "Bucket S3 que contiene los states de Terraform."
  type        = string
}

variable "state_kms_key_arn" {
  description = "KMS key que cifra state y lockfiles; null cuando el bucket usa SSE-S3."
  type        = string
  default     = null
  nullable    = true
}

variable "environments" {
  description = "Entornos y GitHub Environments exclusivos para plan y apply."
  type = map(object({
    state_key                 = string
    github_plan_environment   = string
    github_apply_environment  = string
    additional_s3_bucket_arns = optional(set(string), [])
  }))

  validation {
    condition = alltrue([
      for name, config in var.environments :
      can(regex("^[a-z0-9-]{2,15}$", name)) &&
      can(regex("^[A-Za-z0-9_.-]{3,50}$", config.github_plan_environment)) &&
      can(regex("^[A-Za-z0-9_.-]{3,50}$", config.github_apply_environment)) &&
      config.github_plan_environment != config.github_apply_environment &&
      can(regex("^[A-Za-z0-9!_.*'()/{}:@&+$,?%#=-]+/[^/]+/terraform\\.tfstate$", config.state_key)) &&
      alltrue([
        for arn in config.additional_s3_bucket_arns :
        can(regex("^arn:[^:]+:s3:::[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", arn))
      ])
    ])
    error_message = "Cada entorno requiere state_key válido y GitHub Environments distintos para plan y apply."
  }
}

variable "tags" {
  description = "Etiquetas comunes."
  type        = map(string)
  default     = {}
}
