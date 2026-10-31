# -----------------------------------------------------------------------------
# POD IDENTITY MODULE
#  One IAM role for one Kubernetes service account, bound with EKS Pod
#  Identity (the agent Auto Mode runs on every node). Only pods using that
#  service account in that namespace get these permissions, not the node.
# -----------------------------------------------------------------------------

resource "aws_iam_role" "this" {
  name = var.name

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy" "this" {
  name   = var.name
  role   = aws_iam_role.this.id
  policy = var.policy_json
}

resource "aws_eks_pod_identity_association" "this" {
  cluster_name    = var.cluster_name
  namespace       = var.namespace
  service_account = var.service_account
  role_arn        = aws_iam_role.this.arn

  # Credentials are injected when the pod starts, so the policy must already be there.
  depends_on = [aws_iam_role_policy.this]
}
