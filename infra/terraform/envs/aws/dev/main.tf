locals {
  name_prefix = "${var.project_name}-${var.environment}"
  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
    Repository  = "${var.github_owner}/${var.github_repo}"
  }
}

resource "aws_ecr_repository" "go_service" {
  name                 = "${local.name_prefix}-go-service"
  image_tag_mutability = "IMMUTABLE"
  image_scanning_configuration {
    scan_on_push = true
  }
  tags = local.common_tags
}
