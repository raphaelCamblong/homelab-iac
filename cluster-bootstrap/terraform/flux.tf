# Kubernetes provider points at the kubeconfig Terraform just wrote.
provider "kubernetes" {
  config_path = local_sensitive_file.kubeconfig.filename
}

# 1) Create the flux-system namespace explicitly, BEFORE Flux installs.
#    This lets us pre-place the sops-age Secret so the very first
#    reconciliation of any SOPS-encrypted Kustomization (e.g. backup)
#    succeeds without spurious "secret not found" failures.
#    flux_bootstrap_git is idempotent against an existing namespace.
resource "kubernetes_namespace" "flux_system" {
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
resource "kubernetes_secret" "sops_age" {
  metadata {
    name      = "sops-age"
    namespace = kubernetes_namespace.flux_system.metadata[0].name
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
    kubernetes_secret.sops_age, # Flux only starts AFTER decryption key is in place.
  ]

  path = var.flux_path
  # components_extra: image-reflector-controller + image-automation-controller
  # deferred — re-enable when Renovate/image-automation is actually needed.
}
