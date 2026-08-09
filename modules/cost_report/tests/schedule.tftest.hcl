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
  name           = "vetsoftware-dev-cost-report"
  aws_account_id = "123456789012"
  aws_region     = "us-east-1"
  topic_arn      = "arn:aws:sns:us-east-1:123456789012:vetsoftware-dev-finops"
  kms_key_arn    = "arn:aws:kms:us-east-1:123456789012:key/11111111-2222-3333-4444-555555555555"
}

# El motivo entero de que este modulo exista es la puntualidad: el cron de GitHub
# llegaba entre dos y seis horas tarde todos los dias. Si el reloj se afloja, el
# modulo deja de tener sentido, asi que la hora y la ausencia de ventana flexible
# son contrato y no configuracion.
run "el_reloj_es_puntual_y_de_aws" {
  command = plan

  assert {
    condition     = one(aws_scheduler_schedule.this.flexible_time_window).mode == "OFF"
    error_message = "Una ventana flexible devuelve el problema que este modulo viene a resolver: el informe llegaria a una hora imprecisa."
  }

  assert {
    condition     = aws_scheduler_schedule.this.schedule_expression_timezone == "America/Bogota"
    error_message = "El schedule debe expresarse en la zona de quien lee el informe; el cron de GitHub solo entendia UTC."
  }

  assert {
    condition     = aws_scheduler_schedule.this.schedule_expression == "cron(0 7 * * ? *)"
    error_message = "El informe debe salir a las 07:00 de Bogota."
  }

  # Reintentar una consulta que se factura por request no compensa: si el informe
  # de hoy falla, el de manana cubre el mismo dato.
  assert {
    condition = alltrue([
      for target in aws_scheduler_schedule.this.target :
      alltrue([for retry in target.retry_policy : retry.maximum_retry_attempts == 0])
    ])
    error_message = "El informe no debe reintentarse: cada consulta a Cost Explorer se factura."
  }
}

run "la_funcion_solo_puede_leer_costos_y_publicar" {
  command = plan

  # Cost Explorer no admite acotar por recurso, asi que el control es la lista de
  # acciones: una sola, de lectura. Si aparece cualquier otra ce:*, el rol deja de
  # ser un lector de costos.
  assert {
    condition = alltrue([
      for statement in jsondecode(data.aws_iam_policy_document.this.json).Statement :
      flatten([statement.Action]) == ["ce:GetCostAndUsage"] if statement.Sid == "ReadDailyCost"
    ])
    error_message = "La funcion solo puede leer el costo; cualquier otra accion de Cost Explorer sobra."
  }

  # El topic esta cifrado con la CMK del entorno, que tambien protege el bucket de
  # aplicacion y los logs. Publicar un aviso no es motivo para poder descifrar eso.
  assert {
    condition = anytrue([
      for statement in jsondecode(data.aws_iam_policy_document.this.json).Statement :
      try(statement.Condition.StringEquals["kms:ViaService"], "") == "sns.us-east-1.amazonaws.com"
      if statement.Sid == "EncryptCostReport"
    ])
    error_message = "El permiso de KMS debe acotarse a SNS: la CMK cifra tambien datos de la aplicacion."
  }

  # Sin CreateLogGroup a proposito: si alguien borra el grupo, el fallo se ve en
  # lugar de recrearse uno sin caducidad ni cifrado.
  assert {
    condition     = !strcontains(data.aws_iam_policy_document.this.json, "logs:CreateLogGroup")
    error_message = "La funcion no debe poder crear su log group; Terraform lo crea con retencion y CMK."
  }
}

run "el_paquete_se_arma_desde_el_fuente" {
  command = plan

  assert {
    condition     = aws_lambda_function.this.handler == "cost_report.handler"
    error_message = "El handler debe apuntar al modulo portado."
  }

  # Si el zip se commiteara, el fuente y lo desplegado podrian divergir sin que
  # nada avise. Se arma en el plan desde src/.
  assert {
    condition     = endswith(data.archive_file.source.source_dir, "src")
    error_message = "El paquete debe armarse desde el fuente, no desde un zip versionado."
  }
}

run "rechaza_una_retencion_infinita" {
  command = plan

  variables {
    log_retention_days = 0
  }

  expect_failures = [var.log_retention_days]
}
