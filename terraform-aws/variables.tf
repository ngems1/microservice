variable "region" {
  description = "AWS region for every resource."
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Name prefix used for all resources."
  type        = string
  default     = "week3-boutique"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "cluster_version" {
  description = "EKS Kubernetes version. Use a version in STANDARD support (check the EKS console); older versions cost 6x more."
  type        = string
  default     = "1.35"
}

variable "node_instance_types" {
  description = "EC2 instance types for the managed node group."
  type        = list(string)
  default     = ["t3.medium"]
}

variable "node_desired_size" {
  description = "Number of worker nodes. 3 x t3.medium fits all 11 services plus monitoring."
  type        = number
  default     = 3
}

variable "admin_principal_arn" {
  description = "Your IAM user or role ARN, given cluster-admin so you can run kubectl from CloudShell. Empty = skip."
  type        = string
  default     = ""
}

variable "db_instance_class" {
  description = "RDS MySQL instance size for both environments (prod adds a Multi-AZ standby)."
  type        = string
  default     = "db.t4g.micro"
}

variable "ecr_prefix" {
  description = "ECR repositories are created as <ecr_prefix>/<service>."
  type        = string
  default     = "boutique"
}

variable "services" {
  description = "Online Boutique services that get an ECR repository."
  type        = list(string)
  default = [
    "adservice",
    "cartservice",
    "checkoutservice",
    "currencyservice",
    "emailservice",
    "frontend",
    "inventoryservice",
    "loadgenerator",
    "paymentservice",
    "productcatalogservice",
    "recommendationservice",
    "shippingservice",
  ]
}

variable "lbc_version" {
  description = "AWS Load Balancer Controller release whose IAM policy is used. Keep in step with the Helm chart version in the deploy workflow."
  type        = string
  default     = "v2.13.0"
}

variable "slack_team_id" {
  description = "Slack workspace ID (T...), after authorizing Slack in Amazon Q Developer in chat applications. Empty = no Slack alerts."
  type        = string
  default     = ""
}

variable "slack_channel_id" {
  description = "Slack channel ID (C...) that receives the CloudWatch alarms."
  type        = string
  default     = ""
}
