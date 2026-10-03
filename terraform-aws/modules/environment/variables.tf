# Everything one environment (dev or prod) owns. The root module creates this twice.

variable "env" {
  description = "Environment name: dev or prod."
  type        = string
}

variable "name_prefix" {
  description = "Prefix for every resource name, e.g. week3-boutique-dev."
  type        = string
}

variable "namespace" {
  description = "Kubernetes namespace of this environment, e.g. boutique-dev."
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster that runs the services (shared by all environments)."
  type        = string
}

variable "vpc_id" {
  type = string
}

variable "vpc_cidr" {
  type = string
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "db_instance_class" {
  type    = string
  default = "db.t3.micro"
}

variable "db_multi_az" {
  description = "Standby copy of the database in a second AZ (automatic failover)."
  type        = bool
  default     = false
}

variable "db_backup_retention_days" {
  type    = number
  default = 1
}

variable "lambda_source_dir" {
  description = "Folder with the order-status Lambda code (and its vendored pymysql)."
  type        = string
}
