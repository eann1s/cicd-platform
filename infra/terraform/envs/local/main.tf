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

resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = "9.5.14"
  namespace  = var.argocd_namespace
}

resource "helm_release" "argocd_image_updater" {
  name       = "argocd-image-updater"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-image-updater"
  version    = "1.2.1"
  namespace  = var.argocd_namespace
}
