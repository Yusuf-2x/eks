variable "name" {
  description = "Name prefix for all VPC resources."
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name, used for the kubernetes.io/cluster/<name> subnet tags."
  type        = string
}

variable "cidr_block" {
  description = "VPC CIDR range."
  type        = string
  default     = "10.0.0.0/16"
}

variable "az_count" {
  description = "How many availability zones to spread subnets across (2 or 3)."
  type        = number
  default     = 2

  validation {
    condition     = var.az_count >= 2 && var.az_count <= 3
    error_message = "EKS needs subnets in at least 2 AZs; this module supports 2 or 3."
  }
}

variable "single_nat_gateway" {
  description = "true = one shared NAT gateway (cheaper, fine for learning). false = one per AZ (highly available, production)."
  type        = bool
  default     = true
}

variable "enable_flow_logs" {
  description = "Send VPC flow logs to CloudWatch."
  type        = bool
  default     = true
}
