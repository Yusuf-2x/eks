variable "cluster_name" {
  description = "Also used as ExternalDNS's owner ID, so it only manages its own records."
  type        = string
}

variable "region" {
  type = string
}

variable "domain_name" {
  description = "Public Route 53 hosted zone that already exists, e.g. example.com."
  type        = string
}

variable "cluster_issuer" {
  description = "ClusterIssuer for the add-on UIs: letsencrypt-prod or letsencrypt-staging."
  type        = string
  default     = "letsencrypt-prod"

  validation {
    condition     = contains(["letsencrypt-prod", "letsencrypt-staging"], var.cluster_issuer)
    error_message = "Use letsencrypt-prod or letsencrypt-staging."
  }
}

variable "app_name" {
  description = "Name of the Argo CD Application."
  type        = string
}

variable "app_namespace" {
  description = "Namespace the app's manifests deploy into (must match k8s/)."
  type        = string
}

variable "gitops_repo_url" {
  description = "Public Git repo Argo CD pulls the app manifests from."
  type        = string
}

variable "gitops_revision" {
  description = "Branch, tag or commit Argo CD tracks."
  type        = string
}

variable "gitops_path" {
  description = "Folder in the repo holding the app's manifests."
  type        = string
}
