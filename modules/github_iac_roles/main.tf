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
    "application-autoscaling:DescribeScalableTargets",
    "application-autoscaling:DescribeScalingActivities",
    "application-autoscaling:DescribeScalingPolicies",
    "application-autoscaling:DescribeScheduledActions",
    "budgets:DescribeBudgetActionsForBudget",
    "budgets:ViewBudget",
    "cloudwatch:DescribeAlarms",
    "cloudwatch:GetMetricData",
    "cloudwatch:ListTagsForResource",
    "ec2:Describe*",
    "ecs:Describe*",
    "ecs:List*",
    "elasticache:Describe*",
    "elasticache:ListTagsForResource",
    "logs:DescribeLogGroups",
    "logs:DescribeMetricFilters",
    "logs:DescribeResourcePolicies",
    "kms:DescribeKey",
    "kms:GetKeyPolicy",
    "kms:GetKeyRotationStatus",
    "kms:ListAliases",
    "kms:ListResourceTags",
    "rds:Describe*",
    "rds:ListTagsForResource",
    "route53:GetChange",
    "route53:GetHostedZone",
    "route53:ListHostedZones",
    "route53:ListHostedZonesByName",
    "route53:ListResourceRecordSets",
    "route53:ListTagsForResource",
    "sts:GetCallerIdentity",
  ]

  iam_read_actions = [
    "iam:GetInstanceProfile",
    "iam:GetRole",
    "iam:GetRolePolicy",
    "iam:ListAttachedRolePolicies",
    "iam:ListInstanceProfileTags",
    "iam:ListInstanceProfilesForRole",
    "iam:ListRolePolicies",
    "iam:ListRoleTags",
  ]

  s3_read_actions = [
    "s3:GetAccelerateConfiguration",
    "s3:GetBucketAcl",
    "s3:GetBucketCORS",
    "s3:GetBucketLocation",
    "s3:GetBucketLogging",
    "s3:GetBucketObjectLockConfiguration",
    "s3:GetBucketOwnershipControls",
    "s3:GetBucketPolicy",
    "s3:GetBucketPublicAccessBlock",
    "s3:GetBucketRequestPayment",
    "s3:GetBucketTagging",
    "s3:GetBucketVersioning",
    "s3:GetBucketWebsite",
    "s3:GetEncryptionConfiguration",
    "s3:GetLifecycleConfiguration",
    "s3:GetReplicationConfiguration",
    "s3:ListBucket",
  ]

  regional_apply_actions = [
    "application-autoscaling:DeleteScalingPolicy",
    "application-autoscaling:DeregisterScalableTarget",
    "application-autoscaling:PutScalingPolicy",
    "application-autoscaling:RegisterScalableTarget",
    "application-autoscaling:TagResource",
    "application-autoscaling:UntagResource",
    "cloudwatch:DeleteAlarms",
    "cloudwatch:PutMetricAlarm",
    "cloudwatch:TagResource",
    "cloudwatch:UntagResource",
    "ec2:AssociateRouteTable",
    "ec2:AssociateIamInstanceProfile",
    "ec2:AttachInternetGateway",
    "ec2:AttachVolume",
    "ec2:AuthorizeSecurityGroupEgress",
    "ec2:AuthorizeSecurityGroupIngress",
    "ec2:CreateInternetGateway",
    "ec2:CreateFlowLogs",
    "ec2:CreateRoute",
    "ec2:CreateRouteTable",
    "ec2:CreateSecurityGroup",
    "ec2:CreateSubnet",
    "ec2:CreateTags",
    "ec2:CreateVolume",
    "ec2:CreateVpc",
    "ec2:CreateVpcEndpoint",
    "ec2:DeleteInternetGateway",
    "ec2:DeleteFlowLogs",
    "ec2:DeleteRoute",
    "ec2:DeleteRouteTable",
    "ec2:DeleteSecurityGroup",
    "ec2:DeleteSubnet",
    "ec2:DeleteTags",
    "ec2:DeleteVolume",
    "ec2:DeleteVpc",
    "ec2:DeleteVpcEndpoints",
    "ec2:DetachInternetGateway",
    "ec2:DetachVolume",
    "ec2:DisassociateRouteTable",
    "ec2:ModifyInstanceAttribute",
    "ec2:ModifySecurityGroupRules",
    "ec2:ModifySubnetAttribute",
    "ec2:ModifyVpcAttribute",
    "ec2:ModifyVpcEndpoint",
    "ec2:ReplaceRoute",
    "ec2:ReplaceIamInstanceProfileAssociation",
    "ec2:ReplaceRouteTableAssociation",
    "ec2:RevokeSecurityGroupEgress",
    "ec2:RevokeSecurityGroupIngress",
    "ec2:RunInstances",
    "ec2:StartInstances",
    "ec2:StopInstances",
    "ec2:TerminateInstances",
    "ec2:DisassociateIamInstanceProfile",
    "ecs:CreateCluster",
    "ecs:CreateService",
    "ecs:DeleteCluster",
    "ecs:DeleteService",
    "ecs:DeregisterTaskDefinition",
    "ecs:PutClusterCapacityProviders",
    "ecs:RegisterTaskDefinition",
    "ecs:TagResource",
    "ecs:UntagResource",
    "ecs:UpdateCluster",
    "ecs:UpdateClusterSettings",
    "ecs:UpdateService",
    "elasticache:AddTagsToResource",
    "elasticache:CreateServerlessCache",
    "elasticache:CreateUser",
    "elasticache:CreateUserGroup",
    "elasticache:DeleteServerlessCache",
    "elasticache:DeleteUser",
    "elasticache:DeleteUserGroup",
    "elasticache:ModifyServerlessCache",
    "elasticache:ModifyUser",
    "elasticache:ModifyUserGroup",
    "elasticache:RemoveTagsFromResource",
    "firehose:CreateDeliveryStream",
    "firehose:DeleteDeliveryStream",
    "firehose:StartDeliveryStreamEncryption",
    "firehose:StopDeliveryStreamEncryption",
    "firehose:TagDeliveryStream",
    "firehose:UntagDeliveryStream",
    "firehose:UpdateDestination",
    "logs:CreateLogGroup",
    "logs:CreateLogStream",
    "logs:AssociateKmsKey",
    "logs:DeleteMetricFilter",
    "logs:DeleteLogGroup",
    "logs:DeleteLogStream",
    "logs:DisassociateKmsKey",
    "logs:PutMetricFilter",
    "logs:PutLogGroupDeletionProtection",
    "logs:PutResourcePolicy",
    "logs:PutRetentionPolicy",
    "logs:TagResource",
    "logs:UntagResource",
    "kms:CreateAlias",
    "kms:CreateKey",
    "kms:DeleteAlias",
    "kms:DisableKey",
    "kms:EnableKey",
    "kms:EnableKeyRotation",
    "kms:PutKeyPolicy",
    "kms:ScheduleKeyDeletion",
    "kms:TagResource",
    "kms:UntagResource",
    "kms:UpdateAlias",
    "kms:UpdateKeyDescription",
    "rds:AddTagsToResource",
    "rds:CreateDBInstance",
    "rds:CreateDBParameterGroup",
    "rds:CreateDBSubnetGroup",
    "rds:DeleteDBInstance",
    "rds:DeleteDBParameterGroup",
    "rds:DeleteDBSubnetGroup",
    "rds:ModifyDBInstance",
    "rds:ModifyDBParameterGroup",
    "rds:ModifyDBSubnetGroup",
    "rds:RebootDBInstance",
    "rds:RemoveTagsFromResource",
    "rds:ResetDBParameterGroup",
    "rds:StartDBInstance",
    "rds:StopDBInstance",
    "scheduler:CreateSchedule",
    "scheduler:DeleteSchedule",
    "scheduler:TagResource",
    "scheduler:UntagResource",
    "scheduler:UpdateSchedule",
    "sns:CreateTopic",
    "sns:DeleteTopic",
    "sns:SetSubscriptionAttributes",
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
      "secretsmanager:ListSecretVersionIds",
    ]
    resources = [
      "arn:${var.aws_partition}:secretsmanager:${var.aws_region}:${var.aws_account_id}:secret:${var.project_name}-${each.value.environment}/*"
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
      "arn:${var.aws_partition}:logs:${var.aws_region}:${var.aws_account_id}:log-group:/aws/firehose/${var.project_name}-${each.value.environment}-*",
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
    resources = [
      "arn:${var.aws_partition}:secretsmanager:${var.aws_region}:${var.aws_account_id}:secret:${var.project_name}-${each.value.environment}/*"
    ]
  }
}

resource "aws_iam_role_policy" "apply_identity" {
  for_each = data.aws_iam_policy_document.apply_identity

  name   = "terraform-${local.role_definitions[each.key].environment}-apply-identity"
  role   = aws_iam_role.this[each.key].id
  policy = each.value.json
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

  statement {
    sid    = "ProtectTerraformStateBucketAdministration"
    effect = "Deny"
    actions = [
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
    sid    = "ManageGlobalDnsAndBudgets"
    effect = "Allow"
    actions = [
      "budgets:ModifyBudget",
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
}
