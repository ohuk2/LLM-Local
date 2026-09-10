terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region
}

data "aws_availability_zones" "available" {
  state = "available"
}

# ---------------------------------------------------------------------------
# Network — private subnet only, no internet gateway, no NAT gateway.
# All AWS API traffic (S3, ECR, SSM, logs) goes over VPC endpoints instead.
# ---------------------------------------------------------------------------

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = merge(var.tags, { Name = "airgapped-llm-vpc" })
}

resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = var.private_subnet_cidr
  availability_zone = data.aws_availability_zones.available.names[0]
  tags              = merge(var.tags, { Name = "airgapped-llm-private" })
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "airgapped-llm-private-rt" })
  # Intentionally no routes to an internet or NAT gateway.
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

# ---------------------------------------------------------------------------
# Security groups
# ---------------------------------------------------------------------------

resource "aws_security_group" "endpoints" {
  name_prefix = "airgapped-llm-endpoints-"
  vpc_id      = aws_vpc.this.id
  tags        = var.tags

  ingress {
    description = "HTTPS from within the VPC to interface endpoints"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"] # endpoint ENIs only route within the VPC regardless
  }
}

resource "aws_security_group" "llm_host" {
  name_prefix = "airgapped-llm-host-"
  vpc_id      = aws_vpc.this.id
  tags        = var.tags

  ingress {
    description = "Chat UI (Caddy/HTTPS) from customer VPN or on-site network only"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = var.allowed_ingress_cidrs
  }

  egress {
    description = "Restricted to VPC endpoints and internal traffic — no route to the internet exists anyway"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
  }
}

# ---------------------------------------------------------------------------
# VPC endpoints — the only way this subnet reaches AWS APIs
# ---------------------------------------------------------------------------

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]
  tags              = merge(var.tags, { Name = "airgapped-llm-s3" })
}

locals {
  interface_endpoints = ["ecr.api", "ecr.dkr", "ssm", "ssmmessages", "ec2messages", "logs"]
}

resource "aws_vpc_endpoint" "interface" {
  for_each            = toset(local.interface_endpoints)
  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${var.region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.private.id]
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true
  tags                = merge(var.tags, { Name = "airgapped-llm-${each.value}" })
}

resource "aws_s3_bucket_policy" "model_bundle" {
  bucket = var.model_bundle_bucket
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "RestrictToVpcEndpoint"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource = [
        "arn:aws:s3:::${var.model_bundle_bucket}",
        "arn:aws:s3:::${var.model_bundle_bucket}/*",
      ]
      Condition = {
        StringNotEquals = {
          "aws:sourceVpce" = aws_vpc_endpoint.s3.id
        }
      }
    }]
  })
}

# ---------------------------------------------------------------------------
# IAM — instance role scoped to the model bucket, SSM, and ECR read-only
# ---------------------------------------------------------------------------

resource "aws_iam_role" "llm_host" {
  name_prefix = "airgapped-llm-host-"
  tags        = var.tags
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.llm_host.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "ecr_read" {
  role       = aws_iam_role.llm_host.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy" "model_bucket_read" {
  name_prefix = "model-bucket-read-"
  role        = aws_iam_role.llm_host.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:GetObject", "s3:ListBucket"]
      Resource = [
        "arn:aws:s3:::${var.model_bundle_bucket}",
        "arn:aws:s3:::${var.model_bundle_bucket}/*",
      ]
    }]
  })
}

resource "aws_iam_instance_profile" "llm_host" {
  name_prefix = "airgapped-llm-host-"
  role        = aws_iam_role.llm_host.name
}

# ---------------------------------------------------------------------------
# GPU instance
# ---------------------------------------------------------------------------

data "aws_ami" "dlami" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["Deep Learning Base OSS Nvidia Driver GPU AMI (Ubuntu 24.04)*"]
  }
}

resource "aws_instance" "llm_host" {
  ami                    = data.aws_ami.dlami.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.private.id
  vpc_security_group_ids = [aws_security_group.llm_host.id]
  iam_instance_profile   = aws_iam_instance_profile.llm_host.name
  key_name               = var.key_name
  # No public IP — the subnet has no internet/NAT route regardless.
  associate_public_ip_address = false

  root_block_device {
    volume_size = var.root_volume_size_gb
    volume_type = "gp3"
    encrypted   = true
  }

  user_data = templatefile("${path.module}/user_data.sh.tpl", {
    model_bundle_bucket = var.model_bundle_bucket
  })

  tags = merge(var.tags, { Name = "airgapped-llm-host" })
}
