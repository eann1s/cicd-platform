output "go_service_repository_name" {
  value = aws_ecr_repository.go_service.name
}

output "go_service_repository_url" {
  value = aws_ecr_repository.go_service.repository_url
}

output "go_service_repository_arn" {
  value = aws_ecr_repository.go_service.arn
}
