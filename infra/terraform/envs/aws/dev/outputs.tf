output "go_service_repository_name" {
  value = aws_ecr_repository.go_service.name
}

output "go_service_repository_url" {
  value = aws_ecr_repository.go_service.repository_url
}

output "go_service_repository_arn" {
  value = aws_ecr_repository.go_service.arn
}

output "github_actions_ecr_push_role_arn" {
  value = aws_iam_role.github_actions_ecr_push.arn
}

output "vpc_id" {
  value = aws_vpc.main.id
}

output "public_subnet_ids" {
  value = aws_subnet.public[*].id
}

output "internet_gateway_id" {
  value = aws_internet_gateway.main.id
}

output "public_route_table_id" {
  value = aws_route_table.public.id
}
