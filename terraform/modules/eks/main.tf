# -----------------------------------------------------------------------------
# EKS MODULE
#  - Control plane (managed by AWS) with secrets encryption + audit logging
#  - Managed node group in PRIVATE subnets, launched from a hardened template
#  - Security groups that only allow the traffic EKS actually needs
#  - Core add-ons (VPC CNI, CoreDNS, kube-proxy, Pod Identity agent so pods
#    can get their own scoped IAM roles in later tasks)
# -----------------------------------------------------------------------------

data "aws_caller_identity" "current" {}

# ---------------- Encryption for Kubernetes Secrets ----------------
resource "aws_kms_key" "eks" {
  description             = "Encrypts Kubernetes Secrets for ${var.cluster_name}"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AccountAdmin"
      Effect    = "Allow"
      Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
      Action    = "kms:*"
      Resource  = "*"
    }]
  })
}

resource "aws_kms_alias" "eks" {
  name          = "alias/${var.cluster_name}-secrets"
  target_key_id = aws_kms_key.eks.key_id
}

# ---------------- Control plane logs ----------------
# Must exist before the cluster, otherwise EKS creates it with no retention.
resource "aws_cloudwatch_log_group" "cluster" {
  name              = "/aws/eks/${var.cluster_name}/cluster"
  retention_in_days = var.log_retention_days
}

# ---------------- Security groups ----------------
# EKS also creates its own "cluster security group" automatically. It is
# attached to both the control plane and the nodes and allows all traffic
# between them. The two groups below add tighter, explicit rules on top.
#
# GOTCHA: do NOT tag the node SG with kubernetes.io/cluster/<name>=owned.
# The load balancer controller looks for exactly ONE SG with that tag per
# node to open NodePorts on, and EKS's own cluster SG already has it.

resource "aws_security_group" "cluster" {
  name        = "${var.cluster_name}-control-plane"
  description = "Extra rules for the EKS control plane ENIs"
  vpc_id      = var.vpc_id
  tags        = { Name = "${var.cluster_name}-control-plane" }
}

resource "aws_security_group" "node" {
  name        = "${var.cluster_name}-nodes"
  description = "EKS worker nodes"
  vpc_id      = var.vpc_id
  tags        = { Name = "${var.cluster_name}-nodes" }
}

# Control plane <- nodes : nodes call the Kubernetes API on 443
resource "aws_vpc_security_group_ingress_rule" "cluster_from_nodes_https" {
  security_group_id            = aws_security_group.cluster.id
  referenced_security_group_id = aws_security_group.node.id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  description                  = "Nodes to Kubernetes API"
}

# Nodes <- nodes : pod-to-pod and node-to-node traffic (DNS, app traffic, etc.)
resource "aws_vpc_security_group_ingress_rule" "node_from_self" {
  security_group_id            = aws_security_group.node.id
  referenced_security_group_id = aws_security_group.node.id
  ip_protocol                  = "-1"
  description                  = "Node to node, all traffic"
}

# Nodes <- control plane : kubelet (logs/exec) + webhooks (cert-manager, ingress-nginx admission)
resource "aws_vpc_security_group_ingress_rule" "node_from_cluster_kubelet" {
  security_group_id            = aws_security_group.node.id
  referenced_security_group_id = aws_security_group.cluster.id
  ip_protocol                  = "tcp"
  from_port                    = 10250
  to_port                      = 10250
  description                  = "Control plane to kubelet"
}

resource "aws_vpc_security_group_ingress_rule" "node_from_cluster_webhooks" {
  security_group_id            = aws_security_group.node.id
  referenced_security_group_id = aws_security_group.cluster.id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  description                  = "Control plane to admission webhooks on 443"
}

resource "aws_vpc_security_group_ingress_rule" "node_from_cluster_ephemeral" {
  security_group_id            = aws_security_group.node.id
  referenced_security_group_id = aws_security_group.cluster.id
  ip_protocol                  = "tcp"
  from_port                    = 1025
  to_port                      = 65535
  description                  = "Control plane to webhooks/metrics on high ports"
}

# Nodes -> anywhere : pull images, talk to AWS APIs, Let's Encrypt, Route 53...
# (Leaves via the NAT gateway; nothing can come IN this way.)
resource "aws_vpc_security_group_egress_rule" "node_all" {
  security_group_id = aws_security_group.node.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "Outbound internet via NAT"
}

# ---------------- Cluster ----------------
resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  version  = var.cluster_version
  role_arn = var.cluster_role_arn

  # Access entries (API) instead of the old aws-auth ConfigMap.
  # Whoever runs `terraform apply` becomes cluster admin.
  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = true
  }

  vpc_config {
    subnet_ids              = var.private_subnet_ids
    security_group_ids      = [aws_security_group.cluster.id]
    endpoint_private_access = true # nodes talk to the API inside the VPC
    endpoint_public_access  = true # so you (and CI) can run kubectl
    public_access_cidrs     = var.api_allowed_cidrs
  }

  encryption_config {
    resources = ["secrets"]
    provider {
      key_arn = aws_kms_key.eks.arn
    }
  }

  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  # Avoids silently rolling into "extended support", which costs 6x more per hour.
  upgrade_policy {
    support_type = "STANDARD"
  }

  depends_on = [aws_cloudwatch_log_group.cluster]
}

# ---------------- Worker nodes ----------------
resource "aws_launch_template" "node" {
  name_prefix = "${var.cluster_name}-node-"

  # Attach EKS's cluster SG (control plane <-> node, LB NodePorts) + our node SG.
  vpc_security_group_ids = [
    aws_eks_cluster.this.vpc_config[0].cluster_security_group_id,
    aws_security_group.node.id,
  ]

  # IMDSv2 only: blocks a whole class of SSRF credential-theft attacks.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = var.node_disk_size
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "${var.cluster_name}-node" }
  }
}

resource "aws_eks_node_group" "this" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.cluster_name}-default"
  node_role_arn   = var.node_role_arn
  subnet_ids      = var.private_subnet_ids

  ami_type       = "AL2023_x86_64_STANDARD"
  capacity_type  = var.node_capacity_type
  instance_types = var.node_instance_types

  launch_template {
    id      = aws_launch_template.node.id
    version = aws_launch_template.node.latest_version
  }

  scaling_config {
    min_size     = var.node_min_size
    desired_size = var.node_desired_size
    max_size     = var.node_max_size
  }

  update_config {
    max_unavailable = 1
  }

  lifecycle {
    # Let an autoscaler change the size without Terraform fighting it.
    ignore_changes = [scaling_config[0].desired_size]
  }
}

# ---------------- Add-ons ----------------
resource "aws_eks_addon" "this" {
  for_each = toset(["vpc-cni", "kube-proxy", "coredns", "eks-pod-identity-agent"])

  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = each.value
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  # CoreDNS needs nodes to schedule onto.
  depends_on = [aws_eks_node_group.this]
}

# No IAM OIDC provider (IRSA) here: this AWS account's Organization policy
# denies iam:*OpenIDConnectProvider*. Pods that need AWS permissions
# (cert-manager, ExternalDNS) use EKS Pod Identity instead, via the
# eks-pod-identity-agent add-on above + aws_eks_pod_identity_association.
