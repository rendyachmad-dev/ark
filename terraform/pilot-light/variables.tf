variable "aws_region" {
  description = "Must match the backup module region so the EC2 instance can read from S3 without cross-region transfer fees."
  type        = string
  default     = "ap-southeast-1"
}

variable "project" {
  description = "Name prefix for all resources."
  type        = string
  default     = "ark"
}

variable "bucket_name" {
  description = "The S3 bucket created by the backup module. The restore IAM role needs read access to it."
  type        = string
}

variable "backup_prefix" {
  description = "Must match the prefix used by the backup module."
  type        = string
  default     = "backups/"
}

variable "instance_type" {
  description = "EC2 instance type for the DR target. t3.micro keeps costs minimal during drills."
  type        = string
  default     = "t3.micro"
}

variable "ssh_allowed_cidrs" {
  description = "CIDRs allowed to SSH into the DR instance. Restrict this to your IP."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "vpc_cidr" {
  description = "CIDR block for the pilot-light VPC."
  type        = string
  default     = "10.99.0.0/16"
}

variable "subnet_cidr" {
  description = "CIDR block for the single public subnet."
  type        = string
  default     = "10.99.1.0/24"
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default = {
    Project   = "ark"
    ManagedBy = "terraform"
  }
}
