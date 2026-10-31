variable "region" {
  type    = string
  default = "eu-west-2"
}

variable "project_name" {
  description = "Prefix for every resource name."
  type        = string
  default     = "eks-project"
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "az_count" {
  type    = number
  default = 2
}

variable "single_nat_gateway" {
  description = "One NAT gateway instead of one per AZ. Saves ~$35/month per AZ."
  type        = bool
  default     = true
}

variable "cluster_version" {
  type    = string
  default = "1.37"
}

variable "node_pools" {
  description = "Auto Mode built-in node pools. Nodes only exist while pods need them."
  type        = list(string)
  default     = ["general-purpose", "system"]
}

variable "api_allowed_cidrs" {
  description = "Who can reach the Kubernetes API (kubectl), e.g. your own IP as [\"x.x.x.x/32\"]. Set it in terraform.tfvars (or TF_VAR_api_allowed_cidrs in CI)."
  type        = list(string)
  # No default on purpose: you have to decide who can reach the API.

  validation {
    condition     = length(var.api_allowed_cidrs) > 0 && !contains(var.api_allowed_cidrs, "0.0.0.0/0")
    error_message = "Give at least one CIDR, and not 0.0.0.0/0 (that opens the Kubernetes API to the whole internet)."
  }
}

variable "domain_name" {
  description = "Existing public Route 53 hosted zone. The app is served at eks.<domain>, plus argocd.<domain> and grafana.<domain>."
  type        = string
}

variable "gitops_repo_url" {
  description = "Public Git repo Argo CD deploys the app from (manifests in k8s/)."
  type        = string
  default     = "https://github.com/Yusuf-2x/eks.git"
}

variable "gitops_revision" {
  description = "Branch, tag or commit Argo CD tracks."
  type        = string
  default     = "main"
}

variable "cluster_admin_arns" {
  description = "Extra IAM user/role ARNs to make cluster admins (whoever runs Terraform is added automatically)."
  type        = list(string)
  default     = []
}
