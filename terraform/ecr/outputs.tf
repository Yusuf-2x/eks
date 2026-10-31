output "repository_url" {
  description = "Tag and push images to this, e.g. <url>:<git-sha>."
  value       = aws_ecr_repository.app.repository_url
}

output "repository_arn" {
  value = aws_ecr_repository.app.arn
}

output "docker_login" {
  description = "Log Docker in to the registry (token lasts 12 hours)."
  value       = "aws ecr get-login-password --region ${var.region} | docker login --username AWS --password-stdin ${split("/", aws_ecr_repository.app.repository_url)[0]}"
}
