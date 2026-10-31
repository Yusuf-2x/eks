locals {
  cluster_name = "${var.project_name}-cluster"
}

module "vpc" {
  source = "./modules/vpc"

  name               = var.project_name
  cluster_name       = local.cluster_name
  cidr_block         = var.vpc_cidr
  az_count           = var.az_count
  single_nat_gateway = var.single_nat_gateway
}

module "iam" {
  source = "./modules/iam"

  name = var.project_name
}

module "eks" {
  source = "./modules/eks"

  cluster_name    = local.cluster_name
  cluster_version = var.cluster_version

  private_subnet_ids = module.vpc.private_subnet_ids

  cluster_role_arn  = module.iam.cluster_role_arn
  cluster_role_name = module.iam.cluster_role_name
  node_role_arn     = module.iam.node_role_arn
  node_pools        = var.node_pools

  api_allowed_cidrs  = var.api_allowed_cidrs
  cluster_admin_arns = var.cluster_admin_arns

  # No module-level depends_on: it would defer the module's data sources to
  # apply time. Ordering comes from the iam/vpc outputs instead, which wait for
  # the policy attachments and NAT routes (see their outputs.tf).
}

module "addons" {
  source = "./modules/addons"

  # Comes from the cluster (and waits for the admin access entries, see
  # modules/eks/outputs.tf), so every add-on is installed after it and
  # uninstalled before it.
  cluster_name = module.eks.cluster_name
  region       = var.region
  domain_name  = var.domain_name

  app_name        = "eks-2048"
  app_namespace   = "game-2048"
  gitops_repo_url = var.gitops_repo_url
  gitops_revision = var.gitops_revision
  gitops_path     = "k8s"
}
