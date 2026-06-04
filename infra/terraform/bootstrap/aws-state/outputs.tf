output "state_bucket_name" {
  value = aws_s3_bucket.state_storage.id
}

output "lock_table_name" {
  value = aws_dynamodb_table.lock_table.name
}

output "aws_region" {
  value = var.aws_region
}
