output "repository_url" {
  description = "Tag and push images to this, e.g. <url>:<git-sha>."
  value       = module.ecr.repository_url
}

output "repository_arn" {
  value = module.ecr.repository_arn
}

output "docker_login" {
  description = "Log Docker in to the registry (token lasts 12 hours)."
  value       = "aws ecr get-login-password --region ${var.region} | docker login --username AWS --password-stdin ${module.ecr.registry_host}"
}
