output "region" {
  value = var.region
}

output "cluster_name" {
  value = module.eks.cluster_name
}

output "vpc_id" {
  description = "Passed to the AWS Load Balancer Controller Helm chart."
  value       = module.vpc.vpc_id
}

output "ecr_registry" {
  description = "Helm value images.repository (registry + prefix)."
  value       = "${split("/", aws_ecr_repository.svc["frontend"].repository_url)[0]}/${var.ecr_prefix}"
}

output "environments" {
  description = "Per-environment settings for the Helm values: terraform output -json environments"
  value       = { for name, env in module.env : name => env.settings }
}
