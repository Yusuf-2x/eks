output "cluster_name" {
  value = aws_eks_cluster.this.name
  # Anything that logs in to the cluster with this (the Helm provider, the
  # add-ons) waits until the admins can actually log in, and is removed
  # before their access is.
  depends_on = [aws_eks_access_policy_association.admin]
}

output "cluster_endpoint" {
  value = aws_eks_cluster.this.endpoint
}

output "cluster_certificate_authority_data" {
  value = aws_eks_cluster.this.certificate_authority[0].data
}

output "cluster_security_group_id" {
  description = "The SG EKS created; Auto Mode attaches it to the control plane and the nodes."
  value       = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

output "cluster_admin_arns" {
  value = sort(tolist(local.admin_principal_arns))
}
