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
  name           = "vetsoftware-test"
  aws_account_id = "123456789012"
  aws_region     = "us-east-1"
  kms_key_arn    = "arn:aws:kms:us-east-1:123456789012:key/11111111-2222-3333-4444-555555555555"
}

# INF-49 no se cierra con "hay un CloudTrail": se cierra con un rastro que cubra
# toda la cuenta, que permita reconstruir quien accedio a los documentos con
# datos personales, y cuya evidencia no pueda alterarla quien tenga que
# responder por ella.

run "the_trail_covers_the_whole_account" {
  command = plan

  assert {
    condition = (
      aws_cloudtrail.this.is_multi_region_trail &&
      aws_cloudtrail.this.include_global_service_events
    )
    error_message = "Un rastro de una sola region deja fuera lo que ocurra en las demas, incluidos los servicios globales como IAM."
  }

  assert {
    condition     = aws_cloudtrail.this.enable_log_file_validation
    error_message = "Sin digests firmados el propio registro es repudiable: no se puede demostrar que nadie lo edito."
  }

  assert {
    condition     = aws_cloudtrail.this.kms_key_id == var.kms_key_arn
    error_message = "El rastro debe cifrarse con la CMK del entorno, no con la clave gestionada por AWS."
  }
}

# La evidencia tiene que sobrevivir a quien la incomoda. COMPLIANCE es el unico
# modo que ni el root de la cuenta puede levantar.
run "evidence_cannot_be_erased" {
  command = plan

  assert {
    condition = (
      aws_s3_bucket.trail.object_lock_enabled &&
      !aws_s3_bucket.trail.force_destroy
    )
    error_message = "El bucket del rastro debe tener Object Lock y no admitir force_destroy."
  }

  assert {
    condition = alltrue([
      for rule in aws_s3_bucket_object_lock_configuration.trail.rule :
      alltrue([for retention in rule.default_retention : retention.mode == "COMPLIANCE" && retention.days >= 1825])
    ])
    error_message = "La retencion debe ser COMPLIANCE y cubrir cinco anios."
  }
}

# El destino del access logging es la pieza que responde "quien descargo este
# documento" sin factura. S3 no entrega a un destino cifrado con SSE-KMS, asi
# que AES256 no es un descuido.
run "read_access_is_reconstructable_for_free" {
  command = plan

  assert {
    condition = alltrue([
      for rule in aws_s3_bucket_server_side_encryption_configuration.access_logs.rule :
      alltrue([
        for default in rule.apply_server_side_encryption_by_default :
        default.sse_algorithm == "AES256"
      ])
    ])
    error_message = "El destino del access logging debe usar AES256: S3 no entrega registros a un bucket cifrado con SSE-KMS."
  }

  assert {
    condition = anytrue([
      for statement in jsondecode(data.aws_iam_policy_document.access_logs_bucket.json).Statement :
      statement.Sid == "AllowS3ServerAccessLogging" &&
      statement.Condition.StringEquals["aws:SourceAccount"] == "123456789012"
    ])
    error_message = "Solo la propia cuenta puede depositar access logs en el destino."
  }

  assert {
    condition = alltrue([
      for rule in aws_s3_bucket_lifecycle_configuration.access_logs.rule :
      alltrue([for expiration in rule.expiration : expiration.days > 0])
    ])
    error_message = "Los access logs deben caducar: el almacenamiento es el unico coste del modulo y no puede crecer sin techo."
  }
}

# La restriccion es que la solucion no genere coste. Los defaults son el sitio
# donde eso se cumple o se rompe, asi que se fijan aqui.
run "nothing_billable_is_on_by_default" {
  command = plan

  assert {
    condition     = length(aws_guardduty_detector.this) == 0
    error_message = "GuardDuty se factura por volumen analizado: no puede quedar encendido por defecto."
  }

  assert {
    condition = !anytrue([
      for selector in aws_cloudtrail.this.advanced_event_selector :
      selector.name == "S3 data events on regulated buckets"
    ])
    error_message = "Los data events se facturan por evento: no pueden quedar encendidos por defecto."
  }

  # Lo gratuito si tiene que estar encendido, o el hallazgo sigue abierto.
  assert {
    condition = (
      length(aws_accessanalyzer_analyzer.account) == 1 &&
      length(aws_cloudtrail.this.advanced_event_selector) == 1
    )
    error_message = "Los management events y el Access Analyzer son gratuitos y deben venir activos."
  }
}

# Encendidos a proposito, el cableado tiene que ser el correcto.
run "billable_controls_wire_correctly_when_enabled" {
  command = plan

  variables {
    enable_guardduty      = true
    enable_s3_data_events = true
    regulated_bucket_arns = ["arn:aws:s3:::vetsoftware-test-app/"]
    alarm_topic_arn       = "arn:aws:sns:us-east-1:123456789012:vetsoftware-test-alarms"
  }

  assert {
    condition = anytrue([
      for selector in aws_cloudtrail.this.advanced_event_selector :
      anytrue([
        for field in selector.field_selector :
        field.field == "resources.ARN" && contains(field.starts_with, "arn:aws:s3:::vetsoftware-test-app/")
      ])
    ])
    error_message = "El selector de data events debe apuntar a los buckets regulados que recibe el modulo."
  }

  assert {
    condition = (
      length(aws_guardduty_detector.this) == 1 &&
      length(aws_guardduty_detector_feature.rds_login) == 1 &&
      length(aws_cloudwatch_event_target.guardduty) == 1
    )
    error_message = "GuardDuty debe cubrir los inicios de sesion contra RDS y enrutar sus hallazgos al topic del entorno."
  }
}

# Un entorno sin canal configurado no puede quedarse sin detector: se degrada el
# ruteo, no la deteccion.
run "detection_survives_without_a_channel" {
  command = plan

  variables {
    enable_guardduty = true
  }

  assert {
    condition = (
      length(aws_guardduty_detector.this) == 1 &&
      length(aws_cloudwatch_event_rule.guardduty) == 0
    )
    error_message = "Sin topic el detector debe crearse igual y omitirse solo el ruteo."
  }
}

run "rejects_retention_below_five_years" {
  command = plan

  variables {
    trail_retention_days = 365
  }

  expect_failures = [var.trail_retention_days]
}

# Un ARN de bucket pelado prefija tambien al bucket homonimo mas largo, asi que
# el selector registraria objetos de otro bucket.
run "rejects_bucket_arn_without_trailing_slash" {
  command = plan

  variables {
    regulated_bucket_arns = ["arn:aws:s3:::vetsoftware-test-app"]
  }

  expect_failures = [var.regulated_bucket_arns]
}
