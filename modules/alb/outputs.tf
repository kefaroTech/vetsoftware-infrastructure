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

output "certificate_arn" {
  value = local.certificate_arn
}

output "url" {
  value = var.domain_name != "" ? "${local.enable_https ? "https" : "http"}://${var.domain_name}" : "http://${aws_lb.this.dns_name}"
}
