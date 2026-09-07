variable "aws_region" {
  description = "Region for the backup bucket. Pick one close to your VPS to cut transfer time."
  type        = string
  default     = "ap-southeast-1"
}

variable "project" {
  description = "Name prefix for all resources."
  type        = string
  default     = "ark"
}

variable "bucket_name" {
  description = "Globally unique bucket name. S3 bucket names are shared across every AWS account on earth, so add something specific."
  type        = string
}

variable "backup_prefix" {
  description = "Key prefix the backup identity is allowed to write to. Scoping the IAM policy to this prefix is what makes it least-privilege."
  type        = string
  default     = "backups/"
}

variable "transition_to_ia_days" {
  description = "Days before objects move to Standard-IA. Minimum billable duration is 30 days."
  type        = number
  default     = 30
}

variable "transition_to_glacier_days" {
  description = "Days before objects move to Glacier Flexible Retrieval."
  type        = number
  default     = 90
}

variable "expiration_days" {
  description = "Days before objects are deleted entirely. Set to 0 to keep forever."
  type        = number
  default     = 365
}

variable "noncurrent_version_expiration_days" {
  description = "Days to keep old versions after they are superseded. Versioning protects against a corrupted backup overwriting a good one."
  type        = number
  default     = 30
}

variable "tags" {
  description = "Tags applied to every resource. Useful for cost allocation later."
  type        = map(string)
  default = {
    Project   = "ark"
    ManagedBy = "terraform"
  }
}
