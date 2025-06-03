# Terraform backend and provider configurations
terraform {
  required_version = ">= 0.12"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 3.68.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.7.1"
    }
  }

  backend "s3" {
    bucket         = "my-terraform-state-bucket-1-us-west-1"
    key            = "eks-cluster/terraform.tfstate"
    region         = "us-west-1"
    encrypt        = true
    dynamodb_table = "terraform-locks"
  }
}

# AWS Provider Configuration
provider "aws" {
  region = var.aws_region
}

# Kubernetes provider for accessing the EKS cluster after it's created
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = module.eks.cluster_certificate_authority_data
  token                  = data.aws_eks_cluster_auth.cluster.token
}

# Variables for flexibility
variable "aws_region" {
  default = "us-west-1"
}

variable "kubernetes_version" {
  default = "1.27"
}

variable "cluster_name" {
  default = "my-cluster"
}

variable "vpc_cidr" {
  default = "10.0.0.0/16"
}

# Fetch available AZs
data "aws_availability_zones" "available" {}

# VPC Module Configuration
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.1.0"

  name = "${var.cluster_name}-vpc"
  cidr = var.vpc_cidr

  azs             = slice(data.aws_availability_zones.available.names, 0, 3)
  public_subnets  = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  private_subnets = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = true

  tags = {
    Name = "${var.cluster_name}-vpc"
  }
}

# Define the security group for EKS managed worker nodes (needed by the EKS module)
resource "aws_security_group" "all_worker_mgmt" {
  name        = "${var.cluster_name}-worker-sg"
  description = "Security group for EKS managed worker nodes"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]  # Consider tightening this for production
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.cluster_name}-worker-sg"
  }
}

# EKS Cluster Setup
module "eks" {
  source          = "terraform-aws-modules/eks/aws"
  version         = "20.8.4"
  cluster_name    = var.cluster_name
  cluster_version = var.kubernetes_version
  subnet_ids      = module.vpc.private_subnets

  enable_irsa = true

  vpc_id = module.vpc.vpc_id

  eks_managed_node_group_defaults = {
    ami_type               = "AL2_x86_64"
    instance_types         = ["t3.medium"]
    vpc_security_group_ids = [aws_security_group.all_worker_mgmt.id]
  }

  eks_managed_node_groups = {
    node_group = {
      min_size     = 2
      max_size     = 6
      desired_size = 2
    }
  }

  tags = {
    cluster = "demo"
  }
}

# Data source for EKS cluster auth token (needed by kubernetes provider)
data "aws_eks_cluster_auth" "cluster" {
  name = module.eks.cluster_id
}

# Outputs
output "cluster_id" {
  description = "EKS cluster ID."
  value       = module.eks.cluster_id
}

output "cluster_endpoint" {
  description = "Endpoint for EKS control plane."
  value       = module.eks.cluster_endpoint
}

output "cluster_security_group_id" {
  description = "Security group IDs attached to the cluster control plane."
  value       = module.eks.cluster_security_group_id
}

output "region" {
  description = "AWS region"
  value       = var.aws_region
}

output "oidc_provider_arn" {
  value = module.eks.oidc_provider_arn
}

output "zz_update_kubeconfig_command" {
  description = "Command to update kubeconfig for the cluster"
  value       = format("aws eks update-kubeconfig --name %s --region %s", module.eks.cluster_id, var.aws_region)
}
