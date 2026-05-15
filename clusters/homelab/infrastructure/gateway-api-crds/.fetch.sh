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
curl -sL -o standard-install.yaml \
  https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.5.1/standard-install.yaml
ls -la standard-install.yaml
