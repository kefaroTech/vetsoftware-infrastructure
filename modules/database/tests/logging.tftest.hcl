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
  name               = "vetsoftware-test-mysql"
  subnet_ids         = ["subnet-11111111111111111", "subnet-22222222222222222"]
  security_group_ids = ["sg-11111111111111111"]
  kms_key_arn        = "arn:aws:kms:us-east-1:123456789012:key/11111111-2222-3333-4444-555555555555"
}

# El hallazgo INF-14 tenia dos mitades independientes y cada una necesita su
# propia barrera: el log general no puede exportarse, y los logs que si se
# exportan no pueden vivir para siempre ni cifrarse con la clave de AWS.

run "general_log_is_never_exported" {
  command = plan

  assert {
    condition     = !contains(aws_db_instance.this.enabled_cloudwatch_logs_exports, "general")
    error_message = "El log general de MySQL registra el texto de cada consulta con datos personales; no puede exportarse."
  }

  assert {
    condition     = toset(aws_db_instance.this.enabled_cloudwatch_logs_exports) == toset(["error", "slowquery"])
    error_message = "Por defecto la instancia solo publica error y slowquery."
  }
}

# Quitar la exportacion deja el dato en el disco de la instancia. El parametro es
# dinamico: sin fijarlo, encenderlo desde la consola no requiere reinicio y no
# deja rastro en Terraform.
run "general_log_parameter_is_pinned_off" {
  command = plan

  assert {
    condition = anytrue([
      for parameter in aws_db_parameter_group.this.parameter :
      parameter.name == "general_log" && parameter.value == "0"
    ])
    error_message = "El parameter group debe fijar general_log en 0 para que el drift detection revierta un encendido manual."
  }
}

run "log_groups_are_managed_with_retention_and_cmk" {
  command = plan

  variables {
    log_retention_days = 30
  }

  assert {
    condition = toset([for group in aws_cloudwatch_log_group.database : group.name]) == toset([
      "/aws/rds/instance/vetsoftware-test-mysql/error",
      "/aws/rds/instance/vetsoftware-test-mysql/slowquery",
    ])
    error_message = "Terraform debe declarar un log group por exportacion, con el nombre exacto que RDS usaria."
  }

  assert {
    condition = alltrue([
      for group in aws_cloudwatch_log_group.database :
      group.retention_in_days == 30 && group.kms_key_id == var.kms_key_arn
    ])
    error_message = "Los log groups de RDS deben caducar y cifrarse con la CMK del entorno, no con la clave gestionada por AWS."
  }
}

run "rejects_general_log_explicitly" {
  command = plan

  variables {
    enabled_log_exports = ["error", "general", "slowquery"]
  }

  expect_failures = [var.enabled_log_exports]
}

# 0 es el valor que CloudWatch interpreta como "no caduca nunca": es exactamente
# el estado que este cambio corrige, asi que no puede volver por la puerta de una
# variable.
run "rejects_infinite_retention" {
  command = plan

  variables {
    log_retention_days = 0
  }

  expect_failures = [var.log_retention_days]
}
