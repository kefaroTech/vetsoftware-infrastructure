terraform {
  required_version = "~> 1.15.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.60.0"
    }

    # Empaqueta el codigo de la Lambda en el propio plan. La alternativa era
    # commitear un zip, que es un binario en el repositorio que nadie revisa y
    # que se desincroniza del fuente sin avisar.
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.7"
    }
  }
}
