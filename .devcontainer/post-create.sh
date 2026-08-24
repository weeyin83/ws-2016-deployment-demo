#!/usr/bin/env bash
# =============================================================================
# post-create.sh
# Runs ONCE when the dev container is created (not on every start), so the
# small amount of apt work here is amortised and does not slow down rebuilds.
#
# Responsibilities:
#   1. Guarantee the Terraform plugin cache directory exists and is writable.
#   2. Enable Terraform provider plugin caching via ~/.terraformrc.
#   3. Install lightweight tools not provided by the base image / features
#      (yq, and a safety-net for jq/unzip/curl).
#   4. Validate every required tool and FAIL CLEARLY if anything is missing.
# =============================================================================
set -euo pipefail

echo "==> [post-create] Configuring Azure Terraform IaC toolchain..."

# -----------------------------------------------------------------------------
# 1 + 2. Terraform provider plugin caching
# -----------------------------------------------------------------------------
CACHE_DIR="${TF_PLUGIN_CACHE_DIR:-$HOME/.terraform.d/plugin-cache}"

# The cache dir is a mounted volume; ensure the non-root user owns it.
sudo mkdir -p "$CACHE_DIR"
sudo chown -R "$(id -u)":"$(id -g)" "$HOME/.terraform.d"

# ~/.terraformrc enables the plugin cache and disables the upgrade checkpoint
# call for slightly faster, quieter runs.
cat > "$HOME/.terraformrc" <<EOF
plugin_cache_dir   = "$CACHE_DIR"
disable_checkpoint = true
EOF
echo "    Terraform plugin cache: $CACHE_DIR"

# -----------------------------------------------------------------------------
# 3. Install tools not guaranteed by the base image / features
# -----------------------------------------------------------------------------
# Safety net for jq / unzip / curl (usually present in base:ubuntu).
MISSING_PKGS=()
for pkg in jq unzip curl; do
  command -v "$pkg" >/dev/null 2>&1 || MISSING_PKGS+=("$pkg")
done
if [ "${#MISSING_PKGS[@]}" -gt 0 ]; then
  echo "    Installing missing base tools: ${MISSING_PKGS[*]}"
  sudo apt-get update -y
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${MISSING_PKGS[@]}"
  sudo rm -rf /var/lib/apt/lists/*
fi

# yq (official single Go binary from mikefarah/yq) is not shipped by the base image.
if ! command -v yq >/dev/null 2>&1; then
  YQ_VERSION="v4.44.6"
  ARCH="$(dpkg --print-architecture)"   # amd64 / arm64
  echo "    Installing yq ${YQ_VERSION} (${ARCH})"
  sudo curl -fsSL "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${ARCH}" \
    -o /usr/local/bin/yq
  sudo chmod 0755 /usr/local/bin/yq
fi

# -----------------------------------------------------------------------------
# 4. Validate the toolchain - fail clearly if anything is missing
# -----------------------------------------------------------------------------
echo ""
echo "==> [post-create] Validating installed tooling..."

FAILED=0
check() {
  local name="$1"; shift
  if command -v "$name" >/dev/null 2>&1; then
    printf '    [ OK ] %-12s -> %s\n' "$name" "$("$@" 2>&1 | head -n 1)"
  else
    printf '    [FAIL] %-12s -> NOT FOUND\n' "$name"
    FAILED=1
  fi
}

check terraform terraform version
check az        az version --output tsv
check azd       azd version
check pwsh      pwsh --version
check gh        gh --version
check bicep     az bicep version
check jq        jq --version
check yq        yq --version
check git       git --version

echo ""
if [ "$FAILED" -ne 0 ]; then
  echo "==> [post-create] ERROR: one or more required tools are missing (see [FAIL] above)." >&2
  exit 1
fi

echo "==> [post-create] All required tools present. Environment ready. ✅"
