locals {
  role_definitions = merge([
    for environment, config in var.environments : {
      "${environment}_plan" = {
        environment        = environment
        function           = "plan"
        github_environment = config.github_plan_environment
        state_key          = config.state_key
        managed_bucket_arns = concat(
          ["arn:${var.aws_partition}:s3:::${var.project_name}-${environment}-*"],
          tolist(config.additional_s3_bucket_arns),
        )
      }
      "${environment}_apply" = {
        environment        = environment
        function           = "apply"
        github_environment = config.github_apply_environment
        state_key          = config.state_key
        managed_bucket_arns = concat(
          ["arn:${var.aws_partition}:s3:::${var.project_name}-${environment}-*"],
          tolist(config.additional_s3_bucket_arns),
        )
      }
    }
  ]...)

  apply_role_definitions = {
    for key, role in local.role_definitions : key => role if role.function == "apply"
  }

  global_infrastructure_read_actions = [
    "application-autoscaling:Describe*",
    # Describe* no la cubre: el proveedor lee las etiquetas del scalable target al
    # refrescarlo, y sin este permiso el apply falla despues de haberlo creado.
    "application-autoscaling:ListTagsForResource",
    "budgets:Describe*",
    "budgets:ListTagsForResource",
    "budgets:ViewBudget",
    "ce:GetAnomaly*",
    # La usa el informe diario de costos, no Terraform. Cost Explorer cobra USD 0.01
    # por request, asi que el permiso habilita un gasto: una consulta al dia son
    # ~USD 0.30 al mes. Es de solo lectura y va en el rol de plan a proposito.
    "ce:GetCostAndUsage",
    "ce:ListTagsForResource",
    "chatbot:DescribeSlackChannelConfigurations",
    "chatbot:ListTagsForResource",
    "cloudwatch:Describe*",
    "cloudwatch:GetMetricData",
    "cloudwatch:ListTagsForResource",
    "ec2:Describe*",
    "ecs:Describe*",
    "ecs:List*",
    "elasticache:Describe*",
    "elasticache:ListTagsForResource",
    "logs:Describe*",
    "kms:DescribeKey",
    "kms:GetKeyPolicy",
    "kms:GetKeyRotationStatus",
    "kms:ListAliases",
    "kms:ListResourceTags",
    "rds:Describe*",
    "rds:ListTagsForResource",
    "route53:Get*",
    "route53:List*",
    "sts:GetCallerIdentity",
  ]

  iam_read_actions = [
    "iam:GetInstanceProfile",
    "iam:GetRole*",
    "iam:ListAttachedRolePolicies",
    "iam:ListInstanceProfile*",
    "iam:ListRole*",
  ]

  s3_read_actions = [
    "s3:GetAccelerateConfiguration",
    "s3:GetBucket*",
    "s3:GetEncryptionConfiguration",
    "s3:GetLifecycleConfiguration",
    "s3:GetReplicationConfiguration",
    "s3:ListBucket",
  ]

  regional_apply_actions = [
    "application-autoscaling:*ScalableTarget",
    "application-autoscaling:*ScalingPolicy",
    "application-autoscaling:TagResource",
    "application-autoscaling:UntagResource",
    "cloudwatch:DeleteAlarms",
    "cloudwatch:PutMetricAlarm",
    "cloudwatch:TagResource",
    "cloudwatch:UntagResource",
    "ec2:*FlowLogs",
    "ec2:*IamInstanceProfile*",
    "ec2:*Instances",
    "ec2:*InternetGateway",
    "ec2:*Route",
    "ec2:*RouteTable",
    "ec2:*SecurityGroup",
    "ec2:*SecurityGroupEgress",
    "ec2:*SecurityGroupIngress",
    "ec2:*Subnet",
    "ec2:*Tags",
    "ec2:*Volume",
    "ec2:*Vpc",
    "ec2:AssociateRouteTable",
    "ec2:CreateVpcEndpoint",
    "ec2:DeleteVpcEndpoints",
    "ec2:DisassociateRouteTable",
    "ec2:ModifyInstanceAttribute",
    "ec2:ModifySecurityGroupRules",
    "ec2:ModifySubnetAttribute",
    "ec2:ModifyVpcAttribute",
    "ec2:ModifyVpcEndpoint",
    "ec2:ReplaceRouteTableAssociation",
    "ecs:*Cluster",
    "ecs:*Service",
    "ecs:*TaskDefinition",
    "ecs:PutClusterCapacityProviders",
    "ecs:TagResource",
    "ecs:UntagResource",
    "ecs:UpdateClusterSettings",
    "elasticache:AddTagsToResource",
    "elasticache:*ServerlessCache",
    "elasticache:*User",
    "elasticache:*UserGroup",
    "elasticache:RemoveTagsFromResource",
    "firehose:*DeliveryStream",
    "firehose:*DeliveryStreamEncryption",
    "firehose:TagDeliveryStream",
    "firehose:UntagDeliveryStream",
    "firehose:UpdateDestination",
    "logs:*KmsKey",
    "logs:*LogGroup",
    "logs:*LogStream",
    "logs:*MetricFilter",
    "logs:PutLogGroupDeletionProtection",
    "logs:PutResourcePolicy",
    "logs:PutRetentionPolicy",
    "logs:TagResource",
    "logs:UntagResource",
    "kms:*Alias",
    "kms:CreateKey",
    "kms:DisableKey",
    "kms:EnableKey",
    "kms:EnableKeyRotation",
    "kms:PutKeyPolicy",
    "kms:ScheduleKeyDeletion",
    "kms:TagResource",
    "kms:UntagResource",
    "kms:UpdateKeyDescription",
    "rds:AddTagsToResource",
    "rds:*DBInstance",
    "rds:*DBParameterGroup",
    "rds:*DBSubnetGroup",
    "rds:RemoveTagsFromResource",
    "scheduler:*Schedule",
    "scheduler:TagResource",
    "scheduler:UntagResource",
    "sns:*Subscription*",
    "sns:*Topic",
    "sns:SetTopicAttributes",
    "sns:Subscribe",
    "sns:TagResource",
    "sns:Unsubscribe",
    "sns:UntagResource",
  ]
}

data "aws_iam_policy_document" "assume" {
  for_each = local.role_definitions

  statement {
    sid     = "GitHubEnvironment"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.github_oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_organization}@${var.github_organization_id}/${var.github_repository}@${var.github_repository_id}:environment:${each.value.github_environment}"]
    }
  }
}

resource "aws_iam_role" "this" {
  for_each = local.role_definitions

  name                 = "${var.project_name}-iac-${each.value.function}-${each.value.environment}"
  description          = "GitHub OIDC ${each.value.function} role for ${var.project_name} ${each.value.environment}"
  assume_role_policy   = data.aws_iam_policy_document.assume[each.key].json
  max_session_duration = 3600

  tags = merge(var.tags, {
    Component         = "github-iac"
    Environment       = each.value.environment
    Function          = each.value.function
    GitHubEnvironment = each.value.github_environment
    GitHubRepository  = var.github_repository
  })
}

data "aws_iam_policy_document" "state" {
  for_each = local.role_definitions

  statement {
    sid       = "InspectStateBucket"
    effect    = "Allow"
    actions   = ["s3:GetBucketLocation", "s3:ListBucket"]
    resources = ["arn:${var.aws_partition}:s3:::${var.state_bucket_name}"]

    condition {
      test     = "StringEquals"
      variable = "s3:prefix"
      values   = [each.value.state_key, "${each.value.state_key}.tflock"]
    }
  }

  statement {
    sid       = "ReadEnvironmentState"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["arn:${var.aws_partition}:s3:::${var.state_bucket_name}/${each.value.state_key}"]
  }

  dynamic "statement" {
    for_each = each.value.function == "apply" ? [1] : []

    content {
      sid       = "WriteEnvironmentState"
      effect    = "Allow"
      actions   = ["s3:PutObject"]
      resources = ["arn:${var.aws_partition}:s3:::${var.state_bucket_name}/${each.value.state_key}"]
    }
  }

  statement {
    sid    = "ManageEnvironmentStateLock"
    effect = "Allow"
    actions = [
      "s3:DeleteObject",
      "s3:GetObject",
      "s3:PutObject",
    ]
    resources = ["arn:${var.aws_partition}:s3:::${var.state_bucket_name}/${each.value.state_key}.tflock"]
  }

  dynamic "statement" {
    for_each = var.state_kms_key_arn == null ? [] : [1]

    content {
      sid    = "UseStateEncryptionKey"
      effect = "Allow"
      actions = [
        "kms:Decrypt",
        "kms:DescribeKey",
        "kms:Encrypt",
        "kms:GenerateDataKey",
      ]
      resources = [var.state_kms_key_arn]
    }
  }
}

resource "aws_iam_role_policy" "state" {
  for_each = local.role_definitions

  name   = "terraform-${each.value.environment}-state-${each.value.function}"
  role   = aws_iam_role.this[each.key].id
  policy = data.aws_iam_policy_document.state[each.key].json
}

data "aws_iam_policy_document" "infrastructure_read" {
  for_each = local.role_definitions

  statement {
    sid       = "DiscoverRegionalAndSharedInfrastructure"
    effect    = "Allow"
    actions   = local.global_infrastructure_read_actions
    resources = ["*"]
  }

  statement {
    sid    = "CertifyBackendReleaseImage"
    effect = "Allow"
    actions = [
      "ecr:BatchGetImage",
      "ecr:DescribeImages",
      "ecr:DescribeImageScanFindings",
      # Lee el blob de configuracion de la imagen para recuperar sus labels OCI
      # -commit completo y URL del run que la publico- sin pedirselos a quien
      # despliega. Es solo lectura y esta acotado al repositorio del backend.
      "ecr:GetDownloadUrlForLayer",
      # Dispara un escaneo cuando la imagen no tiene ninguno: el caso de una
      # imagen publicada antes de que el registro tuviera SCAN_ON_PUSH. No
      # modifica la imagen ni la infraestructura, y esta acotado al mismo
      # repositorio.
      "ecr:StartImageScan",
    ]
    resources = [
      "arn:${var.aws_partition}:ecr:${var.aws_region}:${var.aws_account_id}:repository/${var.backend_repository_name}"
    ]
  }

  statement {
    sid     = "ReadEnvironmentRuntimeRoles"
    effect  = "Allow"
    actions = local.iam_read_actions
    resources = [
      "arn:${var.aws_partition}:iam::${var.aws_account_id}:instance-profile/${var.project_name}-${each.value.environment}-*",
      "arn:${var.aws_partition}:iam::${var.aws_account_id}:role/${var.project_name}-${each.value.environment}-*",
    ]
  }

  statement {
    sid    = "ReadEnvironmentSecretsMetadata"
    effect = "Allow"
    actions = [
      "secretsmanager:DescribeSecret",
      "secretsmanager:GetResourcePolicy",
      "secretsmanager:ListSecretVersionIds",
    ]
    # El prefijo va sin separador: cubre tanto vetsoftware-<env>/application como
    # los secretos por recurso, p. ej. vetsoftware-<env>-valkey/connection.
    resources = [
      "arn:${var.aws_partition}:secretsmanager:${var.aws_region}:${var.aws_account_id}:secret:${var.project_name}-${each.value.environment}*"
    ]
  }

  statement {
    sid       = "ReadEnvironmentBuckets"
    effect    = "Allow"
    actions   = local.s3_read_actions
    resources = each.value.managed_bucket_arns
  }

  statement {
    sid    = "ReadEnvironmentNamedResources"
    effect = "Allow"
    actions = [
      "firehose:DescribeDeliveryStream",
      "firehose:ListTagsForDeliveryStream",
      "logs:ListTagsForResource",
      "scheduler:GetSchedule",
      "scheduler:ListTagsForResource",
      "sns:GetSubscriptionAttributes",
      "sns:GetTopicAttributes",
      "sns:ListSubscriptionsByTopic",
      "sns:ListTagsForResource",
    ]
    resources = [
      "arn:${var.aws_partition}:firehose:${var.aws_region}:${var.aws_account_id}:deliverystream/${var.project_name}-${each.value.environment}-*",
      "arn:${var.aws_partition}:logs:${var.aws_region}:${var.aws_account_id}:log-group:/${var.project_name}-${each.value.environment}/*",
      "arn:${var.aws_partition}:logs:${var.aws_region}:${var.aws_account_id}:log-group:/aws/*/${var.project_name}-${each.value.environment}*",
      "arn:${var.aws_partition}:logs:${var.aws_region}:${var.aws_account_id}:log-group:/ecs/${var.project_name}-${each.value.environment}-*",
      "arn:${var.aws_partition}:scheduler:${var.aws_region}:${var.aws_account_id}:schedule/default/${var.project_name}-${each.value.environment}-*",
      "arn:${var.aws_partition}:sns:${var.aws_region}:${var.aws_account_id}:${var.project_name}-${each.value.environment}-*",
    ]
  }

  statement {
    sid     = "ReadPublicAmazonLinuxAmiParameter"
    effect  = "Allow"
    actions = ["ssm:GetParameter"]
    resources = [
      "arn:${var.aws_partition}:ssm:${var.aws_region}::parameter/aws/service/ami-amazon-linux-latest/*"
    ]
  }
}

resource "aws_iam_role_policy" "infrastructure_read" {
  for_each = local.role_definitions

  name   = "terraform-infrastructure-read"
  role   = aws_iam_role.this[each.key].id
  policy = data.aws_iam_policy_document.infrastructure_read[each.key].json

  depends_on = [aws_iam_role_policy.apply_regional]
}

data "aws_iam_policy_document" "apply_regional" {
  for_each = local.apply_role_definitions

  statement {
    sid       = "ManageRegionalInfrastructure"
    effect    = "Allow"
    actions   = local.regional_apply_actions
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.aws_region]
    }
  }
}

resource "aws_iam_role_policy" "apply_regional" {
  for_each = data.aws_iam_policy_document.apply_regional

  name   = "terraform-${local.role_definitions[each.key].environment}-apply-regional"
  role   = aws_iam_role.this[each.key].id
  policy = each.value.json
}

data "aws_iam_policy_document" "apply_identity" {
  for_each = local.apply_role_definitions

  statement {
    sid    = "ManageEnvironmentRuntimeRoles"
    effect = "Allow"
    actions = [
      "iam:AddRoleToInstanceProfile",
      "iam:AttachRolePolicy",
      "iam:CreateInstanceProfile",
      "iam:CreateRole",
      "iam:DeleteInstanceProfile",
      "iam:DeleteRole",
      "iam:DeleteRolePolicy",
      "iam:DetachRolePolicy",
      "iam:PutRolePolicy",
      "iam:RemoveRoleFromInstanceProfile",
      "iam:TagInstanceProfile",
      "iam:TagRole",
      "iam:UntagInstanceProfile",
      "iam:UntagRole",
      "iam:UpdateAssumeRolePolicy",
      "iam:UpdateRoleDescription",
    ]
    resources = [
      "arn:${var.aws_partition}:iam::${var.aws_account_id}:instance-profile/${var.project_name}-${each.value.environment}-*",
      "arn:${var.aws_partition}:iam::${var.aws_account_id}:role/${var.project_name}-${each.value.environment}-*",
    ]
  }

  statement {
    sid       = "CreateRequiredServiceLinkedRoles"
    effect    = "Allow"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["arn:${var.aws_partition}:iam::${var.aws_account_id}:role/aws-service-role/*"]

    condition {
      test     = "StringEquals"
      variable = "iam:AWSServiceName"
      values = [
        "ecs.amazonaws.com",
        "ecs.application-autoscaling.amazonaws.com",
        "elasticache.amazonaws.com",
        "management.chatbot.amazonaws.com",
        "rds.amazonaws.com",
      ]
    }
  }

  statement {
    sid     = "PassEnvironmentRuntimeRoles"
    effect  = "Allow"
    actions = ["iam:PassRole"]
    resources = [
      "arn:${var.aws_partition}:iam::${var.aws_account_id}:role/${var.project_name}-${each.value.environment}-*"
    ]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values = [
        "ec2.amazonaws.com",
        "ecs-tasks.amazonaws.com",
        "firehose.amazonaws.com",
        "chatbot.amazonaws.com",
        "scheduler.amazonaws.com",
        "vpc-flow-logs.amazonaws.com",
      ]
    }
  }

  statement {
    sid    = "ManageEnvironmentSecretsWithoutReadingValues"
    effect = "Allow"
    actions = [
      "secretsmanager:CreateSecret",
      "secretsmanager:DeleteSecret",
      "secretsmanager:PutSecretValue",
      "secretsmanager:RestoreSecret",
      "secretsmanager:TagResource",
      "secretsmanager:UntagResource",
      "secretsmanager:UpdateSecret",
      "secretsmanager:UpdateSecretVersionStage",
    ]
    # El prefijo va sin separador: cubre tanto vetsoftware-<env>/application como
    # los secretos por recurso, p. ej. vetsoftware-<env>-valkey/connection.
    resources = [
      "arn:${var.aws_partition}:secretsmanager:${var.aws_region}:${var.aws_account_id}:secret:${var.project_name}-${each.value.environment}*"
    ]
  }

  # RDS genera el secreto del master user con nombre propio (rds!db-<uuid>) cuando
  # manage_master_user_password esta activo, y exige que el llamador pueda crearlo y etiquetarlo.
  statement {
    sid    = "CreateRdsManagedMasterSecret"
    effect = "Allow"
    actions = [
      "secretsmanager:CreateSecret",
      "secretsmanager:TagResource",
    ]
    resources = [
      "arn:${var.aws_partition}:secretsmanager:${var.aws_region}:${var.aws_account_id}:secret:rds!*"
    ]
  }
}

resource "aws_iam_role_policy" "apply_identity" {
  for_each = data.aws_iam_policy_document.apply_identity

  name   = "terraform-${local.role_definitions[each.key].environment}-apply-identity"
  role   = aws_iam_role.this[each.key].id
  policy = each.value.json

  depends_on = [aws_iam_role_policy.apply_regional]
}

data "aws_iam_policy_document" "apply_storage" {
  for_each = local.apply_role_definitions

  statement {
    sid    = "ManageEnvironmentBuckets"
    effect = "Allow"
    actions = [
      "s3:CreateBucket",
      "s3:DeleteBucket",
      "s3:DeleteBucketPolicy",
      "s3:PutLifecycleConfiguration",
      "s3:PutBucketObjectLockConfiguration",
      "s3:PutBucketOwnershipControls",
      "s3:PutBucketPolicy",
      "s3:PutBucketPublicAccessBlock",
      "s3:PutBucketTagging",
      "s3:PutBucketVersioning",
      "s3:PutEncryptionConfiguration",
    ]
    resources = each.value.managed_bucket_arns
  }

  # El Deny apunta solo al ARN del bucket, asi que cubre toda la administracion a nivel
  # de bucket sin tocar los objetos de state, cuyo ARN incluye la key.
  statement {
    sid       = "ProtectTerraformStateBucketAdministration"
    effect    = "Deny"
    actions   = ["s3:Delete*", "s3:Put*"]
    resources = ["arn:${var.aws_partition}:s3:::${var.state_bucket_name}"]
  }
}

resource "aws_iam_role_policy" "apply_storage" {
  for_each = data.aws_iam_policy_document.apply_storage

  name   = "terraform-${local.role_definitions[each.key].environment}-apply-storage"
  role   = aws_iam_role.this[each.key].id
  policy = each.value.json
}

data "aws_iam_policy_document" "apply_global" {
  for_each = local.apply_role_definitions

  statement {
    sid    = "ManageGlobalDnsCostAlertsAndChat"
    effect = "Allow"
    actions = [
      # default_tags del provider hace que CreateBudget etiquete el presupuesto.
      "budgets:ModifyBudget",
      "budgets:TagResource",
      "budgets:UntagResource",
      "ce:CreateAnomalyMonitor",
      "ce:CreateAnomalySubscription",
      "ce:DeleteAnomalyMonitor",
      "ce:DeleteAnomalySubscription",
      "ce:TagResource",
      "ce:UntagResource",
      "ce:UpdateAnomalyMonitor",
      "ce:UpdateAnomalySubscription",
      "chatbot:CreateSlackChannelConfiguration",
      "chatbot:DeleteSlackChannelConfiguration",
      "chatbot:TagResource",
      "chatbot:UntagResource",
      "chatbot:UpdateSlackChannelConfiguration",
      "route53:AssociateVPCWithHostedZone",
      "route53:ChangeResourceRecordSets",
      "route53:ChangeTagsForResource",
      "route53:CreateHostedZone",
      "route53:DeleteHostedZone",
      "route53:DisassociateVPCFromHostedZone",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "apply_global" {
  for_each = data.aws_iam_policy_document.apply_global

  name   = "terraform-${local.role_definitions[each.key].environment}-apply-global"
  role   = aws_iam_role.this[each.key].id
  policy = each.value.json

  depends_on = [aws_iam_role_policy.apply_regional]
}
