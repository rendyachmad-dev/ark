# -----------------------------------------------------------------------------
# VPC — one public subnet, no NAT Gateway.
#
# NAT Gateway costs ~$33/month just for existing. The DR instance lives in a
# public subnet with a public IP instead. This is fine: it is a short-lived
# drill target, not a long-running production workload.
# -----------------------------------------------------------------------------

resource "aws_vpc" "dr" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.project}-dr-vpc"
  }
}

# Single AZ is enough — this is disaster recovery for a single VPS, not HA.
data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.dr.id
  cidr_block              = var.subnet_cidr
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.project}-dr-public"
  }
}

resource "aws_internet_gateway" "dr" {
  vpc_id = aws_vpc.dr.id

  tags = {
    Name = "${var.project}-dr-igw"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.dr.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.dr.id
  }

  tags = {
    Name = "${var.project}-dr-public-rt"
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# -----------------------------------------------------------------------------
# Security group - SSH + app ports for drill verification, nothing else.
# -----------------------------------------------------------------------------

resource "aws_security_group" "dr" {
  name        = "${var.project}-dr-sg"
  description = "Ark DR instance - SSH and app ports for drill verification"
  vpc_id      = aws_vpc.dr.id

  # SSH
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.ssh_allowed_cidrs
  }

  # Gitea web UI — drill verifies the app responds here
  ingress {
    description = "Gitea HTTP"
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = var.ssh_allowed_cidrs
  }

  # All outbound — needed to pull Docker images and read from S3
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project}-dr-sg"
  }
}
