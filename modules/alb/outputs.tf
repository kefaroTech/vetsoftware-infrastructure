output "arn" {
  value = aws_lb.this.arn
}

output "arn_suffix" {
  value = aws_lb.this.arn_suffix
}

output "dns_name" {
  value = aws_lb.this.dns_name
}

output "zone_id" {
  value = aws_lb.this.zone_id
}

output "target_group_arn" {
  value = aws_lb_target_group.backend.arn
}

output "target_group_arn_suffix" {
  value = aws_lb_target_group.backend.arn_suffix
}

output "listener_arn" {
  value = aws_lb_listener.https.arn
}

output "access_log_group_name" {
  value = aws_cloudwatch_log_group.access.name
}

output "origin_url" {
  description = "Origen privado que debe configurarse en Cloudflare Tunnel."
  value       = "https://${aws_lb.this.dns_name}:443"
}
