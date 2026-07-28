output "instance_ids" {
  value = aws_instance.this[*].id
}

output "private_ips" {
  value = aws_instance.this[*].private_ip
}

output "public_ips" {
  value = aws_instance.this[*].public_ip
}

output "role_arn" {
  value = aws_iam_role.this.arn
}

output "log_group_name" {
  value = aws_cloudwatch_log_group.this.name
}
