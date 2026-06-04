locals {
  name_prefix = "${var.project_name}-${var.environment}"
  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
    Purpose     = "terraform-state"
  }
}

resource "aws_s3_bucket" "state_storage" {
  bucket = "${local.name_prefix}-${var.state_bucket_name}"
  tags   = local.common_tags
}

resource "aws_s3_bucket_versioning" "state_storage" {
  bucket = aws_s3_bucket.state_storage.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state_storage" {
  bucket = aws_s3_bucket.state_storage.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state_storage" {
  bucket                  = aws_s3_bucket.state_storage.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_dynamodb_table" "lock_table" {
  name         = "${local.name_prefix}-${var.lock_table_name}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"
  attribute {
    name = "LockID"
    type = "S"
  }
  tags = merge(local.common_tags, { Name = "${local.name_prefix}-tf-lock-table" })
}
