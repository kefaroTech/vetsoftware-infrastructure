terraform {
  required_version = "~> 1.15.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.60.0"
    }

    # La contrasena de Valkey se genera aqui y se persiste en el state: el modulo
    # necesita declarar su propio proveedor y no heredarlo por accidente de la raiz.
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9.0"
    }
  }
}
