module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = "${var.project}-eks"
  cluster_version = var.cluster_version

  # Public endpoint so GitHub-hosted runners and CloudShell can reach the API.
  cluster_endpoint_public_access = true

  # The identity that runs Terraform (the GitHub Actions role) becomes cluster admin.
  enable_cluster_creator_admin_permissions = true

  vpc_id                   = module.vpc.vpc_id
  subnet_ids               = module.vpc.private_subnets
  control_plane_subnet_ids = module.vpc.private_subnets

  cluster_addons = {
    coredns = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
    vpc-cni = {
      most_recent    = true
      before_compute = true
      # Enforce Kubernetes NetworkPolicies (blocks traffic between boutique-dev and boutique-prod).
      configuration_values = jsonencode({
        enableNetworkPolicy = "true"
      })
    }
    eks-pod-identity-agent = {
      most_recent    = true
      before_compute = true
    }
    # CloudWatch Container Insights: node/pod metrics and container logs.
    amazon-cloudwatch-observability = {
      most_recent = true
    }
  }

  eks_managed_node_groups = {
    default = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = var.node_instance_types
      min_size       = 2
      max_size       = 4
      desired_size   = var.node_desired_size

      iam_role_additional_policies = {
        CloudWatchAgentServerPolicy = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
      }
    }
  }

  # Optional: your own IAM identity gets kubectl admin access.
  access_entries = {
    for name, arn in { admin = var.admin_principal_arn } : name => {
      principal_arn = arn
      policy_associations = {
        admin = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = {
            type = "cluster"
          }
        }
      }
    } if arn != ""
  }
}
