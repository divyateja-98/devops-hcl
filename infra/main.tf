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
    helm = {
      source  = "hashicorp/helm"
      version = ">= 2.12.1"
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

provider "aws" {
  region = var.aws_region
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  token                  = data.aws_eks_cluster_auth.cluster.token

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args = [
      "eks",
      "get-token",
      "--cluster-name",
      var.cluster_name,
      "--region",
      var.aws_region
    ]
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    token                  = data.aws_eks_cluster_auth.cluster.token

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args = [
        "eks",
        "get-token",
        "--cluster-name",
        var.cluster_name,
        "--region",
        var.aws_region
      ]
    }
  }
}

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

data "aws_availability_zones" "available" {}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.1.0"

  name = "${var.cluster_name}-vpc"
  cidr = var.vpc_cidr

  azs = slice(
    data.aws_availability_zones.available.names,
    0,
    min(3, length(data.aws_availability_zones.available.names))
  )

  public_subnets  = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  private_subnets = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = true

  tags = {
    Name = "${var.cluster_name}-vpc"
  }
}

resource "aws_security_group" "all_worker_mgmt" {
  name        = "${var.cluster_name}-worker-sg"
  description = "Security group for EKS managed worker nodes"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
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

  cluster_endpoint_public_access  = true
  cluster_endpoint_private_access = true

  cluster_timeouts = {
    create = "60m"
    update = "60m"
    delete = "60m"
  }
}

data "aws_eks_cluster_auth" "cluster" {
  depends_on = [module.eks]
  name       = var.cluster_name
}

# Resource to wait for EKS API server to be ready and reachable
resource "null_resource" "eks_api_ready" {
  depends_on = [module.eks]

  triggers = {
    always_run = timestamp()
  }

  provisioner "local-exec" {
    command = <<-EOT
      # Wait for cluster to be active
      echo "Waiting for EKS cluster to become active..."
      aws eks wait cluster-active --name ${var.cluster_name} --region ${var.aws_region} || exit 1
      
      # Update kubeconfig
      echo "Updating kubeconfig..."
      aws eks update-kubeconfig --name ${var.cluster_name} --region ${var.aws_region} || exit 1
      
      # Wait for nodes to be ready
      echo "Waiting for at least 2 nodes to be ready..."
      MAX_RETRIES=30
      RETRY_COUNT=0
      RETRY_INTERVAL=10
      
      while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
        READY_NODES=$(kubectl get nodes --no-headers 2>/dev/null | grep " Ready" | wc -l)
        if [ "$READY_NODES" -ge 2 ]; then
          echo "Found $READY_NODES nodes ready"
          break
        fi
        echo "Only $READY_NODES nodes ready. Retrying in ${RETRY_INTERVAL}s... (Attempt $((RETRY_COUNT+1))/$MAX_RETRIES)"
        sleep $RETRY_INTERVAL
        RETRY_COUNT=$((RETRY_COUNT+1))
      done
      
      if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
        echo "Timed out waiting for nodes to be ready"
        exit 1
      fi
      
      # Verify API access
      echo "Verifying API access..."
      kubectl cluster-info || exit 1
      echo "EKS cluster is ready!"
    EOT
    interpreter = ["bash", "-c"]
  }
}

# --- NGINX Application Deployment ---
resource "kubernetes_deployment" "nginx_app" {
  depends_on = [null_resource.eks_api_ready]
  
  metadata {
    name = "nginx-deployment"
    labels = {
      app = "nginx"
    }
  }
  spec {
    replicas = 2
    selector {
      match_labels = {
        app = "nginx"
      }
    }
    template {
      metadata {
        labels = {
          app = "nginx"
        }
      }
      spec {
        container {
          name  = "nginx"
          image = "nginx:latest"
          port {
            container_port = 80
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "nginx_service" {
  depends_on = [kubernetes_deployment.nginx_app]
  
  metadata {
    name = "nginx-service"
    labels = {
      app = "nginx"
    }
  }
  spec {
    selector = {
      app = "nginx"
    }
    port {
      port        = 80
      target_port = 80
      node_port   = 30080
    }
    type = "NodePort"
  }
}

# --- ArgoCD Installation using Helm ---
resource "kubernetes_namespace" "argocd" {
  depends_on = [null_resource.eks_api_ready]
  
  metadata {
    name = "argocd"
  }
}

resource "helm_release" "argocd" {
  depends_on = [kubernetes_namespace.argocd]
  
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = "5.46.8"
  namespace  = "argocd"
  
  set {
    name  = "server.service.type"
    value = "LoadBalancer"
  }
  
  set {
    name  = "server.ingress.enabled"
    value = "true"
  }
  
  set {
    name  = "server.ingress.hosts[0]"
    value = "argocd.${var.cluster_name}.example.com"
  }
  
  wait = true
  timeout = 600
}

# ArgoCD Application resource for NGINX
resource "kubernetes_manifest" "nginx_argocd_app" {
  depends_on = [helm_release.argocd]
  
  manifest = {
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = "nginx-application"
      namespace = "argocd"
    }
    spec = {
      project = "default"
      source = {
        repoURL        = "https://github.com/YOUR_GITHUB_USER/YOUR_NGINX_REPO.git"
        targetRevision = "HEAD"
        path           = "kubernetes-manifests"
      }
      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = "default"
      }
      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
        }
      }
    }
  }
}

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
  value       = (
    module.eks.cluster_id != "" && module.eks.cluster_id != null ?
    format("aws eks update-kubeconfig --name %s --region %s", var.cluster_name, var.aws_region) :
    "Cluster not created yet"
  )
}

output "nat_gateway_eip_address" {
  description = "The Elastic IP address allocated for the NAT Gateway."
  value       = module.vpc.nat_public_ips[0]
}

output "nginx_access_instructions" {
  description = "Instructions to access the NGINX application."
  value = <<-EOT
    To access the NGINX application:
    1. Run the command from 'zz_update_kubeconfig_command' output to configure kubectl
    2. Get the Node IP: kubectl get nodes -o wide
    3. Access NGINX via NodePort: http://<NODE_IP>:30080
    4. Alternatively, use kubectl port-forward:
       kubectl port-forward svc/nginx-service 8080:80
       Then access at: http://localhost:8080
  EOT
}

output "argocd_access_instructions" {
  description = "Instructions to access the ArgoCD UI."
  value = <<-EOT
    To access the ArgoCD UI:
    1. Run the command from 'zz_update_kubeconfig_command' output to configure kubectl
    2. Get the ArgoCD server LoadBalancer hostname:
       kubectl get svc argocd-server -n argocd -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
    3. Access the UI at: https://<ARGOCD_LOADBALANCER_HOSTNAME>
    4. Get the initial admin password:
       kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
    5. Login with username 'admin' and the retrieved password
  EOT
}