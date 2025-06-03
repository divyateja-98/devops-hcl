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

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  token                  = data.aws_eks_cluster_auth.cluster.token
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

  name = "<span class="math-inline">\{var\.cluster\_name\}\-vpc"
cidr \= var\.vpc\_cidr
azs \= slice\(
data\.aws\_availability\_zones\.available\.names,
0,
min\(3, length\(data\.aws\_availability\_zones\.available\.names\)\)
\)
public\_subnets  \= \["10\.0\.1\.0/24", "10\.0\.2\.0/24", "10\.0\.3\.0/24"\]
private\_subnets \= \["10\.0\.101\.0/24", "10\.0\.102\.0/24", "10\.0\.103\.0/24"\]
enable\_nat\_gateway \= true
single\_nat\_gateway \= true
tags \= \{
Name \= "</span>{var.cluster_name}-vpc"
  }
}

resource "aws_security_group" "all_worker_mgmt" {
  name        = "<span class="math-inline">\{var\.cluster\_name\}\-worker\-sg"
description \= "Security group for EKS managed worker nodes"
<106\>vpc\_id      \= module\.vpc\.vpc\_id
ingress \{
from\_port   \= 0
to\_port     \= 0
protocol    \= "\-1"
cidr\_blocks \= \["0\.0\.0\.0/0"\]
\}
egress \{
from\_port   \= 0
to\_port     \= 0
protocol    \= "\-1"</106\>
cidr\_blocks \= \["0\.0\.0\.0/0"\]
\}
tags \= \{
Name \= "</span>{var.cluster_name}-worker-sg"
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

resource "time_sleep" "wait_for_eks_api_stability" {
  depends_on      = [module.eks]
  create_duration = "300s" # Keep at 5 minutes, or increase if necessary
}

resource "null_resource" "eks_api_ready" {
  depends_on = [module.eks, time_sleep.wait_for_eks_api_stability]

  provisioner "local-exec" {
    # Define shell variables as environment variables for the local-exec command.
    # Terraform interpolates these once, and then they are available in the shell.
    environment = {
      MAX_RETRIES         = 20
      RETRY_INTERVAL      = 15
      CLUSTER_NAME        = var.cluster_name
      AWS_REGION          = var.aws_region
      KUBECONFIG_PATH     = "/tmp/kubeconfig-<span class="math-inline">\{var\.cluster\_name\}"
CLUSTER\_ENDPOINT\_NAME \= data\.aws\_eks\_cluster\_auth\.cluster\.name \# Pass this as well
\}
command \= <<\-EOT
echo "Waiting for EKS cluster '</span>{CLUSTER_ENDPOINT_NAME}' to be active..."
      aws eks wait cluster-active --name "<span class="math-inline">\{CLUSTER\_ENDPOINT\_NAME\}" \-\-region "</span>{AWS_REGION}"

      echo "EKS cluster is active. Updating kubeconfig..."
      aws eks update-kubeconfig --name "<span class="math-inline">\{CLUSTER\_ENDPOINT\_NAME\}" \-\-region "</span>{AWS_REGION}" --kubeconfig "<span class="math-inline">\{KUBECONFIG\_PATH\}" \-\-alias "</span>{CLUSTER_NAME}-tf-managed"

      echo "Verifying kubectl access using the specific kubeconfig and context..."
      
      # Now, these variables are available directly from the environment.
      # Use standard shell variable syntax ($VAR or <span class="math-inline">\{VAR\}\)\.
CURRENT\_RETRY\_COUNT\=0
while \! kubectl \-\-kubeconfig "</span>{KUBECONFIG_PATH}" --context "${CLUSTER_NAME}-tf-managed" get ns &> /dev/null && [ "$CURRENT_RETRY_COUNT" -lt "$MAX_RETRIES" ]; do
        echo "kubectl access failed. Retrying in ${RETRY_INTERVAL}s... (Attempt $((CURRENT_RETRY_COUNT+1))/$MAX_RETRIES)"
        sleep "<span class="math-inline">RETRY\_INTERVAL"
CURRENT\_RETRY\_COUNT\=</span>((CURRENT_RETRY_COUNT+1))
      done

      if kubectl --kubeconfig "<span class="math-inline">\{KUBECONFIG\_PATH\}" \-\-context "</span>{CLUSTER_NAME}-tf-managed" get ns &> /dev/null; then
        echo "kubectl access confirmed after $((CURRENT_RETRY_COUNT)) retries."
        exit 0
      else
        echo "kubectl access still failed after <span class="math-inline">MAX\_RETRIES attempts\. This indicates a persistent connectivity issue to the EKS API\."
echo "Possible reasons\: Network ACLs, Security Groups, DNS resolution, or EKS control plane not fully healthy\."
exit 1
fi
EOT
interpreter \= \["bash", "\-c"\]
\}
\}
\# \-\-\- NGINX Application Deployment \-\-\-
resource "kubernetes\_deployment" "nginx\_app" \{
depends\_on \= \[null\_resource\.eks\_api\_ready\]
metadata \{
name \= "nginx\-deployment"
labels \= \{
app \= "nginx"
\}
\}
spec \{
replicas \= 2
selector \{
match\_labels \= \{
<108\>app \= "nginx"
\}
\}
template \{
metadata \{
labels \= \{
app \= "nginx"
\}
\}
spec \{
container \{
name  \= "nginx"
image \= "nginx\:latest"
port \{
container\_port \= 80
\}
\}
\}
\}
\}
\}
resource "kubernetes\_service"</108\> "nginx\_service" \{
depends\_on \= \[kubernetes\_deployment\.nginx\_app\]
metadata \{
name \= "nginx\-service"
labels \= \{
app \= "nginx"
\}
\}
spec \{
selector \= \{
app \= "nginx"
\}
port \{
port        \= 80
target\_port \= 80
node\_port   \= 30080
\}
type \= "NodePort"
\}
\}
\# \-\-\- ArgoCD Installation \-\-\-
resource "kubernetes\_namespace" "argocd" \{
depends\_on \= \[null\_resource\.eks\_api\_ready\]
metadata \{
name \= "argocd"
\}
\}
locals \{
argocd\_install\_yaml \= base64encode\(<<\-EOT
apiVersion\: v1
kind\: Namespace
metadata\:
labels\:
argocd\.argoproj\.io/secret\-type\: cluster
name\: argocd
\-\-\-
<109\>apiVersion\: v1
kind\: ServiceAccount
<111\>metadata\:
labels\:
app\.kubernetes\.io/component\: server
app\.kubernetes\.io/name\: argocd\-server
app\.kubernetes\.io/part\-of\:</109\> argocd
name\: argocd\-server</111\>
namespace\: argocd
\-\-\-
apiVersion\: <110\>rbac\.authorization\.k8s\.io/v1
kind\: Role
metadata\:
labels\:
app\.kubernetes\.io/component\: <116\>server
app\.kubernetes\.io/name\: argocd\-server
app\.kubernetes\.io/part\-of\: argocd</110\>
name\: argocd\-server
namespace\: argocd
rules\:
\- apiGroups\:
\- ""
resources\:</116\>
\- pods
\- pods/exec
verbs\:
\- create
\- get
\- list
\- watch
\- update
\- patch
\- delete
\-\-\-
apiVersion\: rbac\.authorization\.k8s\.io/v1
kind\: RoleBinding
<112\>metadata\:
labels\:
app\.kubernetes\.io/component\: server
app\.kubernetes\.io/name\: argocd\-server
app\.kubernetes\.io/part\-of\: argocd
name\: argocd\-server</112\>
namespace\: argocd
roleRef\:
<117\>apiGroup\: rbac\.authorization\.k8s\.io
kind\: Role
name\: argocd\-server
subjects\:
\- kind\: ServiceAccount
name\: argocd\-server
namespace\: argocd</117\>
\-\-\-
<113\>apiVersion\: apps/v1
kind\: Deployment
metadata\:
labels\:
app\.kubernetes\.io/component\: server
app\.kubernetes\.io/name\: argocd\-server
app\.kubernetes\.io/part\-of\: argocd
name\: argocd\-server</113\>
namespace\: argocd
<114\>spec\:
selector\:
matchLabels\:
app\.kubernetes\.io/name\: argocd\-server
template\:
metadata\:
labels\:
app\.kubernetes\.io/name\: argocd\-server</114\>
spec\:
serviceAccountName\: argocd\-server
containers\:
\- name\: argocd\-server
image\: argoproj/argocd\:v2\.10\.0
ports\:
\- containerPort\: 8080
\- containerPort\: 443
\-\-\-
<115\>apiVersion\: v1
kind\: Service
metadata\:
labels\:
app\.kubernetes\.io/component\: server
app\.kubernetes\.io/name\: argocd\-server
app\.kubernetes\.io/part\-of\: argocd
name\: argocd\-server</115\>
namespace\: argocd
spec\:
selector\:
app\.kubernetes\.io/name\: argocd\-server
ports\:
\- name\: http
port\: 80
targetPort\: 8080
\- name\: https
port\: 443
targetPort\: 443
type\: ClusterIP
EOT
\)
argocd\_manifests \= \[
for doc\_str in split\("\-\-\-", base64decode\(local\.argocd\_install\_yaml\)\) \:
yamldecode\(doc\_str\) if trimspace\(doc\_str\) \!\= ""
\]
\}
resource "kubernetes\_manifest" "argocd\_install" \{
depends\_on \= \[kubernetes\_namespace\.argocd, null\_resource\.eks\_api\_ready\]
for\_each   \= \{ for i, manifest in local\.argocd\_manifests \: "</span>{lookup(manifest, "kind", "unknown")}-<span class="math-inline">\{lookup\(manifest\.metadata, "name", "unknown"\)\}\-</span>{i}" => manifest }
  manifest   = each.value
}

resource "null_resource" "patch_argocd_server_service" {
  depends_on = [kubernetes_manifest.argocd_install, null_resource.eks_api_ready]

  provisioner "local-exec" {
    command = "kubectl patch svc argocd-server -n argocd -p '{\"spec\": {\"type\": \"LoadBalancer\"}}' --context <span class="math-inline">\{var\.cluster\_name\}\-tf\-managed"
interpreter \= \["bash", "\-c"\]
\}
\}
resource "kubernetes\_manifest" "nginx\_argocd\_app" \{
depends\_on \= \[null\_resource\.patch\_argocd\_server\_service, null\_resource\.eks\_api\_ready\]
manifest \= \{
apiVersion \= "argoproj\.<118\>io/v1alpha1"
kind       \= "Application"
metadata \= \{
name      \= "nginx\-application"
namespace \= "argocd"
\}
spec \= \{
project \= "default"
source \= \{
repoURL        \= "https\://github\.com/YOUR\_GITHUB\_USER/YOUR\_NGINX\_REPO\.git"</118\>
targetRevision \= "HEAD"
path           \= "kubernetes\-manifests"
\}
destination \= \{
server    \= "https\://kubernetes\.default\.svc"
namespace \= "default"
\}
syncPolicy \= \{
automated \= \{
prune    \= true
selfHeal \= true
\}
\}
\}
\}
\}
<119\>output "cluster\_id" \{
description \= "EKS cluster ID\."
value       \= module\.eks\.cluster\_id
\}
<120\>output "cluster\_endpoint" \{
description \= "Endpoint for EKS control plane\."
value       \= module\.eks\.cluster\_endpoint
\}
output "cluster\_security\_group\_id"</119\> \{
description \= "Security group IDs attached to the cluster control plane\."
value       \= module\.eks\.cluster\_security\_group\_id</120\>
\}
output "region" \{
description \= "AWS region"
value       \= var\.aws\_region
\}
output "oidc\_provider\_arn" \{
value \= module\.eks\.oidc\_provider\_arn
\}
output "zz\_update\_kubeconfig\_command" \{
description \= "Command to update kubeconfig for the cluster"
value       \= \(
module\.eks\.cluster\_id \!\= "" && module\.eks\.cluster\_id \!\= null ?
format\("aws eks update\-kubeconfig \-\-name %s \-\-region %s \-\-kubeconfig /tmp/kubeconfig\-%s \-\-alias %s\-tf\-managed", var\.cluster\_name, var\.aws\_region, var\.cluster\_name, var\.cluster\_name\) \:
"Cluster not created yet"
\)
\}
output "nat\_gateway\_eip\_address" \{
description \= "The Elastic IP address allocated for the NAT Gateway\."
value       \= module\.vpc\.nat\_public\_ips\[0\]
\}
output "nginx\_access\_instructions" \{
description \= "Instructions to access the NGINX application\."
value \= <<\-EOT
To access the NGINX application\:
1\. Get the Node IP\: kubectl get nodes \-o wide \-\-kubeconfig /tmp/kubeconfig\-</span>{var.cluster_name} --context <span class="math-inline">\{var\.cluster\_name\}\-tf\-managed
2\. Access NGINX via NodePort\: http\://<NODE\_IP\>\:</span>{kubernetes_service.nginx_service.spec[0].port[0].node_port}
    3. Alternatively, use kubectl port-forward:
       kubectl port-forward svc/nginx-service 8080:80 --kubeconfig /tmp/kubeconfig-${var.cluster_name} --context <span class="math-inline">\{var\.cluster\_name\}\-tf\-managed
Then access at\: http\://localhost\:8080
EOT
\}
output "argocd\_access\_instructions" \{
description \= "Instructions to access the ArgoCD UI\."
value \= <<\-EOT
To access the ArgoCD UI\:
1\. Get the ArgoCD server LoadBalancer IP\:
kubectl get svc argocd\-server \-n argocd \-o jsonpath\='\{\.status\.loadBalancer\.ingress\[0\]\.hostname\}' \-\-kubeconfig /tmp/kubeconfig\-</span>{var.cluster_name} --context <span class="math-inline">\{var\.cluster\_name\}\-tf\-managed \|\| kubectl get svc argocd\-server \-n argocd \-o jsonpath\='\{\.status\.loadBalancer\.ingress\[0\]\.ip\}' \-\-kubeconfig /tmp/kubeconfig\-</span>{var.cluster_name} --context <span class="math-inline">\{var\.cluster\_name\}\-tf\-managed
2\. Access the UI at\: https\://<ARGOCD\_LOADBALANCER\_IP\>
3\. Get the initial admin password\:
kubectl \-n argocd get secret argocd\-initial\-admin\-secret \-o jsonpath\="\{\.data\.password\}" \-\-kubeconfig /tmp/kubeconfig\-</span>{var.cluster_name} --context ${var.cluster_name}-tf-managed | base64 -d
    4. Login with username 'admin' and the retrieved password.
  EOT
}