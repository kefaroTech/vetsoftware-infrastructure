output "application_bucket_name" {
  value = aws_s3_bucket.application.id
}

output "application_bucket_arn" {
  value = aws_s3_bucket.application.arn
}

output "audit_bucket_name" {
  value = aws_s3_bucket.audit.id
}

output "audit_bucket_arn" {
  value = aws_s3_bucket.audit.arn
}

output "delivery_stream_name" {
  value = aws_kinesis_firehose_delivery_stream.audit.name
}

output "delivery_stream_arn" {
  value = aws_kinesis_firehose_delivery_stream.audit.arn
}
