# -----------------------------------------------------------------------------
# ECR MODULE: one private, hardened image repository.
# -----------------------------------------------------------------------------

resource "aws_ecr_repository" "this" {
  name = var.name

  # A tag (e.g. a git SHA) can only ever point at one image: nobody can quietly
  # overwrite a tag that's already running in the cluster.
  image_tag_mutability = "IMMUTABLE"

  # Refuse to delete the repo while it still holds images.
  force_delete = false

  # Free basic scan for known CVEs on every push.
  image_scanning_configuration {
    scan_on_push = true
  }

  # Encrypt images at rest with KMS (AWS-managed aws/ecr key: no monthly fee).
  # A customer-managed key (~$1/month) only adds key-policy control/auditing,
  # which a public static site doesn't need.
  #trivy:ignore:AWS-0033
  encryption_configuration {
    encryption_type = "KMS"
  }
}

# Keeps storage (and clutter) down: old images are removed automatically.
resource "aws_ecr_lifecycle_policy" "this" {
  repository = aws_ecr_repository.this.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Delete untagged images after ${var.untagged_expiry_days} days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = var.untagged_expiry_days
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep only the newest ${var.max_image_count} images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = var.max_image_count
        }
        action = { type = "expire" }
      },
    ]
  })
}
