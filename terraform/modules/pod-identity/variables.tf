variable "name" {
  description = "IAM role name."
  type        = string
}

variable "cluster_name" {
  type = string
}

variable "namespace" {
  description = "Namespace of the service account."
  type        = string
}

variable "service_account" {
  description = "Service account the role is bound to. It doesn't need to exist yet."
  type        = string
}

variable "policy_json" {
  description = "Inline IAM policy (JSON) with exactly the permissions the pod needs."
  type        = string
}
