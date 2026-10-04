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
      # Prefix delegation: each node gets /28 IP blocks instead of single IPs, so a
      # t3.medium runs up to 110 pods instead of 17 (the limit behind "Too many pods").
      # EKS sets the nodes' pod limit from this when the node group is created, so it
      # takes effect on a new cluster (infra destroy + apply) or new nodes.
      configuration_values = jsonencode({
        enableNetworkPolicy = "true"
        env = {
          ENABLE_PREFIX_DELEGATION = "true"
          WARM_PREFIX_TARGET       = "1"
        }
      })
    }
    # CPU/memory numbers per pod for the HorizontalPodAutoscaler (and "kubectl top").
    metrics-server = {
      most_recent = true
    }
    eks-pod-identity-agent = {
      most_recent    = true
      before_compute = true
    }
    # CloudWatch Container Insights: node/pod metrics and container logs.
    amazon-cloudwatch-observability = {
      most_recent = true
      # Container Insights (node/pod metrics, container logs) stays on. Application
      # Signals auto-monitor is turned off: by default it injects an OpenTelemetry
      # agent into every pod, which made the JVM of adservice too slow to start
      # (killed by its liveness probe) and is billed per request/span.
      configuration_values = jsonencode({
        manager = {
          applicationSignals = {
            autoMonitor = {
              monitorAllServices = false
            }
          }
        }
      })
    }
  }

  # The EKS metrics-server add-on listens on port 10251 on its pods. The Kubernetes API
  # (control plane) must reach it there, otherwise "kubectl top" and the HPAs get
  # "unable to fetch metrics from resource metrics API" and stay at <unknown>.
  node_security_group_additional_rules = {
    ingress_cluster_metrics_server = {
      description                   = "Cluster API to metrics-server (EKS add-on) 10251/tcp"
      protocol                      = "tcp"
      from_port                     = 10251
      to_port                       = 10251
      type                          = "ingress"
      source_cluster_security_group = true
    }
  }

  eks_managed_node_groups = {
    default = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = var.node_instance_types
      min_size       = 2
      max_size       = 5
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
