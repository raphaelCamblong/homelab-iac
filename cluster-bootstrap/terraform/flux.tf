# Kubernetes provider points at the kubeconfig Terraform just wrote.
provider "kubernetes" {
  config_path = local_sensitive_file.kubeconfig.filename
}

# Helm provider for the pre-Flux Cilium install (see helm_release.cilium below).
provider "helm" {
  kubernetes {
    config_path = local_sensitive_file.kubeconfig.filename
  }
}

# 0a) Apply Gateway API CRDs (experimental channel — Cilium 1.19 needs
#     TLSRoute v1alpha2) BEFORE Cilium so the operator's field indexers
#     find them at startup. null_resource + kubectl --server-side because
#     the httproutes CRD is large enough to blow the last-applied-
#     configuration annotation on client-side apply. Replays when the
#     vendored CRD bundle file hash changes.
resource "null_resource" "gateway_api_crds" {
  triggers = {
    file_hash = filemd5("${path.module}/../../clusters/homelab/infrastructure/gateway-api-crds/standard-install.yaml")
  }
  provisioner "local-exec" {
    command = <<-EOT
      kubectl --kubeconfig=${local_sensitive_file.kubeconfig.filename} \
        apply --server-side=true --force-conflicts \
        -f ${path.module}/../../clusters/homelab/infrastructure/gateway-api-crds/standard-install.yaml
    EOT
  }
  depends_on = [local_sensitive_file.kubeconfig]
}

# 0b) Pre-Flux Cilium install. Breaks the bootstrap circularity (Flux pods
#     need CNI; CNI is normally Flux-managed). Flux's helm-controller adopts
#     this release on first reconcile — release name + namespace match the
#     HelmRelease at clusters/homelab/infrastructure/cilium/helmrelease.yaml.
#     `ignore_changes = all` so TF stops managing values after first apply;
#     Flux is then the single source of truth for chart upgrades.
#
#     KEEP THE CHART VERSION HERE IN SYNC with helmrelease.yaml chart.spec.version.
resource "helm_release" "cilium" {
  name       = "cilium"
  namespace  = "kube-system"
  repository = "https://helm.cilium.io"
  chart      = "cilium"
  version    = "1.19.4"
  values     = [file("${path.module}/../../clusters/homelab/infrastructure/cilium/values.yaml")]
  timeout    = 600 # 10m — first image pull on arm64 + operator stabilization
  wait       = true
  depends_on = [null_resource.gateway_api_crds]
  lifecycle {
    ignore_changes = all
  }
}

# 1) Create the flux-system namespace explicitly, BEFORE Flux installs.
#    This lets us pre-place the sops-age Secret so the very first
#    reconciliation of any SOPS-encrypted Kustomization (e.g. backup)
#    succeeds without spurious "secret not found" failures.
#    flux_bootstrap_git is idempotent against an existing namespace.
resource "kubernetes_namespace_v1" "flux_system" {
  metadata {
    name = "flux-system"
  }
  lifecycle {
    ignore_changes = [metadata] # Flux annotates it after bootstrap; don't fight that.
  }
}

# 2) SOPS age decryption Secret — placed BEFORE flux_bootstrap_git so any
#    Kustomization with `decryption: { provider: sops }` finds the key on
#    its first reconcile.
resource "kubernetes_secret_v1" "sops_age" {
  metadata {
    name      = "sops-age"
    namespace = kubernetes_namespace_v1.flux_system.metadata[0].name
  }
  data = {
    "age.agekey" = file(pathexpand(var.age_key_path))
  }
}

# 3) GitHub deploy key for Flux to pull from the repo.
provider "github" {
  owner = var.github_owner
  token = var.github_token
}

resource "tls_private_key" "flux" {
  algorithm   = "ECDSA"
  ecdsa_curve = "P256"
}

resource "github_repository_deploy_key" "flux" {
  title      = "flux-${var.cluster_name}"
  repository = var.github_repo
  key        = tls_private_key.flux.public_key_openssh
  read_only  = false
}

# 4) Flux bootstrap — installs the controllers and writes its own manifests
#    to clusters/homelab/flux-system/ on the configured branch. By the time
#    Flux starts reconciling, the namespace AND the sops-age Secret are
#    already in place.
provider "flux" {
  kubernetes = {
    config_path = local_sensitive_file.kubeconfig.filename
  }
  git = {
    url    = "ssh://git@github.com/${var.github_owner}/${var.github_repo}.git"
    branch = var.github_branch
    ssh = {
      username    = "git"
      private_key = tls_private_key.flux.private_key_pem
    }
  }
}

resource "flux_bootstrap_git" "this" {
  depends_on = [
    github_repository_deploy_key.flux,
    local_sensitive_file.kubeconfig,
    kubernetes_secret_v1.sops_age, # Flux only starts AFTER decryption key is in place.
    helm_release.cilium,           # CNI must be up before Flux controller pods can schedule.
  ]

  path     = var.flux_path
  interval = "1h" # webhook (see clusters/homelab/flux-receiver.yaml) drives real reconciles; polling is fallback
  # components_extra: image-reflector-controller + image-automation-controller
  # deferred — re-enable when Renovate/image-automation is actually needed.
}
