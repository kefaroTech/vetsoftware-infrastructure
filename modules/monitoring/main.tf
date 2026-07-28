locals {
  notifications_enabled = var.alarm_email != ""
  alarm_actions         = local.notifications_enabled ? [aws_sns_topic.alarms[0].arn] : []
}

resource "aws_sns_topic" "alarms" {
  count = local.notifications_enabled ? 1 : 0

  name = "${var.name}-alarms"
  tags = var.tags
}

resource "aws_sns_topic_subscription" "email" {
  count = local.notifications_enabled ? 1 : 0

  topic_arn = aws_sns_topic.alarms[0].arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

resource "aws_cloudwatch_metric_alarm" "backend_cpu" {
  alarm_name          = "${var.name}-backend-high-cpu"
  alarm_description   = "Backend CPU above 85% for 10 minutes"
  namespace           = "AWS/ECS"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  threshold           = 85
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions

  dimensions = {
    ClusterName = var.ecs_cluster_name
    ServiceName = var.ecs_service_name
  }

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "backend_memory" {
  alarm_name          = "${var.name}-backend-high-memory"
  alarm_description   = "Backend memory above 85% for 10 minutes"
  namespace           = "AWS/ECS"
  metric_name         = "MemoryUtilization"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  threshold           = 85
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions

  dimensions = {
    ClusterName = var.ecs_cluster_name
    ServiceName = var.ecs_service_name
  }

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  alarm_name          = "${var.name}-alb-5xx"
  alarm_description   = "ALB is returning server errors"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_Target_5XX_Count"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 5
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions

  dimensions = {
    LoadBalancer = var.alb_arn_suffix
    TargetGroup  = var.target_group_arn_suffix
  }

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "alb_latency" {
  alarm_name          = "${var.name}-alb-latency"
  alarm_description   = "Target response time above two seconds"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "TargetResponseTime"
  extended_statistic  = "p95"
  period              = 300
  evaluation_periods  = 2
  threshold           = 2
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions

  dimensions = {
    LoadBalancer = var.alb_arn_suffix
    TargetGroup  = var.target_group_arn_suffix
  }

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "database_cpu" {
  alarm_name          = "${var.name}-database-high-cpu"
  alarm_description   = "RDS CPU above 80%"
  namespace           = "AWS/RDS"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions

  dimensions = {
    DBInstanceIdentifier = var.database_identifier
  }

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "database_storage" {
  alarm_name          = "${var.name}-database-low-storage"
  alarm_description   = "RDS free storage below 5 GiB"
  namespace           = "AWS/RDS"
  metric_name         = "FreeStorageSpace"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 1
  threshold           = 5368709120
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions

  dimensions = {
    DBInstanceIdentifier = var.database_identifier
  }

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "gotenberg_status" {
  for_each = { for index, instance_id in var.gotenberg_instance_ids : tostring(index) => instance_id }

  alarm_name          = "${var.name}-gotenberg-${each.value}-status"
  alarm_description   = "EC2 instance status check failed"
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = local.alarm_actions

  dimensions = { InstanceId = each.value }
  tags       = var.tags
}

resource "aws_cloudwatch_metric_alarm" "gotenberg_recovery" {
  for_each = { for index, instance_id in var.gotenberg_instance_ids : tostring(index) => instance_id }

  alarm_name          = "${var.name}-gotenberg-${each.key}-system-recovery"
  alarm_description   = "Recover the EC2 instance after an underlying system failure"
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed_System"
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "missing"
  alarm_actions = concat(local.alarm_actions, [
    "arn:aws:automate:${var.aws_region}:ec2:recover"
  ])

  dimensions = { InstanceId = each.value }
  tags       = var.tags
}

resource "aws_cloudwatch_metric_alarm" "alloy_status" {
  for_each = { for index, instance_id in var.alloy_instance_ids : tostring(index) => instance_id }

  alarm_name          = "${var.name}-alloy-${each.value}-status"
  alarm_description   = "EC2 instance status check failed"
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = local.alarm_actions

  dimensions = { InstanceId = each.value }
  tags       = var.tags
}

resource "aws_cloudwatch_metric_alarm" "alloy_recovery" {
  for_each = { for index, instance_id in var.alloy_instance_ids : tostring(index) => instance_id }

  alarm_name          = "${var.name}-alloy-${each.key}-system-recovery"
  alarm_description   = "Recover the EC2 instance after an underlying system failure"
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed_System"
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "missing"
  alarm_actions = concat(local.alarm_actions, [
    "arn:aws:automate:${var.aws_region}:ec2:recover"
  ])

  dimensions = { InstanceId = each.value }
  tags       = var.tags
}

resource "aws_budgets_budget" "monthly" {
  count = var.monthly_budget_usd > 0 ? 1 : 0

  name         = "${var.name}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  dynamic "notification" {
    for_each = local.notifications_enabled ? [80, 100] : []

    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value
      threshold_type             = "PERCENTAGE"
      notification_type          = notification.value == 80 ? "FORECASTED" : "ACTUAL"
      subscriber_email_addresses = [var.alarm_email]
    }
  }
}
