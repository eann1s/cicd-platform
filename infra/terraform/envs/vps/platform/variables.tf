variable "argocd_namespace" {
  type    = string
  default = "argocd"
}

variable "go_service_namespace" {
  type    = string
  default = "go-service"
}

variable "node_service_namespace" {
  type    = string
  default = "node-service"
}

variable "monitoring_namespace" {
  type    = string
  default = "monitoring"
}

variable "kube_context" {
  type    = string
  default = "do-k3s-dev"
}

variable "kyverno_namespace" {
  type    = string
  default = "kyverno"
}
