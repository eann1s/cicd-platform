terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
  backend "s3" {
    bucket         = "cicd-platform-dev-tfstate-980481493011"
    key            = "envs/aws/dev/terraform.tfstate"
    region         = "eu-north-1"
    dynamodb_table = "cicd-platform-dev-tflock"
    profile        = "cicd-platform-dev"
    encrypt        = true
  }
}

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile
}
