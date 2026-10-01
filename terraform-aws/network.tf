data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  # Two AZs keeps it multi-AZ while holding cost down.
  # Private: 10.0.0.0/20 and 10.0.16.0/20 (pods get VPC IPs, so these are large).
  # Public:  10.0.48.0/24 and 10.0.49.0/24 (ALB and NAT gateway only).
  azs             = slice(data.aws_availability_zones.available.names, 0, 2)
  private_subnets = [for i in range(2) : cidrsubnet(var.vpc_cidr, 4, i)]
  public_subnets  = [for i in range(2) : cidrsubnet(var.vpc_cidr, 8, 48 + i)]
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.project}-vpc"
  cidr = var.vpc_cidr

  azs             = local.azs
  private_subnets = local.private_subnets
  public_subnets  = local.public_subnets

  # One NAT gateway instead of one per AZ: cheaper, fine for a dev environment.
  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true
  enable_dns_support   = true

  # Lets the AWS Load Balancer Controller find the right subnets.
  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }
}
