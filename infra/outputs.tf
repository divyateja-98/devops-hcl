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
