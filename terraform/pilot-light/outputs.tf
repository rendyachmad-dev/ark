output "vpc_id" {
  description = "VPC ID for the DR environment."
  value       = aws_vpc.dr.id
}

output "subnet_id" {
  description = "Public subnet where the DR instance launches."
  value       = aws_subnet.public.id
}

output "security_group_id" {
  description = "Security group attached to the DR instance."
  value       = aws_security_group.dr.id
}

output "launch_template_id" {
  description = "Launch template ID — pass this to 'aws ec2 run-instances --launch-template'."
  value       = aws_launch_template.dr.id
}

output "launch_template_latest_version" {
  description = "Latest version of the launch template."
  value       = aws_launch_template.dr.latest_version
}

output "instance_profile_arn" {
  description = "IAM instance profile ARN for the DR instance."
  value       = aws_iam_instance_profile.dr.arn
}

output "ami_id" {
  description = "Ubuntu 24.04 AMI used by the launch template."
  value       = data.aws_ami.ubuntu.id
}

output "account_id" {
  value = data.aws_caller_identity.current.account_id
}

output "aws_region" {
  value = var.aws_region
}
