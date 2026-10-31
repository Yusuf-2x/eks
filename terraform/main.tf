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

  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids

  cluster_role_arn  = module.iam.cluster_role_arn
  node_role_arn     = module.iam.node_role_arn
  api_allowed_cidrs = var.api_allowed_cidrs

  node_instance_types = var.node_instance_types
  node_capacity_type  = var.node_capacity_type
  node_min_size       = var.node_min_size
  node_desired_size   = var.node_desired_size
  node_max_size       = var.node_max_size

  # IAM policies must be attached before the cluster/nodes are created,
  # and must stay attached until they are fully deleted.
  depends_on = [module.iam]
}
