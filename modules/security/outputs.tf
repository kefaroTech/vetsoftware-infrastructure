output "alb_security_group_id" {
  value = aws_security_group.alb.id
}

output "backend_security_group_id" {
  value = aws_security_group.backend.id
}

output "gotenberg_security_group_id" {
  value = aws_security_group.gotenberg.id
}

output "alloy_security_group_id" {
  value = aws_security_group.alloy.id
}

output "database_security_group_id" {
  value = aws_security_group.database.id
}

output "cache_security_group_id" {
  value = aws_security_group.cache.id
}
