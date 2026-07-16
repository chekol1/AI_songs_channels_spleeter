# ---------------------------------------------------------------
# ArgoCD - GitOps: continuously syncs k8s/ manifests from GitHub
# into the cluster. Installed via Helm, managed by Terraform,
# UI exposed through a LoadBalancer and printed as an output.
# ---------------------------------------------------------------

terraform {
  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.17"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.35"
    }
  }
}

# Both providers authenticate against the EKS cluster Terraform just created
provider "helm" {
  kubernetes {
    host                   = aws_eks_cluster.main.endpoint
    cluster_ca_certificate = base64decode(aws_eks_cluster.main.certificate_authority[0].data)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", "sonicloud-eks"]
    }
  }
}

provider "kubernetes" {
  host                   = aws_eks_cluster.main.endpoint
  cluster_ca_certificate = base64decode(aws_eks_cluster.main.certificate_authority[0].data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", "sonicloud-eks"]
  }
}

resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  namespace        = "argocd"
  create_namespace = true
  wait             = true
  timeout          = 600

  # expose the UI via an ELB (adds ~$0.6/day)
  set {
    name  = "server.service.type"
    value = "LoadBalancer"
  }

  depends_on = [aws_eks_node_group.default]
}

# Read the ELB hostname Kubernetes assigned to the ArgoCD server service
data "kubernetes_service" "argocd_server" {
  metadata {
    name      = "argocd-server"
    namespace = "argocd"
  }
  depends_on = [helm_release.argocd]
}

output "argocd_url" {
  value = "https://${data.kubernetes_service.argocd_server.status[0].load_balancer[0].ingress[0].hostname}"
}

output "argocd_login_hint" {
  value = "user: admin | password: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
}
