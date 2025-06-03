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
    time = {
      source  = "hashicorp/time"
      version = ">= 0.7.0"
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

# The Kubernetes provider configuration is crucial here.
provider "kubernetes" {
  # Use the actual cluster endpoint, which should be the public one if configured.
  # Ensure the data.aws_eks_cluster output is available before this provider is configured.
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  
  # Option 1 (prefer this if it works): Use direct token from data source
  token = data.aws_eks_cluster_auth.cluster.token

  # Option 2 (more robust for authentication, uncomment if Option 1 fails AFTER connectivity is resolved):
  # exec {
  #   api_version = "client.authentication.k8s.io/v1beta1"
  #   command     = "aws"
  #   args        = ["eks", "get-token", "--cluster-name", var.cluster_name, "--region", var.aws_region]
  # }

  # Increased timeout for the Kubernetes provider itself
  # This makes the provider wait longer for API responses
  # Set to a higher value to give it ample time
  timeout = "10m" # Increase from default (usually 5m)

  # ONLY FOR DEBUGGING TLS ISSUES - DO NOT USE IN PRODUCTION
  # insecure_skip_tls_verify = true
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

  # Ensure both public and private access are enabled
  cluster_endpoint_public_access  = true
  cluster_endpoint_private_access = true

  # Pass timeouts to the underlying aws_eks_cluster resource using 'cluster_timeouts'
  cluster_timeouts = {
    create = "60m"
    update = "60m"
    delete = "60m"
  }
}

data "aws_eks_cluster_auth" "cluster" {
  depends_on = [module.eks] # This ensures EKS cluster creation completes first
  name       = var.cluster_name
}

# Add a time_sleep to allow the EKS API server to fully stabilize after creation
# This is crucial for initial Kubernetes provider connection.
resource "time_sleep" "wait_for_eks_api_stability" {
  depends_on      = [module.eks] # Depends on the EKS module completing its creation
  create_duration = "300s"       # **INCREASED:** Try 5 minutes (300 seconds)
                                 # If still failing, increase to 420s (7 min) or 600s (10 min)
}

# This null_resource now acts as a robust check and a hard dependency
resource "null_resource" "eks_api_ready" {
  depends_on = [module.eks, time_sleep.wait_for_eks_api_stability] # Ensures EKS is created AND sleep completes

  provisioner "local-exec" {
    command = <<-EOT
      echo "Waiting for EKS cluster '${data.aws_eks_cluster_auth.cluster.name}' to be active..."
      # Use aws eks wait cluster-active for a robust wait
      # This waits until the EKS cluster state is 'ACTIVE'
      aws eks wait cluster-active --name ${data.aws_eks_cluster_auth.cluster.name} --region ${var.aws_region}

      echo "EKS cluster is active. Updating kubeconfig..."
      KUBECONFIG_PATH="/tmp/kubeconfig-${var.cluster_name}"
      aws eks update-kubeconfig --name ${data.aws_eks_cluster_auth.cluster.name} --region ${var.aws_region} --kubeconfig $KUBECONFIG_PATH --alias ${var.cluster_name}-tf-managed

      echo "Verifying kubectl access using the specific kubeconfig and context..."
      RETRY_COUNT=0
      MAX_RETRIES=20 # Increased retries
      RETRY_INTERVAL=15 # Increased interval to 15 seconds
      while ! kubectl --kubeconfig $KUBECONFIG_PATH --context ${var.cluster_name}-tf-managed get ns &> /dev/null && [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
        echo "kubectl access failed. Retrying in ${RETRY_INTERVAL}s... (Attempt $((RETRY_COUNT+1))/$MAX_RETRIES)"
        sleep $RETRY_INTERVAL
        RETRY_COUNT=$((RETRY_COUNT+1))
      done

      if kubectl --kubeconfig $KUBECONFIG_PATH --context ${var.cluster_name}-tf-managed get ns &> /dev/null; then
        echo "kubectl access confirmed after $((RETRY_COUNT)) retries."
        exit 0
      else
        echo "kubectl access still failed after $MAX_RETRIES attempts. This indicates a persistent connectivity issue to the EKS API."
        echo "Possible reasons: Network ACLs, Security Groups, DNS resolution, or EKS control plane not fully healthy."
        exit 1
      fi
    EOT
    interpreter = ["bash", "-c"]
  }
}

# --- NGINX Application Deployment ---
resource "kubernetes_deployment" "nginx_app" {
  depends_on = [null_resource.eks_api_ready] # Explicitly depend on this check
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
  depends_on = [kubernetes_deployment.nginx_app] # This is sufficient if kubernetes_deployment depends correctly
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

# --- ArgoCD Installation ---
resource "kubernetes_namespace" "argocd" {
  depends_on = [null_resource.eks_api_ready] # Explicitly depend on this check
  metadata {
    name = "argocd"
  }
}

locals {
  argocd_install_yaml = base64encode(<<-EOT
apiVersion: v1
kind: Namespace
metadata:
  labels:
    argocd.argoproj.io/secret-type: cluster
  name: argocd
---
apiVersion: v1
kind: ServiceAccount
metadata:
  labels:
    app.kubernetes.io/component: server
    app.kubernetes.io/name: argocd-server
    app.kubernetes.io/part-of: argocd
  name: argocd-server
  namespace: argocd
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  labels:
    app.kubernetes.io/component: server
    app.kubernetes.io/name: argocd-server
    app.kubernetes.io/part-of: argocd
  name: argocd-server
  namespace: argocd
rules:
- apiGroups:
  - ""
  resources:
  - pods
  - pods/exec
  verbs:
  - create
  - get
  - list
  - watch
  - update
  - patch
  - delete
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  labels:
    app.kubernetes.io/component: server
    app.kubernetes.io/name: argocd-server
    app.kubernetes.io/part-of: argocd
  name: argocd-server
  namespace: argocd
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: argocd-server
subjects:
- kind: ServiceAccount
  name: argocd-server
  namespace: argocd
---
apiVersion: apps/v1
kind: Deployment
metadata:
  labels:
    app.kubernetes.io/component: server
    app.kubernetes.io/name: argocd-server
    app.kubernetes.io/part-of: argocd
  name: argocd-server
  namespace: argocd
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: argocd-server
  template:
    metadata:
      labels:
        app.kubernetes.io/name: argocd-server
    spec:
      serviceAccountName: argocd-server
      containers:
      - name: argocd-server
        image: argoproj/argocd:v2.10.0
        ports:
        - containerPort: 8080
        - containerPort: 443
---
apiVersion: v1
kind: Service
metadata:
  labels:
    app.kubernetes.io/component: server
    app.kubernetes.io/name: argocd-server
    app.kubernetes.io/part-of: argocd
  name: argocd-server
  namespace: argocd
spec:
  selector:
    app.kubernetes.io/name: argocd-server
  ports:
  - name: http
    port: 80
    targetPort: 8080
  - name: https
    port: 443
    targetPort: 443
  type: ClusterIP
EOT
)

  argocd_manifests = [
    for doc_str in split("---", base64decode(local.argocd_install_yaml)) :
    yamldecode(doc_str) if trimspace(doc_str) != ""
  ]
}

resource "kubernetes_manifest" "argocd_install" {
  depends_on = [kubernetes_namespace.argocd, null_resource.eks_api_ready]
  for_each   = { for i, manifest in local.argocd_manifests : "${lookup(manifest, "kind", "unknown")}-${lookup(manifest.metadata, "name", "unknown")}-${i}" => manifest }
  manifest   = each.value
}

resource "null_resource" "patch_argocd_server_service" {
  depends_on = [kubernetes_manifest.argocd_install, null_resource.eks_api_ready]

  provisioner "local-exec" {
    command = "kubectl patch svc argocd-server -n argocd -p '{\"spec\": {\"type\": \"LoadBalancer\"}}' --context ${var.cluster_name}-tf-managed"
    interpreter = ["bash", "-c"]
  }
}

resource "kubernetes_manifest" "nginx_argocd_app" {
  depends_on = [null_resource.patch_argocd_server_service, null_resource.eks_api_ready]

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
    format("aws eks update-kubeconfig --name %s --region %s --kubeconfig /tmp/kubeconfig-%s --alias %s-tf-managed", var.cluster_name, var.aws_region, var.cluster_name, var.cluster_name) :
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
    1. Get the Node IP: kubectl get nodes -o wide --kubeconfig /tmp/kubeconfig-${var.cluster_name} --context ${var.cluster_name}-tf-managed
    2. Access NGINX via NodePort: http://<NODE_IP>:${kubernetes_service.nginx_service.spec[0].port[0].node_port}
    3. Alternatively, use kubectl port-forward:
       kubectl port-forward svc/nginx-service 8080:80 --kubeconfig /tmp/kubeconfig-${var.cluster_name} --context ${var.cluster_name}-tf-managed
       Then access at: http://localhost:8080
  EOT
}

output "argocd_access_instructions" {
  description = "Instructions to access the ArgoCD UI."
  value = <<-EOT
    To access the ArgoCD UI:
    1. Get the ArgoCD server LoadBalancer IP:
       kubectl get svc argocd-server -n argocd -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' --kubeconfig /tmp/kubeconfig-${var.cluster_name} --context ${var.cluster_name}-tf-managed || kubectl get svc argocd-server -n argocd -o jsonpath='{.status.loadBalancer.ingress[0].ip}' --kubeconfig /tmp/kubeconfig-${var.cluster_name} --context ${var.cluster_name}-tf-managed
    2. Access the UI at: https://<ARGOCD_LOADBALANCER_IP>
    3. Get the initial admin password:
       kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" --kubeconfig /tmp/kubeconfig-${var.cluster_name} --context ${var.cluster_name}-tf-managed | base64 -d
    4. Login with username 'admin' and the retrieved password.
  EOT
}