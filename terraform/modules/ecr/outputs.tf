output "repository_url" {
  value = aws_ecr_repository.this.repository_url
}

output "repository_arn" {
  value = aws_ecr_repository.this.arn
}

output "registry_host" {
  description = "<account>.dkr.ecr.<region>.amazonaws.com — what docker login needs."
  value       = split("/", aws_ecr_repository.this.repository_url)[0]
}
