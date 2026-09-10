variable "region" {
  description = "AWS region for the deployment"
  type        = string
  default     = "eu-west-2"
}

variable "vpc_cidr" {
  description = "CIDR block for the isolated VPC"
  type        = string
  default     = "10.42.0.0/16"
}

variable "private_subnet_cidr" {
  description = "CIDR block for the private subnet holding the GPU instance"
  type        = string
  default     = "10.42.1.0/24"
}

variable "allowed_ingress_cidrs" {
  description = "CIDRs allowed to reach the chat UI (443) — customer VPN/Direct Connect ranges only, never 0.0.0.0/0"
  type        = list(string)
}

variable "instance_type" {
  description = "GPU instance type. g5.xlarge (A10G 24GB) fits an 8B model comfortably; step up to g5.2xlarge/g6e for higher concurrency"
  type        = string
  default     = "g5.xlarge"
}

variable "key_name" {
  description = "Existing EC2 key pair name for break-glass access (day-to-day access should go through SSM instead)"
  type        = string
  default     = null
}

variable "model_bundle_bucket" {
  description = "Name of the S3 bucket holding staged model weights / compose files, reachable only via the VPC endpoint"
  type        = string
}

variable "root_volume_size_gb" {
  description = "Root EBS volume size — model weights + container images add up fast"
  type        = number
  default     = 200
}

variable "tags" {
  description = "Common resource tags"
  type        = map(string)
  default = {
    Project = "airgapped-llm"
  }
}
