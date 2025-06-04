output "kubeconfig" {
  value = aws_eks_cluster.eks.name
}

output "argocd_url_instruction" {
  value = <<-EOT
    Run the following to get ArgoCD server URL:
    kubectl get svc -n argocd argocd-server -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
  EOT
}
