output "argocd_url" {
  value = "https://${local.argocd_host}"
}

output "grafana_url" {
  value = "https://${local.grafana_host}"
}

output "grafana_admin_password" {
  value     = random_password.grafana_admin.result
  sensitive = true
}

output "hosted_zone_id" {
  value = data.aws_route53_zone.this.zone_id
}
