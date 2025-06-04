output "argocd_ui_info" {
  value = <<EOT
1. Get ArgoCD UI:
   kubectl get svc argocd-server -n argocd

2. Default login:
   user: admin
   password: 
   kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
EOT
}
