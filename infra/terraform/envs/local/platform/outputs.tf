output "argocd_namespace" {
  value = kubernetes_namespace.argocd.metadata[0].name
}

output "go_namespace" {
  value = kubernetes_namespace.go_service.metadata[0].name
}

output "node_namespace" {
  value = kubernetes_namespace.node_service.metadata[0].name
}
