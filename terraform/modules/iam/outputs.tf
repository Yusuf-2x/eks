# The role ARNs "wait" for their policy attachments, so anything using them
# (the cluster) is created after the policies are attached and destroyed
# before they are detached. Auto Mode needs the policies to clean up nodes,
# load balancers and volumes on destroy.

output "cluster_role_arn" {
  value      = aws_iam_role.cluster.arn
  depends_on = [aws_iam_role_policy_attachment.cluster]
}

output "cluster_role_name" {
  value = aws_iam_role.cluster.name
}

output "node_role_arn" {
  value      = aws_iam_role.node.arn
  depends_on = [aws_iam_role_policy_attachment.node]
}

output "node_role_name" {
  value = aws_iam_role.node.name
}
