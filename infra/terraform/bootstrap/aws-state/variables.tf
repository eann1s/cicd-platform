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

variable "state_bucket_name" {
  type    = string
  default = "tfstate-980481493011"
}

variable "lock_table_name" {
  type    = string
  default = "tflock"
}


