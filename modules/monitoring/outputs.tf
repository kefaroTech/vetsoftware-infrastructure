output "alarm_topic_arn" {
  value = length(aws_sns_topic.alarms) > 0 ? aws_sns_topic.alarms[0].arn : null
}

output "cost_anomaly_monitor_arn" {
  description = "ARN del monitor de anomalías por servicio cuando está habilitado."
  value       = length(aws_ce_anomaly_monitor.services) > 0 ? aws_ce_anomaly_monitor.services[0].arn : null
}

output "slack_chat_configuration_arn" {
  description = "ARN de la configuración Amazon Q Developer/Slack cuando está habilitada."
  value       = length(aws_chatbot_slack_channel_configuration.alarms) > 0 ? aws_chatbot_slack_channel_configuration.alarms[0].chat_configuration_arn : null
}
