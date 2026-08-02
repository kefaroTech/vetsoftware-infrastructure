resource "aws_security_group" "alb" {
  name_prefix = "${var.name}-alb-"
  description = "Internal ALB reachable only from backend tunnel connectors"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.name}-alb" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "backend" {
  name_prefix = "${var.name}-backend-"
  description = "Fargate backend and Cloudflare Tunnel connector"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.name}-backend" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "alb_https_from_tunnel" {
  security_group_id            = aws_security_group.alb.id
  referenced_security_group_id = aws_security_group.backend.id
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
  description                  = "HTTPS from colocated Cloudflare Tunnel connectors"
}

resource "aws_vpc_security_group_ingress_rule" "backend_from_alb" {
  security_group_id            = aws_security_group.backend.id
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = var.backend_port
  to_port                      = var.backend_port
  ip_protocol                  = "tcp"
  description                  = "Backend only from internal ALB"
}

resource "aws_vpc_security_group_egress_rule" "backend_external_https" {
  for_each = toset(var.approved_external_https_ipv4_cidrs)

  security_group_id = aws_security_group.backend.id
  cidr_ipv4         = each.value
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  description       = "HTTPS to explicitly approved external services"
}

resource "aws_vpc_security_group_egress_rule" "backend_cloudflare_tunnel" {
  for_each = toset(var.cloudflare_tunnel_ipv4_cidrs)

  security_group_id = aws_security_group.backend.id
  cidr_ipv4         = each.value
  from_port         = 7844
  to_port           = 7844
  ip_protocol       = "tcp"
  description       = "Cloudflare Tunnel HTTP2 transport"
}

resource "aws_vpc_security_group_egress_rule" "backend_to_alb" {
  security_group_id            = aws_security_group.backend.id
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
  description                  = "Cloudflare Tunnel connector to internal ALB"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_backend" {
  security_group_id            = aws_security_group.alb.id
  referenced_security_group_id = aws_security_group.backend.id
  from_port                    = var.backend_port
  to_port                      = var.backend_port
  ip_protocol                  = "tcp"
  description                  = "Internal ALB to backend"
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

resource "aws_vpc_security_group_egress_rule" "alloy_external_https" {
  for_each = toset(var.approved_external_https_ipv4_cidrs)

  security_group_id = aws_security_group.alloy.id
  cidr_ipv4         = each.value
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  description       = "HTTPS export to explicitly approved Grafana endpoints"
}

resource "aws_security_group" "vpc_endpoints" {
  name_prefix = "${var.name}-vpc-endpoints-"
  description = "PrivateLink endpoints for approved AWS APIs"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.name}-vpc-endpoints" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "endpoints_from_backend" {
  security_group_id            = aws_security_group.vpc_endpoints.id
  referenced_security_group_id = aws_security_group.backend.id
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
  description                  = "AWS APIs from backend tasks"
}

resource "aws_vpc_security_group_ingress_rule" "endpoints_from_alloy" {
  security_group_id            = aws_security_group.vpc_endpoints.id
  referenced_security_group_id = aws_security_group.alloy.id
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
  description                  = "AWS APIs from Alloy instances"
}

resource "aws_vpc_security_group_egress_rule" "backend_to_endpoints" {
  security_group_id            = aws_security_group.backend.id
  referenced_security_group_id = aws_security_group.vpc_endpoints.id
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
  description                  = "Backend to private AWS API endpoints"
}

resource "aws_vpc_security_group_egress_rule" "alloy_to_endpoints" {
  security_group_id            = aws_security_group.alloy.id
  referenced_security_group_id = aws_security_group.vpc_endpoints.id
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
  description                  = "Alloy to private AWS API endpoints"
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

resource "aws_vpc_security_group_egress_rule" "backend_to_database" {
  security_group_id            = aws_security_group.backend.id
  referenced_security_group_id = aws_security_group.database.id
  from_port                    = 3306
  to_port                      = 3306
  ip_protocol                  = "tcp"
  description                  = "Backend to MySQL"
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

resource "aws_vpc_security_group_egress_rule" "backend_to_cache" {
  security_group_id            = aws_security_group.backend.id
  referenced_security_group_id = aws_security_group.cache.id
  from_port                    = 6379
  to_port                      = 6379
  ip_protocol                  = "tcp"
  description                  = "Backend to Valkey"
}

resource "aws_vpc_security_group_egress_rule" "backend_to_alloy_grpc" {
  security_group_id            = aws_security_group.backend.id
  referenced_security_group_id = aws_security_group.alloy.id
  from_port                    = var.alloy_grpc_port
  to_port                      = var.alloy_grpc_port
  ip_protocol                  = "tcp"
  description                  = "Backend OTLP gRPC to Alloy"
}

resource "aws_vpc_security_group_egress_rule" "backend_to_alloy_http" {
  security_group_id            = aws_security_group.backend.id
  referenced_security_group_id = aws_security_group.alloy.id
  from_port                    = var.alloy_http_port
  to_port                      = var.alloy_http_port
  ip_protocol                  = "tcp"
  description                  = "Backend OTLP HTTP to Alloy"
}
