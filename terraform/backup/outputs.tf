output "bucket_name" {
  description = "Backup bucket name. Goes into the Ansible role as ark_s3_bucket."
  value       = aws_s3_bucket.backups.id
}

output "bucket_arn" {
  value = aws_s3_bucket.backups.arn
}

output "backup_prefix" {
  value = var.backup_prefix
}

output "aws_region" {
  value = var.aws_region
}

output "access_key_id" {
  description = "Access key for the backup agent."
  value       = aws_iam_access_key.backup_agent.id
}

output "secret_access_key" {
  description = "Secret key for the backup agent. Retrieve with: terraform output -raw secret_access_key"
  value       = aws_iam_access_key.backup_agent.secret
  sensitive   = true
}

output "account_id" {
  value = data.aws_caller_identity.current.account_id
}
