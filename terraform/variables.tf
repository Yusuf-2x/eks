variable "region" {
  type    = string
  default = "eu-north-1"
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
  default = "1.35"
}

variable "api_allowed_cidrs" {
  description = "Who can reach the Kubernetes API. Set to your own IP (x.x.x.x/32) for best security; note GitHub-hosted CI runners will need access too in Task 5."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "node_instance_types" {
  type    = list(string)
  default = ["t3.medium"]
}

variable "node_capacity_type" {
  type    = string
  default = "ON_DEMAND"
}

variable "node_min_size" {
  type    = number
  default = 1
}

variable "node_desired_size" {
  type    = number
  default = 2
}

variable "node_max_size" {
  type    = number
  default = 2
}
