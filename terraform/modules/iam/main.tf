# -----------------------------------------------------------------------------
# IAM MODULE (EKS Auto Mode)
#  - Cluster role : assumed by EKS. With Auto Mode, EKS itself launches nodes,
#                   attaches EBS volumes, creates load balancers and manages
#                   networking, so the role carries the Auto Mode policies.
#  - Node role    : assumed by the EC2 nodes Auto Mode launches. Deliberately
#                   minimal: register with the cluster + pull images from ECR.
#
# Roles for add-ons (ExternalDNS, cert-manager) are NOT here on purpose: they
# should be scoped to a single Kubernetes service account via EKS Pod Identity,
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
    "arn:aws:iam::aws:policy/AmazonEKSComputePolicy",       # launch/terminate nodes
    "arn:aws:iam::aws:policy/AmazonEKSBlockStoragePolicy",  # EBS volumes for pods
    "arn:aws:iam::aws:policy/AmazonEKSLoadBalancingPolicy", # NLB/ALB for Services/Ingress
    "arn:aws:iam::aws:policy/AmazonEKSNetworkingPolicy",    # ENIs and pod IPs
  ])

  role       = aws_iam_role.cluster.name
  policy_arn = each.value
}

# ---------------- Node role ----------------
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
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodeMinimalPolicy",   # join the cluster
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly", # pull images from ECR, nothing else
  ])

  role       = aws_iam_role.node.name
  policy_arn = each.value
}
