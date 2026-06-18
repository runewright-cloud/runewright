#!/usr/bin/env bash
# build_android_ffi.sh — compile the runewright_ffi Rust crate for Android
# and copy the .so into the Flutter jniLibs tree.
#
# Linking strategy: NDK clang as the linker + Zig's statically-compiled libc++
# injected via ndk-cxx-android.sh. barretenberg-rs's libbb-external.a uses the
# upstream LLVM __1 libc++ namespace (Zig-built); NDK's libc++_shared.so uses
# __ndk1, so we replace it entirely with Zig's static libc++.a.
#
# Prerequisites (one-time):
#   rustup target add aarch64-linux-android
#   Zig libcxx cache seeded at ~/.cache/runewright/zig-libcxx/
#     (done automatically on first run if the cache directory is missing)
#   barretenberg arm64-android .a at:
#     ~/.cache/runewright/barretenberg/4.2.0-aztecnr-rc.2/arm64-android/libbb-external.a
#     (downloaded automatically on first run)
#
# Usage:
#   bash scripts/build_android_ffi.sh           # release build
#   bash scripts/build_android_ffi.sh --debug   # debug build (no optimisation)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FFI_DIR="${REPO_ROOT}/ffi"
JNI_LIBS="${REPO_ROOT}/android/app/src/main/jniLibs"
LINKER_WRAPPER="${REPO_ROOT}/scripts/ndk-cxx-android.sh"

BB_VERSION="4.2.0-aztecnr-rc.2"
BB_CACHE="${HOME}/.cache/runewright/barretenberg/${BB_VERSION}/arm64-android"
ZIG_LIBCXX_DIR="${HOME}/.cache/runewright/zig-libcxx"

MODE="release"
CARGO_FLAGS="--release"
if [[ "${1:-}" == "--debug" ]]; then
  MODE="debug"
  CARGO_FLAGS=""
fi

echo "=== Building runewright_ffi for Android (${MODE}) ==="

# ── 1. NDK ──────────────────────────────────────────────────────────────────
if [[ -z "${ANDROID_NDK_HOME:-}" ]]; then
  DETECTED=$(find "${HOME}/Android/Sdk/ndk" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort -V | tail -1)
  if [[ -n "${DETECTED}" ]]; then
    export ANDROID_NDK_HOME="${DETECTED}"
    echo "  Auto-detected NDK: ${ANDROID_NDK_HOME}"
  else
    echo "ERROR: ANDROID_NDK_HOME not set and auto-detection failed."
    echo "  find ~/Android/Sdk -name 'ndk' -maxdepth 2"
    exit 1
  fi
fi

NDK_HOST="${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/linux-x86_64"
NDK_CC="${NDK_HOST}/bin/aarch64-linux-android24-clang"
READELF="${NDK_HOST}/bin/llvm-readelf"
NM="${NDK_HOST}/bin/llvm-nm"

if [[ ! -x "${NDK_CC}" ]]; then
  echo "ERROR: aarch64-linux-android24-clang not found under ${NDK_HOST}"
  exit 1
fi
echo "  NDK: ${ANDROID_NDK_HOME}"

# ── 2. Zig libcxx cache ─────────────────────────────────────────────────────
# These three files were compiled once via:
#   zig c++ -target aarch64-linux-android [test.cpp] ...
# and copied from ~/.cache/zig/o/<hash>/ to this stable path.
# Re-run docs/M2_ffi_spike.md §"Seed Zig libcxx cache" to regenerate.
for lib in libc++.a libc++abi.a libunwind.a; do
  if [[ ! -f "${ZIG_LIBCXX_DIR}/${lib}" ]]; then
    echo "ERROR: Zig libcxx cache missing: ${ZIG_LIBCXX_DIR}/${lib}"
    echo "  See docs/M2_ffi_spike.md for the seed procedure."
    exit 1
  fi
done
echo "  Zig libcxx: ${ZIG_LIBCXX_DIR}"

# ── 3. barretenberg arm64-android .a ─────────────────────────────────────────
# barretenberg-rs build.rs has a target-match bug: "aarch64-linux-android"
# matches the "linux" arm before the "android" arm, downloading the wrong
# arm64-linux binary. We bypass it with BB_LIB_DIR pointing to the correct
# arm64-android artifact cached here.
if [[ ! -f "${BB_CACHE}/libbb-external.a" ]]; then
  echo "  Downloading barretenberg-rs arm64-android static lib (${BB_VERSION})..."
  mkdir -p "${BB_CACHE}"
  BB_URL="https://github.com/AztecProtocol/aztec-packages/releases/download/v${BB_VERSION}/barretenberg-static-arm64-android.tar.gz"
  if ! curl -fL "${BB_URL}" | tar -xz -C "${BB_CACHE}"; then
    echo ""
    echo "ERROR: Auto-download failed. Download manually:"
    echo "  URL: ${BB_URL}"
    echo "  Extract libbb-external.a to: ${BB_CACHE}/"
    echo "  (Or find the asset in the barretenberg-rs ${BB_VERSION} GitHub release.)"
    exit 1
  fi
  if [[ ! -f "${BB_CACHE}/libbb-external.a" ]]; then
    echo "ERROR: Downloaded but libbb-external.a not found in ${BB_CACHE}"
    exit 1
  fi
fi
export BB_LIB_DIR="${BB_CACHE}"
echo "  BB_LIB_DIR: ${BB_LIB_DIR}"

# ── 4. Linker wrapper ────────────────────────────────────────────────────────
if [[ ! -f "${LINKER_WRAPPER}" ]]; then
  echo "ERROR: linker wrapper not found: ${LINKER_WRAPPER}"
  exit 1
fi
chmod +x "${LINKER_WRAPPER}"
export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="${LINKER_WRAPPER}"
echo "  Linker: ${LINKER_WRAPPER}"

# Provide CC/CXX/AR for any build scripts that invoke the C toolchain.
export CC_aarch64_linux_android="${NDK_CC}"
export CXX_aarch64_linux_android="${NDK_HOST}/bin/aarch64-linux-android24-clang++"
export AR_aarch64_linux_android="${NDK_HOST}/bin/llvm-ar"

# ── 5. Rust build ────────────────────────────────────────────────────────────
source "${HOME}/.cargo/env"
echo ""
echo "=== Compiling Rust → aarch64-linux-android (${MODE}) ==="
cargo build --lib --target aarch64-linux-android ${CARGO_FLAGS} \
  --manifest-path "${FFI_DIR}/Cargo.toml"

# ── 6. Verify .so linkage ────────────────────────────────────────────────────
SO="${FFI_DIR}/target/aarch64-linux-android/${MODE}/librunewright_ffi.so"
if [[ ! -f "${SO}" ]]; then
  echo "ERROR: .so not found at ${SO}"
  exit 1
fi

echo ""
echo "=== Verifying .so linkage ==="

# FAIL if libc++_shared.so is listed — means the namespace injection didn't work.
if "${READELF}" -d "${SO}" | grep -q "libc++_shared"; then
  echo "FAIL: libc++_shared.so found in NEEDED — ABI mismatch will crash dlopen!"
  "${READELF}" -d "${SO}" | grep NEEDED
  exit 1
fi
echo "  PASS: no libc++_shared.so in NEEDED"

NEEDED=$("${READELF}" -d "${SO}" | grep NEEDED | sed 's/.*\[//;s/\]//' | tr '\n' ' ')
echo "  NEEDED: ${NEEDED}"

# FAIL if any __1 symbols are undefined — barretenberg symbols leaking.
UNDEF_1=$("${NM}" -D -u "${SO}" 2>/dev/null | grep -c "NSt3__1" || true)
if [[ "${UNDEF_1}" -ne 0 ]]; then
  echo "FAIL: ${UNDEF_1} undefined NSt3__1 symbols — Zig libc++ injection incomplete!"
  "${NM}" -D -u "${SO}" | grep "NSt3__1" | head -10
  exit 1
fi
echo "  PASS: 0 undefined NSt3__1 symbols"

# FAIL if any __ndk1 symbols are undefined — shouldn't happen, but sanity check.
UNDEF_NDK1=$("${NM}" -D -u "${SO}" 2>/dev/null | grep -c "NSt6__ndk1" || true)
if [[ "${UNDEF_NDK1}" -ne 0 ]]; then
  echo "FAIL: ${UNDEF_NDK1} undefined NSt6__ndk1 symbols — unexpected NDK C++ dep!"
  "${NM}" -D -u "${SO}" | grep "NSt6__ndk1" | head -10
  exit 1
fi
echo "  PASS: 0 undefined NSt6__ndk1 symbols"

# FAIL if any glibc-only symbols are undefined — must be shimmed.
for sym in bcmp __ctype_b_loc __ctype_tolower_loc __errno_location; do
  if "${NM}" -D -u "${SO}" 2>/dev/null | grep -qE "[[:space:]]U ${sym}$"; then
    echo "FAIL: ${sym} is undefined — android_shims not linked in!"
    exit 1
  fi
done
echo "  PASS: glibc shim symbols resolved (bcmp, __ctype_b_loc, __ctype_tolower_loc)"

# ── 7. Copy to jniLibs ───────────────────────────────────────────────────────
DEST="${JNI_LIBS}/arm64-v8a/librunewright_ffi.so"
mkdir -p "${JNI_LIBS}/arm64-v8a"
cp "${SO}" "${DEST}"

SIZE=$(du -h "${DEST}" | cut -f1)
echo ""
echo "=== Build complete ==="
echo "  .so     : ${DEST}"
echo "  size    : ${SIZE}"
echo ""
echo "Next: flutter clean && flutter run --release"
echo "  See docs/M2_ffi_spike.md for the measurement procedure."
