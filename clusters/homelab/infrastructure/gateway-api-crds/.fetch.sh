#!/usr/bin/env bash
# Vendor the upstream Gateway API standard CRDs.
# Run this once at action time BEFORE the Flux bootstrap (Phase 5),
# then commit the generated standard-install.yaml.
#
# Why vendored: Flux sources are kustomize/helm/git/oci — it can't fetch a
# raw GitHub release URL directly.
# Pinned v1.5.1 — latest stable at 2026-05-15.
set -euo pipefail
cd "$(dirname "$0")"
# NOTE: experimental channel, NOT standard. Cilium 1.19.x requires
# TLSRoute v1alpha2 to be served — only the experimental bundle serves
# v1alpha2 (standard serves v1 only). The filename is kept as
# standard-install.yaml so kustomization.yaml does not need to change;
# only the source URL differs. Re-run this script when bumping pin.
curl -sL -o standard-install.yaml \
  https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.5.1/experimental-install.yaml
ls -la standard-install.yaml
