output "endpoint" {
  value = aws_db_instance.this.address
}

output "port" {
  value = aws_db_instance.this.port
}

output "database_name" {
  value = aws_db_instance.this.db_name
}

output "master_username" {
  value = aws_db_instance.this.username
}

output "master_secret_arn" {
  value = aws_db_instance.this.master_user_secret[0].secret_arn
}

output "identifier" {
  value = aws_db_instance.this.identifier
}

output "arn" {
  value = aws_db_instance.this.arn
}

output "resource_id" {
  value = aws_db_instance.this.resource_id
}

output "hardening" {
  value = {
    backup_retention_period             = aws_db_instance.this.backup_retention_period
    deletion_protection                 = aws_db_instance.this.deletion_protection
    iam_database_authentication_enabled = aws_db_instance.this.iam_database_authentication_enabled
    skip_final_snapshot                 = aws_db_instance.this.skip_final_snapshot
  }
}
