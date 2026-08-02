resource "aws_lb" "this" {
  name               = substr(var.name, 0, 32)
  internal           = true
  load_balancer_type = "application"
  security_groups    = var.security_group_ids
  subnets            = var.subnet_ids

  enable_deletion_protection = var.enable_deletion_protection
  drop_invalid_header_fields = true
  enable_http2               = true
  idle_timeout               = 60

  tags = merge(var.tags, { Name = var.name })
}

resource "aws_lb_target_group" "backend" {
  name        = substr("${var.name}-backend", 0, 32)
  port        = var.backend_port
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = var.vpc_id

  deregistration_delay = 30

  health_check {
    enabled             = true
    path                = var.health_check_path
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = var.tags
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = var.ssl_policy
  certificate_arn   = var.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.backend.arn
  }
}

resource "aws_cloudwatch_log_group" "access" {
  name                        = "/aws/vendedlogs/elasticloadbalancing/${var.name}/access"
  retention_in_days           = var.access_log_retention_days
  kms_key_id                  = var.kms_key_arn
  deletion_protection_enabled = var.enable_deletion_protection
  tags                        = var.tags
}

resource "aws_cloudwatch_log_delivery_source" "access" {
  name         = "${var.name}-alb-access"
  log_type     = "ALB_ACCESS_LOGS"
  resource_arn = aws_lb.this.arn
  tags         = var.tags
}

resource "aws_cloudwatch_log_delivery_destination" "access" {
  name          = "${var.name}-alb-access"
  output_format = "json"

  delivery_destination_configuration {
    destination_resource_arn = aws_cloudwatch_log_group.access.arn
  }

  tags = var.tags
}

resource "aws_cloudwatch_log_delivery" "access" {
  delivery_source_name     = aws_cloudwatch_log_delivery_source.access.name
  delivery_destination_arn = aws_cloudwatch_log_delivery_destination.access.arn
  tags                     = var.tags
}
