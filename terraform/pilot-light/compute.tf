# -----------------------------------------------------------------------------
# AMI — latest Ubuntu 24.04 LTS, matching the VPS.
# -----------------------------------------------------------------------------

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# -----------------------------------------------------------------------------
# SSH key pair — public key injected via tfvars or at drill time.
# Using a placeholder; real key set before first drill.
# -----------------------------------------------------------------------------

resource "aws_key_pair" "dr" {
  key_name   = "${var.project}-dr-key"
  public_key = var.ssh_public_key

  tags = {
    Name = "${var.project}-dr-key"
  }
}

# -----------------------------------------------------------------------------
# IAM role — lets the EC2 instance read backups from S3 without baking
# credentials into the image. No write, no delete.
# -----------------------------------------------------------------------------

resource "aws_iam_role" "dr_instance" {
  name = "${var.project}-dr-instance-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy" "dr_read_backups" {
  name = "${var.project}-dr-read-backups"
  role = aws_iam_role.dr_instance.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ListBucket"
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:GetBucketLocation"
        ]
        Resource = "arn:aws:s3:::${var.bucket_name}"
        Condition = {
          StringLike = {
            "s3:prefix" = ["${var.backup_prefix}*"]
          }
        }
      },
      {
        Sid    = "ReadObjects"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:GetObjectVersion"
        ]
        Resource = "arn:aws:s3:::${var.bucket_name}/${var.backup_prefix}*"
      },
      {
        Sid    = "RestoreFromGlacier"
        Effect = "Allow"
        Action = "s3:RestoreObject"
        Resource = "arn:aws:s3:::${var.bucket_name}/${var.backup_prefix}*"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "dr" {
  name = "${var.project}-dr-instance-profile"
  role = aws_iam_role.dr_instance.name
}

# -----------------------------------------------------------------------------
# Launch template — everything the drill needs to spin up an instance.
#
# The template itself is free. EC2 charges start only when the drill CLI
# calls run-instances. The drill destroys the instance when done.
# -----------------------------------------------------------------------------

resource "aws_launch_template" "dr" {
  name          = "${var.project}-dr-template"
  image_id      = data.aws_ami.ubuntu.id
  instance_type = var.instance_type
  key_name      = aws_key_pair.dr.key_name

  iam_instance_profile {
    arn = aws_iam_instance_profile.dr.arn
  }

  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [aws_security_group.dr.id]
    subnet_id                   = aws_subnet.public.id
  }

  # User data installs Docker and the AWS CLI on first boot so the restore
  # playbook can run immediately without manual setup.
  user_data = base64encode(<<-USERDATA
    #!/bin/bash
    set -euo pipefail

    # Docker
    apt-get update -qq
    apt-get install -y -qq ca-certificates curl
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" > /etc/apt/sources.list.d/docker.list
    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin

    # AWS CLI v2
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
    cd /tmp && unzip -qq awscliv2.zip && ./aws/install

    # Signal that the instance is ready for the restore playbook
    touch /tmp/ark-dr-ready
  USERDATA
  )

  tag_specifications {
    resource_type = "instance"

    tags = {
      Name = "${var.project}-dr-instance"
    }
  }

  tag_specifications {
    resource_type = "volume"

    tags = {
      Name = "${var.project}-dr-volume"
    }
  }
}
