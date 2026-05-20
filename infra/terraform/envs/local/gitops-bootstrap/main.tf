locals {
  repo_root = "${path.module}/../../../../.."
}

resource "kubernetes_manifest" "platform_project" {
  manifest = yamldecode(file("${local.repo_root}/gitops/argocd/projects/platform-project.yml"))
}

resource "kubernetes_manifest" "go_service_app" {
  manifest = yamldecode(file("${local.repo_root}/gitops/argocd/applications/go-service-app.yml"))
}

resource "kubernetes_manifest" "node_service_app" {
  manifest = yamldecode(file("${local.repo_root}/gitops/argocd/applications/node-service-app.yml"))
}

resource "kubernetes_manifest" "image_updater_cr" {
  manifest = yamldecode(file("${local.repo_root}/gitops/argocd/image-updater/custom-resource.yml"))
}
