resource "aws_security_group" "alb" {
  name_prefix = "${var.name}-alb-"
  description = "Public ingress to VetSoftware ALB"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.name}-alb" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  for_each = toset(var.alb_ingress_cidrs)

  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = each.value
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
  description       = "HTTP ingress"
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  for_each = toset(var.alb_ingress_cidrs)

  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = each.value
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  description       = "HTTPS ingress"
}

resource "aws_security_group" "backend" {
  name_prefix = "${var.name}-backend-"
  description = "Fargate backend"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.name}-backend" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "backend_from_alb" {
  security_group_id            = aws_security_group.backend.id
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = var.backend_port
  to_port                      = var.backend_port
  ip_protocol                  = "tcp"
  description                  = "Backend only from ALB"
}

resource "aws_vpc_security_group_egress_rule" "backend_all" {
  security_group_id = aws_security_group.backend.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "Backend outbound dependencies"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_backend" {
  security_group_id            = aws_security_group.alb.id
  referenced_security_group_id = aws_security_group.backend.id
  from_port                    = var.backend_port
  to_port                      = var.backend_port
  ip_protocol                  = "tcp"
  description                  = "ALB to backend"
}

resource "aws_security_group" "alloy" {
  name_prefix = "${var.name}-alloy-"
  description = "Private Grafana Alloy OTLP gateway"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.name}-alloy" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "alloy_grpc_from_backend" {
  security_group_id            = aws_security_group.alloy.id
  referenced_security_group_id = aws_security_group.backend.id
  from_port                    = var.alloy_grpc_port
  to_port                      = var.alloy_grpc_port
  ip_protocol                  = "tcp"
  description                  = "OTLP gRPC from backend"
}

resource "aws_vpc_security_group_ingress_rule" "alloy_http_from_backend" {
  security_group_id            = aws_security_group.alloy.id
  referenced_security_group_id = aws_security_group.backend.id
  from_port                    = var.alloy_http_port
  to_port                      = var.alloy_http_port
  ip_protocol                  = "tcp"
  description                  = "OTLP HTTP from backend"
}

resource "aws_vpc_security_group_egress_rule" "alloy_all" {
  security_group_id = aws_security_group.alloy.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "Export to Grafana Cloud"
}

resource "aws_security_group" "database" {
  name_prefix = "${var.name}-database-"
  description = "Private MySQL"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.name}-database" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "database_from_backend" {
  security_group_id            = aws_security_group.database.id
  referenced_security_group_id = aws_security_group.backend.id
  from_port                    = 3306
  to_port                      = 3306
  ip_protocol                  = "tcp"
  description                  = "MySQL from backend"
}

resource "aws_security_group" "cache" {
  name_prefix = "${var.name}-cache-"
  description = "Private Valkey"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.name}-cache" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "cache_from_backend" {
  security_group_id            = aws_security_group.cache.id
  referenced_security_group_id = aws_security_group.backend.id
  from_port                    = 6379
  to_port                      = 6379
  ip_protocol                  = "tcp"
  description                  = "Valkey TLS from backend"
}
