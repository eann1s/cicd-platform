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

variable "vpc_cidr" {
  type    = string
  default = "10.20.0.0/16"
}
variable "public_subnet_cidrs" {
  type    = list(string)
  default = ["10.20.1.0/24", "10.20.2.0/24"]
}
variable "availability_zones" {
  type    = list(string)
  default = ["eu-north-1a", "eu-north-1b"]
}
