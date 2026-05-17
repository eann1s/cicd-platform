resource "kubernetes_namespace" "argocd" {
  metadata {
    name = var.argocd_namespace
  }
  lifecycle {
    ignore_changes = [
      metadata[0].annotations
    ]
  }
}

resource "kubernetes_namespace" "go_service" {
  metadata {
    name = var.go_service_namespace
  }
  lifecycle {
    ignore_changes = [
      metadata[0].annotations
    ]
  }
}

resource "kubernetes_namespace" "node_service" {
  metadata {
    name = var.node_service_namespace
  }
  lifecycle {
    ignore_changes = [
      metadata[0].annotations
    ]
  }
}
