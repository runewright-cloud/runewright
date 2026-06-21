#!/usr/bin/env bash
# check_ffi_fresh.sh — warns if the deployed Android .so is older than the
# Rust FFI source it's supposed to be compiled from.
#
# Why this exists: a stale .so doesn't fail to build or install -- it
# installs fine and then crashes on launch with a cryptic
# "Content hash on Dart side is different from Rust side, indicating
# out-of-sync code" error (flutter_rust_bridge's own sanity check catching
# the mismatch at *runtime*, not build time). This happened during the M4
# two-device gate run (docs/M4_findings.md M4.6) and has happened before
# in this project. The fix (scripts/build_android_ffi.sh) is one command --
# the problem was never knowing it needed to be run.
#
# Usage:
#   bash scripts/check_ffi_fresh.sh
# Exit 0 : .so is at least as new as every ffi/src file -- nothing to do.
# Exit 1 : .so is stale or missing -- run scripts/build_android_ffi.sh.
#
# Run this before `flutter run`/`flutter build apk` whenever ffi/src/ has
# changed. Cheap (a handful of `stat` calls) -- safe to run every time as a
# habit, not just when something feels wrong. See CLAUDE.md's Bug Avoidance
# Reminders.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SO="${REPO_ROOT}/android/app/src/main/jniLibs/arm64-v8a/librunewright_ffi.so"
FFI_SRC="${REPO_ROOT}/ffi/src"

if [[ ! -f "${SO}" ]]; then
  echo "STALE: ${SO} does not exist yet."
  echo "  Run: bash scripts/build_android_ffi.sh"
  exit 1
fi

SO_MTIME=$(stat -c %Y "${SO}")

NEWER_FILES=()
while IFS= read -r -d '' f; do
  if [[ "$(stat -c %Y "${f}")" -gt "${SO_MTIME}" ]]; then
    NEWER_FILES+=("${f#"${REPO_ROOT}"/}")
  fi
done < <(find "${FFI_SRC}" -name "*.rs" -print0)

if [[ ${#NEWER_FILES[@]} -gt 0 ]]; then
  echo "STALE: the Android .so is older than ${#NEWER_FILES[@]} Rust source file(s):"
  for f in "${NEWER_FILES[@]}"; do
    echo "  ${f}"
  done
  echo ""
  echo "  This is the exact failure mode that crashes on launch with:"
  echo "    \"Content hash on Dart side is different from Rust side\""
  echo ""
  echo "  Run: bash scripts/build_android_ffi.sh"
  exit 1
fi

echo "OK: ${SO#"${REPO_ROOT}"/} is up to date with ffi/src/."
