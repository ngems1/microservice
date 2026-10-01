terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.95"
    }
  }

  # No backend here on purpose: the bootstrap workflow starts with local state,
  # then moves it into the bucket it creates (generated ci_backend.tf).
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "week3-boutique"
      ManagedBy = "terraform-bootstrap"
    }
  }
}
