output "alarm_topic_arn" {
  value = length(aws_sns_topic.alarms) > 0 ? aws_sns_topic.alarms[0].arn : null
}
