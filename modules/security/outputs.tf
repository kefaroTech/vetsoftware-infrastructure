output "alb_security_group_id" {
  value = aws_security_group.alb.id
}

output "backend_security_group_id" {
  value = aws_security_group.backend.id
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

output "public_https_egress" {
  value = {
    backend_cidr = aws_vpc_security_group_egress_rule.backend_public_https.cidr_ipv4
    backend_port = aws_vpc_security_group_egress_rule.backend_public_https.to_port
    alloy_cidr   = aws_vpc_security_group_egress_rule.alloy_public_https.cidr_ipv4
    alloy_port   = aws_vpc_security_group_egress_rule.alloy_public_https.to_port
  }
}
