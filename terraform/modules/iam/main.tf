# -----------------------------------------------------------------------------
# IAM MODULE
#  - Cluster role : assumed by the EKS control plane (managed by AWS) so it can
#                   create ENIs, load balancers etc. on your behalf.
#  - Node role    : assumed by the EC2 worker nodes. Gives the kubelet just
#                   enough to join the cluster, run the VPC CNI, and pull images
#                   from ECR (read-only).
#
# Roles for add-ons (ExternalDNS, cert-manager) are NOT here on purpose: they
# should be scoped to a single Kubernetes service account (IRSA / Pod Identity),
# not given to every node. Those get added in Tasks 3 & 4.
# -----------------------------------------------------------------------------

# ---------------- Cluster role ----------------
resource "aws_iam_role" "cluster" {
  name = "${var.name}-eks-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "cluster" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy",
  ])

  role       = aws_iam_role.cluster.name
  policy_arn = each.value
}

# ---------------- Worker node role ----------------
resource "aws_iam_role" "node" {
  name = "${var.name}-eks-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "node" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",          # join the cluster
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",               # VPC CNI assigns pod IPs
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly", # pull images from ECR
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",       # shell into nodes via SSM instead of SSH
  ])

  role       = aws_iam_role.node.name
  policy_arn = each.value
}
