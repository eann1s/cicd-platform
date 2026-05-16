resource "kubernetes_namespace" "argocd" {
  metadata {
    name = var.argocd_namespace
  }
}

resource "kubernetes_namespace" "go_service" {
  metadata {
    name = var.go_service_namespace
  }
}

resource "kubernetes_namespace" "node_service" {
  metadata {
    name = var.node_service_namespace
  }
}
