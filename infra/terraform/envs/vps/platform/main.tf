locals {
  repo_root = "${path.module}/../../../../.."
}

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

resource "kubernetes_namespace" "monitoring_namespace" {
  metadata {
    name = var.monitoring_namespace
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
  depends_on = [kubernetes_namespace.argocd]
}

resource "helm_release" "argocd_image_updater" {
  name       = "argocd-image-updater"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-image-updater"
  version    = "1.2.1"
  namespace  = var.argocd_namespace
  values = [
    yamlencode({
      config = {
        "log.level" = "debug"
        "git.user"  = "argocd-image-updater"
        "git.email" = "argocd-image-updater@users.noreply.github.com"

        "registries.conf" = <<-EOT
          registries:
            - name: Github Container Registry
              api_url: https://ghcr.io
              prefix: ghcr.io
              credentials: pullsecret:argocd/ghcr-image-updater
              default: true
        EOT
      }
    })
  ]
  depends_on = [kubernetes_namespace.argocd]
}

resource "helm_release" "kube_prometheus_stack" {
  name       = "kube-prometheus-stack"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  version    = "85.2.2"
  namespace  = var.monitoring_namespace
  values = [
    yamlencode({
      alertmanager = {
        alertmanagerSpec = {
          alertmanagerConfigMatcherStrategy = {
            type = "None"
          }
        }
      }
    })
  ]
}
