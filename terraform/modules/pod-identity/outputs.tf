output "role_arn" {
  value = aws_iam_role.this.arn
}

output "association_id" {
  description = "Depend on this before installing the pods that use the role."
  value       = aws_eks_pod_identity_association.this.association_id
}
