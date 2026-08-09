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
  project_name             = "vetsoftware"
  aws_account_id           = "123456789012"
  aws_region               = "us-east-1"
  backend_repository_name  = "vetsoftware-backend"
  github_oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
  github_organization      = "kefaroTech"
  github_organization_id   = "12345678"
  github_repository        = "VetSoftwareIaC"
  github_repository_id     = "100000004"
  state_bucket_name        = "vetsoftware-prod-tfstate-123456789012"
  state_kms_key_arn        = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000000"
  environments = {
    dev = {
      state_key                = "vetsoftware/dev/terraform.tfstate"
      github_plan_environment  = "iac-plan-dev"
      github_apply_environment = "iac-apply-dev"
    }
    prod = {
      state_key                = "vetsoftware/prod/terraform.tfstate"
      github_plan_environment  = "iac-plan-prod"
      github_apply_environment = "iac-apply-prod"
    }
  }
}

run "environment_and_function_roles_are_isolated" {
  command = plan


  assert {
    condition = length(aws_iam_role.this) == 4 && toset(keys(aws_iam_role.this)) == toset([
      "dev_apply",
      "dev_plan",
      "prod_apply",
      "prod_plan",
    ])
    error_message = "Deben existir exactamente cuatro roles: plan y apply para dev y prod."
  }

  assert {
    condition = alltrue([
      aws_iam_role.this["dev_plan"].name == "vetsoftware-iac-plan-dev",
      aws_iam_role.this["dev_apply"].name == "vetsoftware-iac-apply-dev",
      aws_iam_role.this["prod_plan"].name == "vetsoftware-iac-plan-prod",
      aws_iam_role.this["prod_apply"].name == "vetsoftware-iac-apply-prod",
    ])
    error_message = "Los nombres de los roles deben conservar entorno y función."
  }

  assert {
    condition = alltrue([
      strcontains(data.aws_iam_policy_document.assume["dev_plan"].json, "repo:kefaroTech@12345678/VetSoftwareIaC@100000004:environment:iac-plan-dev"),
      strcontains(data.aws_iam_policy_document.assume["dev_apply"].json, "repo:kefaroTech@12345678/VetSoftwareIaC@100000004:environment:iac-apply-dev"),
      strcontains(data.aws_iam_policy_document.assume["prod_plan"].json, "repo:kefaroTech@12345678/VetSoftwareIaC@100000004:environment:iac-plan-prod"),
      strcontains(data.aws_iam_policy_document.assume["prod_apply"].json, "repo:kefaroTech@12345678/VetSoftwareIaC@100000004:environment:iac-apply-prod"),
    ])
    error_message = "Cada trust policy debe exigir el subject inmutable y su GitHub Environment exclusivo."
  }

  # El job de plan corre sin environment en un pull_request, porque la deployment
  # branch policy no puede casar con refs/pull/N/merge. Apply no recibe ese sujeto:
  # es donde vive la aprobacion manual y abrirlo a un PR la eliminaria.
  assert {
    condition = alltrue([
      strcontains(data.aws_iam_policy_document.assume["dev_plan"].json, "repo:kefaroTech@12345678/VetSoftwareIaC@100000004:pull_request"),
      strcontains(data.aws_iam_policy_document.assume["prod_plan"].json, "repo:kefaroTech@12345678/VetSoftwareIaC@100000004:pull_request"),
      !strcontains(data.aws_iam_policy_document.assume["dev_apply"].json, ":pull_request"),
      !strcontains(data.aws_iam_policy_document.assume["prod_apply"].json, ":pull_request"),
    ])
    error_message = "Solo los roles de plan admiten el sujeto pull_request; apply se limita a su GitHub Environment."
  }

  # Dos sujetos exactos y ninguno mas: si alguien cambiara el StringEquals por un
  # comodin, cualquier workflow del repositorio podria asumir el rol de plan.
  assert {
    condition = alltrue([
      for key in ["dev_plan", "prod_plan"] :
      length([
        for statement in jsondecode(data.aws_iam_policy_document.assume[key].json).Statement :
        statement if length(statement.Condition.StringEquals["token.actions.githubusercontent.com:sub"]) == 2
      ]) == 1
    ])
    error_message = "El rol de plan debe enumerar exactamente dos sujetos y seguir siendo StringEquals."
  }

  assert {
    condition = alltrue([
      length([for statement in jsondecode(data.aws_iam_policy_document.state["dev_plan"].json).Statement : statement if statement.Sid == "WriteEnvironmentState"]) == 0,
      length([for statement in jsondecode(data.aws_iam_policy_document.state["prod_plan"].json).Statement : statement if statement.Sid == "WriteEnvironmentState"]) == 0,
      length([for statement in jsondecode(data.aws_iam_policy_document.state["dev_apply"].json).Statement : statement if statement.Sid == "WriteEnvironmentState"]) == 1,
      length([for statement in jsondecode(data.aws_iam_policy_document.state["prod_apply"].json).Statement : statement if statement.Sid == "WriteEnvironmentState"]) == 1,
    ])
    error_message = "Plan debe leer state sin escribirlo; solo apply puede actualizar su state."
  }

  assert {
    condition = alltrue([
      strcontains(data.aws_iam_policy_document.state["dev_plan"].json, "vetsoftware/dev/terraform.tfstate"),
      !strcontains(data.aws_iam_policy_document.state["dev_plan"].json, "vetsoftware/prod/terraform.tfstate"),
      strcontains(data.aws_iam_policy_document.state["prod_plan"].json, "vetsoftware/prod/terraform.tfstate"),
      !strcontains(data.aws_iam_policy_document.state["prod_plan"].json, "vetsoftware/dev/terraform.tfstate"),
    ])
    error_message = "Cada rol debe quedar limitado a la key y lockfile de su entorno."
  }

  assert {
    condition = alltrue([
      toset(keys(aws_iam_role_policy.apply_regional)) == toset(["dev_apply", "prod_apply"]),
      toset(keys(aws_iam_role_policy.apply_identity)) == toset(["dev_apply", "prod_apply"]),
      toset(keys(aws_iam_role_policy.apply_storage)) == toset(["dev_apply", "prod_apply"]),
      toset(keys(aws_iam_role_policy.apply_global)) == toset(["dev_apply", "prod_apply"]),
    ])
    error_message = "Los roles plan no deben recibir ninguna política de mutación."
  }

  assert {
    condition = alltrue([
      !strcontains(data.aws_iam_policy_document.apply_identity["dev_apply"].json, "secretsmanager:GetSecretValue"),
      !strcontains(data.aws_iam_policy_document.apply_identity["prod_apply"].json, "secretsmanager:GetSecretValue"),
      strcontains(data.aws_iam_policy_document.apply_identity["dev_apply"].json, "secret:vetsoftware-dev*"),
      strcontains(data.aws_iam_policy_document.apply_identity["prod_apply"].json, "secret:vetsoftware-prod*"),
    ])
    error_message = "Apply administra secretos por entorno, pero nunca puede leer sus valores."
  }

  assert {
    condition = alltrue([
      strcontains(data.aws_iam_policy_document.infrastructure_read["dev_plan"].json, "secret:vetsoftware-dev*"),
      !strcontains(data.aws_iam_policy_document.infrastructure_read["dev_plan"].json, "secret:vetsoftware-prod*"),
      strcontains(data.aws_iam_policy_document.infrastructure_read["prod_plan"].json, "arn:aws:s3:::vetsoftware-prod-*"),
      !strcontains(data.aws_iam_policy_document.infrastructure_read["prod_plan"].json, "arn:aws:s3:::vetsoftware-dev-*"),
    ])
    error_message = "Las lecturas de secretos y buckets deben conservar el límite de su entorno."
  }

  assert {
    condition = alltrue([
      strcontains(data.aws_iam_policy_document.infrastructure_read["dev_plan"].json, "ecr:DescribeImages"),
      strcontains(data.aws_iam_policy_document.infrastructure_read["prod_apply"].json, "ecr:DescribeImageScanFindings"),
      strcontains(data.aws_iam_policy_document.infrastructure_read["dev_plan"].json, "arn:aws:ecr:us-east-1:123456789012:repository/vetsoftware-backend"),
      !strcontains(data.aws_iam_policy_document.infrastructure_read["dev_plan"].json, "repository/*"),
    ])
    error_message = "Plan y apply deben certificar únicamente la imagen ECR del backend."
  }

  assert {
    condition = alltrue(concat(
      [for policy in data.aws_iam_policy_document.infrastructure_read : length(policy.json) <= 10240],
      [for policy in data.aws_iam_policy_document.state : length(policy.json) <= 10240],
      [for policy in data.aws_iam_policy_document.apply_regional : length(policy.json) <= 10240],
      [for policy in data.aws_iam_policy_document.apply_identity : length(policy.json) <= 10240],
      [for policy in data.aws_iam_policy_document.apply_storage : length(policy.json) <= 10240],
      [for policy in data.aws_iam_policy_document.apply_global : length(policy.json) <= 10240],
    ))
    error_message = "Cada política inline debe respetar el máximo de 10.240 caracteres de IAM."
  }

  # IAM limita el AGREGADO de politicas inline de un rol a 10.240 caracteres, no
  # cada politica por separado: partir el permiso en otra inline no gana espacio.
  # Los roles apply llegaron a ~9.560 y el margen dejo de ser holgado. El guard
  # sube de 9.500 a 9.700 -queda 5% bajo el limite duro- porque la alternativa
  # era ensanchar comodines para ahorrar caracteres, que abarata el numero a
  # costa del privilegio minimo.
  #
  # Ese techo mando hasta que la linea base de trazabilidad pidio sus permisos y
  # dejo de caber, que es justo el escenario que este comentario anticipaba. Las
  # lecturas -identicas en los cuatro roles- pasaron a una politica administrada,
  # que tiene su propio limite y no cuenta contra el agregado inline. El guard
  # vuelve a tener margen de sobra sin haber ensanchado un solo comodin.
  assert {
    condition     = alltrue([for count in values(output.inline_policy_character_counts) : count <= 9700])
    error_message = format("Las políticas inline deben conservar margen bajo el límite IAM de 10.240 caracteres; conteos=%s.", jsonencode(output.inline_policy_character_counts))
  }

  # La administrada tiene un techo mas bajo -6.144- y ahi vive el bloque de
  # lecturas, que es el que mas crece: cada servicio nuevo suma sus Describe.
  assert {
    condition     = alltrue([for count in values(output.managed_policy_character_counts) : count <= 5800])
    error_message = format("Las políticas administradas deben conservar margen bajo el límite IAM de 6.144 caracteres; conteos=%s.", jsonencode(output.managed_policy_character_counts))
  }

  # Las lecturas dejan de ser inline: si alguien las devuelve a PutRolePolicy, el
  # agregado vuelve a apretar y el proximo permiso no cabra otra vez.
  assert {
    condition = (
      length(aws_iam_policy.infrastructure_read) == 4 &&
      length(aws_iam_role_policy_attachment.infrastructure_read) == 4
    )
    error_message = "Las lecturas de infraestructura deben vivir en una política administrada adjunta, no en una inline."
  }

  assert {
    condition = alltrue([
      !strcontains(data.aws_iam_policy_document.infrastructure_read["dev_plan"].json, "elasticloadbalancing:"),
      !strcontains(data.aws_iam_policy_document.infrastructure_read["prod_plan"].json, "elasticloadbalancing:"),
      !strcontains(data.aws_iam_policy_document.apply_regional["dev_apply"].json, "elasticloadbalancing:"),
      !strcontains(data.aws_iam_policy_document.apply_regional["prod_apply"].json, "elasticloadbalancing:"),
      strcontains(data.aws_iam_policy_document.apply_regional["dev_apply"].json, "logs:*MetricFilter"),
      strcontains(data.aws_iam_policy_document.apply_regional["prod_apply"].json, "logs:*MetricFilter"),
    ])
    error_message = "Los roles IaC no deben conservar permisos ELB y sí deben administrar métricas de errores del túnel."
  }

  # PutMetricAlarm no crea alarmas compuestas y sin events: no hay reglas que
  # traduzcan un evento de ECS o RDS en un aviso. Faltando cualquiera de las dos,
  # el apply del modulo de monitoreo muere con AccessDenied a mitad de camino.
  assert {
    condition = alltrue([
      strcontains(data.aws_iam_policy_document.apply_regional["dev_apply"].json, "cloudwatch:PutCompositeAlarm"),
      strcontains(data.aws_iam_policy_document.apply_regional["dev_apply"].json, "events:*Rule"),
      strcontains(data.aws_iam_policy_document.apply_regional["dev_apply"].json, "events:*Targets"),
      strcontains(data.aws_iam_policy_document.apply_regional["prod_apply"].json, "events:*Rule"),
      strcontains(data.aws_iam_policy_document.infrastructure_read["dev_plan"].json, "events:Describe*"),
    ])
    error_message = "Apply debe poder administrar reglas de EventBridge y alarmas compuestas, y plan debe poder leerlas."
  }

  # El plan no puede tocar EventBridge: leer la deriva es su trabajo, crearla no.
  assert {
    condition = alltrue([
      !strcontains(data.aws_iam_policy_document.infrastructure_read["dev_plan"].json, "events:*Rule"),
      !strcontains(data.aws_iam_policy_document.infrastructure_read["prod_plan"].json, "events:*Targets"),
    ])
    error_message = "El rol de plan solo puede leer EventBridge, nunca modificarlo."
  }

  assert {
    condition = alltrue([
      strcontains(data.aws_iam_policy_document.infrastructure_read["dev_plan"].json, "ce:GetAnomaly*"),
      # El informe diario de costos corre con el rol de plan: leer el gasto no
      # puede exigir el rol que aplica infraestructura.
      strcontains(data.aws_iam_policy_document.infrastructure_read["dev_plan"].json, "ce:GetCostAndUsage"),
      strcontains(data.aws_iam_policy_document.infrastructure_read["dev_plan"].json, "chatbot:DescribeSlackChannelConfigurations"),
      strcontains(data.aws_iam_policy_document.apply_global["dev_apply"].json, "ce:CreateAnomalyMonitor"),
      strcontains(data.aws_iam_policy_document.apply_global["dev_apply"].json, "chatbot:CreateSlackChannelConfiguration"),
      strcontains(data.aws_iam_policy_document.apply_identity["dev_apply"].json, "chatbot.amazonaws.com"),
      strcontains(data.aws_iam_policy_document.apply_identity["dev_apply"].json, "management.chatbot.amazonaws.com"),
    ])
    error_message = "Plan y apply deben poder leer y administrar Cost Anomaly Detection y el canal Slack sin ampliar prod desde dev."
  }

  assert {
    condition = alltrue([
      !strcontains(data.aws_iam_policy_document.apply_identity["dev_apply"].json, "secret:vetsoftware-dev/*"),
      !strcontains(data.aws_iam_policy_document.infrastructure_read["dev_plan"].json, "secret:vetsoftware-dev/*"),
      !strcontains(data.aws_iam_policy_document.apply_identity["dev_apply"].json, "secret:vetsoftware-prod*"),
    ])
    error_message = "El prefijo de secretos no debe llevar separador: vetsoftware-dev-valkey/connection queda fuera de secret:vetsoftware-dev/*."
  }

  assert {
    condition = alltrue([
      strcontains(data.aws_iam_policy_document.apply_identity["dev_apply"].json, "secret:rds!*"),
      strcontains(data.aws_iam_policy_document.apply_identity["prod_apply"].json, "secret:rds!*"),
      length([
        for statement in jsondecode(data.aws_iam_policy_document.apply_identity["dev_apply"].json).Statement :
        statement if statement.Sid == "CreateRdsManagedMasterSecret"
      ]) == 1,
    ])
    error_message = "Apply debe poder crear y etiquetar el secreto que RDS genera para el master user."
  }
}

# REGISTRO DE PERMISOS POR MODULO. Un modulo nuevo puede introducir tipos de
# recurso que estos roles no saben crear, y nada lo detecta antes de tiempo: el
# plan no comprueba permisos y el gate no ejecuta apply. El AccessDenied aparece
# a mitad del apply, con parte de la infraestructura ya creada.
#
# Paso cuatro veces el 9 de agosto de 2026. Tres con account_baseline
# -PutBucketLogging, CreateTrail, el TagResource del analizador- y una con
# cost_report, que fallo en lambda:CreateFunction.
#
# Al anadir un modulo con un tipo de recurso nuevo, se anade aqui lo que necesita.
# Vale la pena mirar tres cosas que no son obvias leyendo el modulo:
#
#   - Que identidad USA el recurso, no solo cual lo crea. CloudTrail pide su data
#     key con la suya, y el permiso que faltaba era el de la key policy.
#   - Los permisos que se piden de rebote: etiquetar al crear, pasar un rol de
#     ejecucion, crear un rol vinculado de servicio.
#   - Las lecturas, o el plan y el drift fallaran sobre algo que el apply si pudo
#     crear.
run "apply_puede_crear_los_recursos_de_los_modulos" {
  command = plan

  assert {
    condition = alltrue([
      for accion in [
        "cloudtrail:CreateTrail",
        "cloudtrail:StartLogging",
        "cloudtrail:PutEventSelectors",
        "cloudtrail:AddTags",
        "access-analyzer:CreateAnalyzer",
        # El analizador se etiqueta al crearlo: sin TagResource la creacion falla
        # entera aunque CreateAnalyzer este concedido.
        "access-analyzer:TagResource",
        ] : alltrue([
          for key in ["dev_apply", "prod_apply"] :
          strcontains(data.aws_iam_policy_document.apply_regional[key].json, accion)
      ])
    ])
    error_message = "El rol de apply debe poder crear el trail y el analizador de la cuenta; sin esto el apply muere a mitad, con recursos ya creados."
  }

  # El analizador necesita su rol vinculado la primera vez que se crea uno en la
  # cuenta. Sin esto CreateAnalyzer falla por iam:CreateServiceLinkedRole y no
  # por un permiso de access-analyzer, que es lo que despista al leer el error.
  assert {
    condition = alltrue([
      for key in ["dev_apply", "prod_apply"] :
      strcontains(data.aws_iam_policy_document.apply_identity[key].json, "access-analyzer.amazonaws.com")
    ])
    error_message = "El rol de apply debe poder crear el rol vinculado del Access Analyzer; sin el, CreateAnalyzer falla."
  }

  # El access logging es la via gratuita para reconstruir quien accedio a un
  # documento con datos personales, y se configura sobre un bucket que ya existe.
  assert {
    condition = alltrue([
      for key in ["dev_apply", "prod_apply"] :
      strcontains(data.aws_iam_policy_document.apply_storage[key].json, "s3:PutBucketLogging")
    ])
    error_message = "El rol de apply debe poder activar el server access logging de los buckets del ambiente."
  }

  # cost_report: la Lambda del informe diario.
  assert {
    condition = alltrue([
      for accion in ["lambda:CreateFunction", "lambda:UpdateFunctionCode", "lambda:TagResource"] :
      alltrue([
        for key in ["dev_apply", "prod_apply"] :
        strcontains(data.aws_iam_policy_document.apply_regional[key].json, accion)
      ])
    ])
    error_message = "El rol de apply debe poder crear y actualizar la funcion del informe de costos."
  }

  # Crear una Lambda es pasarle su rol de ejecucion: sin PassRole hacia
  # lambda.amazonaws.com, CreateFunction falla por IAM y no por un permiso de
  # Lambda, que es lo que despista al leer el error.
  assert {
    condition = alltrue([
      for key in ["dev_apply", "prod_apply"] :
      strcontains(data.aws_iam_policy_document.apply_identity[key].json, "lambda.amazonaws.com")
    ])
    error_message = "El rol de apply debe poder pasar el rol de ejecucion a Lambda."
  }

  # Plan y drift refrescan estos recursos en cada corrida. Sin lectura, el ciclo
  # diario falla sobre algo que el apply si pudo crear, que es la unica variante
  # peor que no poder crearlo.
  assert {
    condition = alltrue([
      for accion in [
        "cloudtrail:DescribeTrails",
        "cloudtrail:GetTrailStatus",
        "cloudtrail:GetEventSelectors",
        "access-analyzer:ListAnalyzers",
        "lambda:Get*",
        ] : alltrue([
          for key in ["dev_plan", "dev_apply", "prod_plan", "prod_apply"] :
          strcontains(data.aws_iam_policy_document.infrastructure_read[key].json, accion)
      ])
    ])
    error_message = "Los dos roles deben poder LEER el trail, el analizador y la funcion; si no, el plan y el drift fallan al refrescarlos."
  }
}
