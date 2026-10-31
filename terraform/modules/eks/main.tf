# -----------------------------------------------------------------------------
# EKS MODULE (Auto Mode)
#  - Control plane (managed by AWS) with secrets encryption + audit logging
#  - EKS Auto Mode: AWS launches, patches and scales the nodes (Karpenter under
#    the hood) and runs the core add-ons for us: VPC CNI, CoreDNS, kube-proxy,
#    EBS CSI driver, AWS Load Balancer Controller and the Pod Identity agent.
#    No node group, launch template or add-on resources to maintain.
#  - Auto Mode nodes are hardened by AWS: Bottlerocket OS, read-only root
#    filesystem, IMDSv2 only, encrypted volumes, no SSH/SSM, and replaced at
#    least every 21 days so they stay patched.
#  - Access entries (not the old aws-auth ConfigMap) decide who is admin.
# -----------------------------------------------------------------------------

data "aws_caller_identity" "current" {}

# Turns "assumed-role/<role>/<session>" into the role ARN, so the person or CI
# role running Terraform can be made a cluster admin.
data "aws_iam_session_context" "current" {
  arn = data.aws_caller_identity.current.arn
}

locals {
  admin_principal_arns = toset(concat([data.aws_iam_session_context.current.issuer_arn], var.cluster_admin_arns))
}

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

# The cluster role may use this one key (and nothing else) for envelope encryption.
resource "aws_iam_role_policy" "cluster_encryption" {
  name = "${var.cluster_name}-secrets-encryption"
  role = var.cluster_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["kms:Encrypt", "kms:Decrypt", "kms:ListGrants", "kms:DescribeKey"]
      Resource = aws_kms_key.eks.arn
    }]
  })
}

# ---------------- Control plane logs ----------------
# Must exist before the cluster, otherwise EKS creates it with no retention.
# CloudWatch already encrypts logs at rest with an AWS key; a customer-managed
# key would only add key-policy control. Short retention keeps cost down while learning.
#trivy:ignore:AWS-0017
resource "aws_cloudwatch_log_group" "cluster" {
  #checkov:skip=CKV_AWS_158:CloudWatch default encryption is enough for a learning cluster
  #checkov:skip=CKV_AWS_338:7-day retention on purpose (cost); raise log_retention_days for production
  name              = "/aws/eks/${var.cluster_name}/cluster"
  retention_in_days = var.log_retention_days
}

# ---------------- Cluster ----------------
# The public API endpoint stays on so kubectl works without a VPN, but only the
# CIDRs in api_allowed_cidrs can reach it (0.0.0.0/0 is rejected by the root stack).
#trivy:ignore:AWS-0040
#trivy:ignore:AWS-0041
resource "aws_eks_cluster" "this" {
  #checkov:skip=CKV_AWS_39:Public endpoint is limited to api_allowed_cidrs; private endpoint is on for nodes
  #checkov:skip=CKV_AWS_339:Checkov's version list lags EKS releases; cluster_version is checked against describe-cluster-versions
  name     = var.cluster_name
  version  = var.cluster_version
  role_arn = var.cluster_role_arn

  # Auto Mode manages the core add-ons itself; don't install the self-managed copies.
  bootstrap_self_managed_addons = false

  access_config {
    authentication_mode = "API"
    # Admins are granted explicitly below, so they're visible in Terraform.
    bootstrap_cluster_creator_admin_permissions = false
  }

  # ---- Auto Mode: these three blocks must be enabled together ----
  compute_config {
    enabled = true
    # general-purpose = your workloads; system = critical add-ons (tainted CriticalAddonsOnly)
    node_pools    = var.node_pools
    node_role_arn = var.node_role_arn
  }

  kubernetes_network_config {
    elastic_load_balancing {
      enabled = true
    }
  }

  storage_config {
    block_storage {
      enabled = true
    }
  }

  # Auto Mode launches nodes into these same (private) subnets.
  vpc_config {
    subnet_ids              = var.private_subnet_ids
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

  depends_on = [
    aws_cloudwatch_log_group.cluster,
    aws_iam_role_policy.cluster_encryption,
  ]
}

# ---------------- Cluster admins ----------------
resource "aws_eks_access_entry" "admin" {
  for_each = local.admin_principal_arns

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "admin" {
  for_each = local.admin_principal_arns

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.admin]
}

# No IAM OIDC provider (IRSA) here: pods that need AWS permissions
# (cert-manager, ExternalDNS) use EKS Pod Identity, which Auto Mode runs on
# every node. Grant them roles with aws_eks_pod_identity_association.
