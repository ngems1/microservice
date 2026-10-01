variable "region" {
  description = "AWS region for the state bucket (use the same region as terraform-aws)."
  type        = string
  default     = "us-east-1"
}

variable "github_owner" {
  description = "GitHub user or organization that owns the repo (the bootstrap workflow fills this in)."
  type        = string
}

variable "github_repo" {
  description = "GitHub repository name (the bootstrap workflow fills this in)."
  type        = string
}

variable "state_bucket_name" {
  description = "Name of the Terraform state bucket. Empty = week3-tfstate-<account-id>."
  type        = string
  default     = ""
}

variable "create_oidc_provider" {
  description = "Create the GitHub OIDC provider. False when it already exists (the bootstrap workflow signs in through it, so it passes false)."
  type        = bool
  default     = true
}

variable "plan_role_name" {
  description = "Read-only role used by pull-request plans."
  type        = string
  default     = "week3-gha-plan"
}

variable "deploy_role_name" {
  description = "Role used to apply Terraform and deploy, from main and the dev/prod environments only."
  type        = string
  default     = "week3-gha-deploy"
}

variable "deploy_policy_arn" {
  description = "Permissions of the deploy role. Terraform creates IAM roles, VPCs, EKS, so it needs broad rights; narrowing it is a security remediation item."
  type        = string
  default     = "arn:aws:iam::aws:policy/AdministratorAccess"
}

variable "github_environments" {
  description = "GitHub environments whose jobs may use the deploy role."
  type        = list(string)
  default     = ["dev", "prod"]
}
