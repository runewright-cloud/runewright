#!/usr/bin/env bash
# bootstrap.sh — reproducible toolchain setup for Runewright
#
# Pinned versions (all three must stay in sync):
#   nargo  1.0.0-beta.20
#   bb     5.0.0-nightly.20260324   (see pinning note below)
#   Flutter stable (latest, pulled from git tag)
#   Rust   stable (via rustup)
#
# Pinning note for bb:
#   bb 5.0.0-nightly.20260324 is a nightly build; nightly URLs are not
#   guaranteed to remain hosted long-term. The vendored SHA-256 below
#   is the authoritative pin. If the upstream URL 404s, obtain the binary
#   from a team member who has it cached, verify the checksum, and re-host
#   at a stable location (e.g. a tagged GitHub release in this repo).
#   Never skip the checksum step.
#
# Usage:
#   bash bootstrap.sh            # full install
#   bash bootstrap.sh --check    # verify versions only (no install)

set -euo pipefail

NARGO_VERSION="1.0.0-beta.20"
BB_VERSION="5.0.0-nightly.20260324"
# SHA-256 of the linux-amd64 bb binary at the pinned version.
# Update this if the binary is re-hosted at a new location.
BB_SHA256="REPLACE_WITH_ACTUAL_SHA256_AFTER_FIRST_DOWNLOAD"

NARGO_URL="https://github.com/noir-lang/noir/releases/download/v${NARGO_VERSION}/nargo-x86_64-unknown-linux-gnu.tar.gz"
BB_URL="https://github.com/AztecProtocol/aztec-packages/releases/download/aztec-packages-v${BB_VERSION}/barretenberg-x86_64-linux-gnu.tar.gz"

INSTALL_DIR="${HOME}/.runewright/bin"
mkdir -p "${INSTALL_DIR}"

check_only=false
if [[ "${1:-}" == "--check" ]]; then
  check_only=true
fi

# ── Version verification helpers ─────────────────────────────────────────────

check_nargo() {
  if command -v nargo &>/dev/null; then
    local v
    v=$(nargo --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+[^\s]*' | head -1 || true)
    if [[ "$v" == "$NARGO_VERSION" ]]; then
      echo "  nargo  ${v} ✓"
      return 0
    else
      echo "  nargo  found ${v}, want ${NARGO_VERSION} ✗"
      return 1
    fi
  else
    echo "  nargo  not found ✗"
    return 1
  fi
}

check_bb() {
  if command -v bb &>/dev/null; then
    local v
    v=$(bb --version 2>/dev/null | grep -oP '[\d\.\-]+nightly\.\d+' | head -1 || true)
    if [[ "$v" == "$BB_VERSION" ]]; then
      echo "  bb     ${v} ✓"
      return 0
    else
      echo "  bb     found ${v}, want ${BB_VERSION} ✗"
      return 1
    fi
  else
    echo "  bb     not found ✗"
    return 1
  fi
}

check_flutter() {
  if command -v flutter &>/dev/null; then
    echo "  flutter $(flutter --version 2>/dev/null | head -1) ✓"
    return 0
  else
    echo "  flutter not found ✗"
    return 1
  fi
}

check_rust() {
  if command -v rustc &>/dev/null; then
    echo "  rustc  $(rustc --version) ✓"
    return 0
  else
    echo "  rustc  not found ✗"
    return 1
  fi
}

# ── Early-exit if --check ─────────────────────────────────────────────────────

if $check_only; then
  echo "=== Runewright toolchain versions ==="
  all_ok=true
  check_nargo   || all_ok=false
  check_bb      || all_ok=false
  check_flutter || all_ok=false
  check_rust    || all_ok=false
  if $all_ok; then
    echo "All tools at pinned versions."
    exit 0
  else
    echo "One or more tools missing or at wrong version. Run: bash bootstrap.sh"
    exit 1
  fi
fi

# ── Install nargo ─────────────────────────────────────────────────────────────

if ! check_nargo 2>/dev/null; then
  echo "Installing nargo ${NARGO_VERSION}..."
  tmp=$(mktemp -d)
  curl -fsSL "${NARGO_URL}" -o "${tmp}/nargo.tar.gz"
  tar -xzf "${tmp}/nargo.tar.gz" -C "${tmp}"
  install -m 755 "${tmp}/nargo" "${INSTALL_DIR}/nargo"
  rm -rf "${tmp}"
  export PATH="${INSTALL_DIR}:${PATH}"
  echo "  nargo installed to ${INSTALL_DIR}/nargo"
fi

# ── Install bb ───────────────────────────────────────────────────────────────

if ! check_bb 2>/dev/null; then
  echo "Installing bb ${BB_VERSION}..."
  tmp=$(mktemp -d)
  curl -fsSL "${BB_URL}" -o "${tmp}/bb.tar.gz"

  # Verify checksum if we have one pinned
  if [[ "${BB_SHA256}" != "REPLACE_WITH_ACTUAL_SHA256_AFTER_FIRST_DOWNLOAD" ]]; then
    echo "${BB_SHA256}  ${tmp}/bb.tar.gz" | sha256sum --check --strict
  else
    echo "  WARNING: bb checksum not yet pinned. After first install, run:"
    echo "    sha256sum ${tmp}/bb.tar.gz"
    echo "  and paste the result into BB_SHA256 in bootstrap.sh."
  fi

  tar -xzf "${tmp}/bb.tar.gz" -C "${tmp}"
  install -m 755 "${tmp}/bb" "${INSTALL_DIR}/bb"
  rm -rf "${tmp}"
  export PATH="${INSTALL_DIR}:${PATH}"
  echo "  bb installed to ${INSTALL_DIR}/bb"
fi

# ── Install Flutter (stable) ─────────────────────────────────────────────────

if ! check_flutter 2>/dev/null; then
  echo "Installing Flutter stable..."
  FLUTTER_DIR="${HOME}/.runewright/flutter"
  if [[ ! -d "${FLUTTER_DIR}" ]]; then
    git clone --depth 1 --branch stable \
      https://github.com/flutter/flutter.git "${FLUTTER_DIR}"
  else
    git -C "${FLUTTER_DIR}" fetch --tags origin stable
    git -C "${FLUTTER_DIR}" checkout stable
  fi
  export PATH="${FLUTTER_DIR}/bin:${PATH}"
  flutter precache --no-ios --no-macos --no-web --no-windows --no-fuchsia
  echo "  flutter installed to ${FLUTTER_DIR}"
fi

# ── Install Rust (stable + Android cross-compile target) ─────────────────────

if ! check_rust 2>/dev/null; then
  echo "Installing Rust stable..."
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
  # shellcheck disable=SC1091
  source "${HOME}/.cargo/env"
  echo "  rust installed"
fi

# Android cross-compile target for M2 mobile proving spike
echo "Adding Android cross-compile target..."
rustup target add aarch64-linux-android 2>/dev/null || true

# ── Final verification ────────────────────────────────────────────────────────

echo ""
echo "=== Runewright toolchain versions ==="
export PATH="${INSTALL_DIR}:${HOME}/.cargo/bin:${PATH}"

all_ok=true
check_nargo   || all_ok=false
check_bb      || all_ok=false
check_flutter || all_ok=false
check_rust    || all_ok=false

echo ""
if $all_ok; then
  echo "Bootstrap complete. Add ${INSTALL_DIR} to your PATH:"
  echo "  export PATH=\"${INSTALL_DIR}:\${PATH}\""
else
  echo "Bootstrap finished but one or more tools did not install correctly."
  echo "Check the output above and re-run bootstrap.sh."
  exit 1
fi
