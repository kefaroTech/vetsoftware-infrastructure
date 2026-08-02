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

data "aws_lb" "shared" {
  name = "${var.project_name}-${var.shared_environment}"
}

data "aws_lb_listener" "shared" {
  load_balancer_arn = data.aws_lb.shared.arn
  port              = var.shared_alb_listener_port
}

data "aws_security_group" "shared_alb" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.shared.id]
  }

  filter {
    name   = "tag:Name"
    values = ["${var.project_name}-${var.shared_environment}-alb"]
  }
}

data "aws_security_group" "shared_vpc_endpoints" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.shared.id]
  }

  filter {
    name   = "tag:Name"
    values = ["${var.project_name}-${var.shared_environment}-vpc-endpoints"]
  }
}
