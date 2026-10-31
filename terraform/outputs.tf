output "region" {
  value = var.region
}

output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "cluster_admin_arns" {
  value = module.eks.cluster_admin_arns
}

output "configure_kubectl" {
  description = "Run this to point kubectl at the new cluster."
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
}

output "app_url" {
  description = "The host itself is set in k8s/ingress.yaml (Git), not here."
  value       = "https://eks.${var.domain_name}"
}

output "argocd_url" {
  value = module.addons.argocd_url
}

output "argocd_admin_password_command" {
  description = "Argo CD makes a random admin password on install; this prints it (user: admin)."
  value       = "kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
}

output "grafana_url" {
  value = module.addons.grafana_url
}

output "grafana_admin_password" {
  description = "User: admin. Show it with: terraform output -raw grafana_admin_password"
  value       = module.addons.grafana_admin_password
  sensitive   = true
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "public_subnet_ids" {
  value = module.vpc.public_subnet_ids
}

output "private_subnet_ids" {
  value = module.vpc.private_subnet_ids
}

output "node_role_name" {
  description = "IAM role Auto Mode nodes use (needed if you add a custom NodeClass later)."
  value       = module.iam.node_role_name
}
