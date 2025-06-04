terraform {
  required_version = ">= 1.3.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 4.0"
    }
  }
}

provider "aws" {
  region = "us-west-1"
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = ">= 3.17"

  name = "eks-vpc"
  cidr = "10.0.0.0/16"

  azs             = ["us-west-1a", "us-west-1b", "us-west-1c"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = true

  tags = {
    "Name" = "eks-vpc"
  }
}

module "eks" {
  source          = "terraform-aws-modules/eks/aws"
  version         = ">= 17.1.0, < 18.0.0"

  cluster_name    = "my-eks-cluster"
  cluster_version = "1.27"

  subnet_ids      = module.vpc.private_subnets
  vpc_id          = module.vpc.vpc_id

  manage_aws_auth = true

  node_groups = {
    default = {
      desired_capacity = 2
      max_capacity     = 3
      min_capacity     = 1
      instance_types   = ["t3.medium"]
      disk_size        = 20
    }
  }

  tags = {
    Environment = "production"
    Terraform   = "true"
  }
}

output "kubeconfig" {
  value     = module.eks.kubeconfig
  sensitive = true
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "cluster_ca_certificate" {
  value = module.eks.cluster_certificate_authority_data
}
