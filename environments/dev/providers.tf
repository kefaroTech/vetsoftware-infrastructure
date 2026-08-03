provider "aws" {
  region = var.aws_region

  default_tags {
    tags = merge(var.tags, {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "Terraform"
      Repository  = "VetSoftwareIaC"
    })
  }
}

provider "random" {}

data "aws_caller_identity" "current" {}
