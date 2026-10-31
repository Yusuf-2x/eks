variable "region" {
  description = "Must match the EKS cluster's region (pulling across regions is slower and costs data transfer)."
  type        = string
  default     = "eu-west-2"
}

variable "project_name" {
  type    = string
  default = "eks-project"
}

variable "repository_name" {
  type    = string
  default = "eks-2048"
}

variable "max_image_count" {
  description = "How many images to keep before the oldest are deleted."
  type        = number
  default     = 20
}

variable "untagged_expiry_days" {
  type    = number
  default = 7
}
