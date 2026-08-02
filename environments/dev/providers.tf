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

data "aws_vpc" "shared" {
  filter {
    name   = "tag:Name"
    values = ["${var.project_name}-${var.shared_environment}-vpc"]
  }
}

data "aws_subnets" "shared_public" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.shared.id]
  }

  filter {
    name   = "tag:Tier"
    values = ["public"]
  }

  filter {
    name   = "tag:Environment"
    values = [var.shared_environment]
  }
}

data "aws_subnets" "shared_data" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.shared.id]
  }

  filter {
    name   = "tag:Tier"
    values = ["data"]
  }

  filter {
    name   = "tag:Environment"
    values = [var.shared_environment]
  }
}
