provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test-only-access-key"
  secret_key                  = "test-only-secret-key"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_region_validation      = true
  skip_requesting_account_id  = true
}

variables {
  name               = "vetsoftware-test-valkey"
  subnet_ids         = ["subnet-11111111111111111", "subnet-22222222222222222"]
  security_group_ids = ["sg-11111111111111111"]
  kms_key_arn        = "arn:aws:kms:us-east-1:123456789012:key/11111111-2222-3333-4444-555555555555"
}

# El hallazgo INF-17 tiene dos mitades: la contrasena que dos consumidores tienen
# que compartir y el cifrado en reposo. Cada una necesita su propia barrera.
#
# Lo que este contrato NO puede ver: los argumentos write-only -passwords_wo y
# secret_string_wo- valen null en el plan por definicion, asi que ningun assert
# puede comparar las dos contrasenas literalmente. Lo observable es su versionado,
# que es exactamente el mecanismo que decide si Terraform las reescribe.

run "both_consumers_share_one_versioned_password" {
  command = plan

  # random_password sustituyo a un bloque ephemeral. Si alguien lo revierte, este
  # assert cae: un ephemeral no tiene keepers ni aparece en el plan como recurso.
  assert {
    condition     = random_password.valkey.keepers["password_version"] == tostring(var.password_version)
    error_message = "La contrasena debe generarse con un random_password persistido y regenerarse solo cuando cambia password_version; un valor efimero diverge entre applies."
  }

  # El nucleo de la invariante: si estas dos versiones se separan, Terraform
  # reescribe uno de los consumidores y el otro no, y el backend arranca en crash
  # loop con WRONGPASS.
  assert {
    condition = (
      aws_elasticache_user.application.passwords_wo_version ==
      aws_secretsmanager_secret_version.connection.secret_string_wo_version
    )
    error_message = "El usuario RBAC y el secreto REDIS_URL deben compartir la misma version de contrasena: si divergen, el secreto anuncia credenciales que el usuario no acepta."
  }

  assert {
    condition = (
      aws_elasticache_user.application.passwords_wo_version == var.password_version &&
      aws_secretsmanager_secret_version.connection.secret_string_wo_version == var.password_version
    )
    error_message = "Ambos consumidores deben versionarse con var.password_version, que es la unica palanca de rotacion del modulo."
  }
}

# Rotar es subir la version: los tres recursos tienen que moverse juntos, no solo
# el que se edito.
run "rotation_moves_every_consumer_together" {
  command = plan

  variables {
    password_version = 7
  }

  assert {
    condition = (
      random_password.valkey.keepers["password_version"] == "7" &&
      aws_elasticache_user.application.passwords_wo_version == 7 &&
      aws_secretsmanager_secret_version.connection.secret_string_wo_version == 7
    )
    error_message = "Al incrementar password_version deben moverse a la vez el generador, el usuario RBAC y el secreto; si uno se queda atras la rotacion deja el par desincronizado."
  }
}

run "cache_encrypts_with_the_environment_cmk" {
  command = plan

  assert {
    condition     = aws_elasticache_serverless_cache.this.kms_key_id == var.kms_key_arn
    error_message = "El cache debe cifrarse con la CMK del entorno: los datos incluyen sesiones y respuestas con datos de pacientes, y la clave gestionada por AWS tiene una politica que el proyecto no controla."
  }

  assert {
    condition     = aws_secretsmanager_secret.connection.name == "${var.name}/connection"
    error_message = "El secreto de conexion debe colgar del nombre del cache para que las politicas por prefijo lo alcancen."
  }
}

# Un ARN mal escrito no falla en el plan: AWS lo rechaza en el apply, a mitad del
# grafo y despues de haber tocado otros recursos.
run "rejects_a_kms_key_that_is_not_an_arn" {
  command = plan

  variables {
    kms_key_arn = "11111111-2222-3333-4444-555555555555"
  }

  expect_failures = [var.kms_key_arn]
}

# Bajar la version no rota nada -deja los dos consumidores como estaban- y da la
# falsa impresion de haber rotado.
run "rejects_a_non_positive_password_version" {
  command = plan

  variables {
    password_version = 0
  }

  expect_failures = [var.password_version]
}
