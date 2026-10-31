variable "cluster_name" {
  type = string
}

variable "cluster_version" {
  description = "Kubernetes version. Check what's in standard support: aws eks describe-cluster-versions --query 'clusterVersions[?status==`STANDARD_SUPPORT`].clusterVersion'"
  type        = string
}

variable "private_subnet_ids" {
  description = "Subnets for the control plane ENIs and the Auto Mode nodes."
  type        = list(string)
}

variable "cluster_role_arn" {
  type = string
}

variable "cluster_role_name" {
  description = "Name of the cluster role, so this module can let it use the secrets KMS key."
  type        = string
}

variable "node_role_arn" {
  type = string
}

variable "node_pools" {
  description = "Built-in Auto Mode node pools to enable."
  type        = list(string)
  default     = ["general-purpose", "system"]

  validation {
    condition     = alltrue([for p in var.node_pools : contains(["general-purpose", "system"], p)])
    error_message = "Built-in node pools are \"general-purpose\" and \"system\"."
  }
}

variable "api_allowed_cidrs" {
  description = "CIDRs allowed to reach the public Kubernetes API endpoint."
  type        = list(string)
}

variable "cluster_admin_arns" {
  description = "Extra IAM user/role ARNs to make cluster admins. Whoever runs Terraform is always added."
  type        = list(string)
  default     = []
}

variable "log_retention_days" {
  type    = number
  default = 7
}
