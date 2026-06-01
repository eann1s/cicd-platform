variable "aws_region" {
  type    = string
  default = "eu-north-1"
}

variable "aws_profile" {
  type    = string
  default = "cicd-platform-dev"
}

variable "project_name" {
  type    = string
  default = "cicd-platform"
}

variable "environment" {
  type    = string
  default = "dev"
}

variable "github_owner" {
  type    = string
  default = "eann1s"
}

variable "github_repo" {
  type    = string
  default = "cicd-platform"
}

