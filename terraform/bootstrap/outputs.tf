output "state_bucket" {
  description = "Put this in terraform/backend.hcl as `bucket`."
  value       = aws_s3_bucket.state.bucket
}

output "lock_table" {
  description = "Put this in terraform/backend.hcl as `dynamodb_table`."
  value       = aws_dynamodb_table.lock.name
}

output "region" {
  value = var.region
}
