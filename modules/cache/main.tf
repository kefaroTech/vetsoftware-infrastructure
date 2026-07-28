ephemeral "random_password" "valkey" {
  length           = 40
  special          = true
  override_special = "!#$%&*+-.:=?@^_~"
  min_lower        = 4
  min_upper        = 4
  min_numeric      = 4
  min_special      = 4
}

resource "aws_elasticache_user" "application" {
  user_id       = replace("${var.name}-app", "_", "-")
  user_name     = var.user_name
  access_string = "on ~* +@all"
  engine        = "valkey"

  passwords_wo         = ephemeral.random_password.valkey.result
  passwords_wo_version = var.password_version

  tags = var.tags
}

resource "aws_elasticache_user_group" "this" {
  engine        = "valkey"
  user_group_id = replace("${var.name}-users", "_", "-")
  user_ids      = [aws_elasticache_user.application.user_id]

  tags = var.tags
}

resource "aws_elasticache_serverless_cache" "this" {
  engine               = "valkey"
  major_engine_version = var.major_engine_version
  name                 = var.name
  description          = "VetSoftware managed serverless cache"

  subnet_ids         = var.subnet_ids
  security_group_ids = var.security_group_ids
  user_group_id      = aws_elasticache_user_group.this.user_group_id

  cache_usage_limits {
    data_storage {
      maximum = var.maximum_data_storage_gb
      unit    = "GB"
    }

    ecpu_per_second {
      maximum = var.maximum_ecpu_per_second
    }
  }

  daily_snapshot_time      = var.daily_snapshot_time
  snapshot_retention_limit = var.snapshot_retention_limit

  tags = merge(var.tags, { Name = var.name })
}

resource "aws_secretsmanager_secret" "connection" {
  name                    = "${var.name}/connection"
  description             = "Generated Valkey TLS connection for VetSoftware"
  recovery_window_in_days = 7
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "connection" {
  secret_id = aws_secretsmanager_secret.connection.id
  secret_string_wo = jsonencode({
    REDIS_URL = "rediss://${var.user_name}:${urlencode(ephemeral.random_password.valkey.result)}@${aws_elasticache_serverless_cache.this.endpoint[0].address}:${aws_elasticache_serverless_cache.this.endpoint[0].port}"
  })
  secret_string_wo_version = var.password_version
}
