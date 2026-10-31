# -----------------------------------------------------------------------------
# ECR stack: private registry for the app image.
# Its own stack (not part of the main one) so `terraform destroy` on the cluster
# at the end of the day never deletes your images. Costs ~$0 (a few MB stored).
# -----------------------------------------------------------------------------

module "ecr" {
  source = "../modules/ecr"

  name                 = var.repository_name
  max_image_count      = var.max_image_count
  untagged_expiry_days = var.untagged_expiry_days
}

# The repo was first created directly in this stack; these tell Terraform it
# simply moved into the module, so nothing is destroyed or recreated.
moved {
  from = aws_ecr_repository.app
  to   = module.ecr.aws_ecr_repository.this
}

moved {
  from = aws_ecr_lifecycle_policy.app
  to   = module.ecr.aws_ecr_lifecycle_policy.this
}
