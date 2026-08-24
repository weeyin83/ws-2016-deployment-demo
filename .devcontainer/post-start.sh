#!/usr/bin/env bash
# =============================================================================
# post-start.sh
# Runs on EVERY container start. Keep it fast and side-effect free.
#   - Re-assert ownership of the mounted cache volumes (volumes can mount root-owned).
#   - Print non-secret Azure authentication hints. NO credentials are handled here.
# =============================================================================
set -euo pipefail

CACHE_DIR="${TF_PLUGIN_CACHE_DIR:-$HOME/.terraform.d/plugin-cache}"
sudo chown -R "$(id -u)":"$(id -g)" "$HOME/.terraform.d" 2>/dev/null || true
sudo chown -R "$(id -u)":"$(id -g)" "$HOME/.azure" 2>/dev/null || true
mkdir -p "$CACHE_DIR"

cat <<'EOF'
------------------------------------------------------------------------------
Azure Terraform IaC dev container ready.

Authenticate to Azure with ONE of (no secrets are stored in this image):
  • Interactive:        az login --use-device-code
  • Managed Identity:   az login --identity
  • Service Principal:  az login --service-principal -u "$ARM_CLIENT_ID" \
                          -p "$ARM_CLIENT_SECRET" --tenant "$ARM_TENANT_ID"
  • GitHub OIDC (CI):   azure/login action federates a token; export ARM_USE_OIDC=true

Terraform provider cache: $TF_PLUGIN_CACHE_DIR  (persisted across rebuilds)
------------------------------------------------------------------------------
EOF
