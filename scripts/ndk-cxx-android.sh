#!/usr/bin/env bash
# ndk-cxx-android.sh — aarch64-linux-android linker wrapper for cargo.
#
# barretenberg-rs's libbb-external.a was built with Zig's upstream LLVM libc++
# (NSt3__1 namespace). NDK's libc++_shared.so uses NSt6__ndk1 — incompatible.
# This wrapper uses NDK clang as the linker but replaces -lc++ with Zig's
# statically-compiled libc++ (same __1 namespace as barretenberg).
#
# Set via: export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER=/path/to/this/script

set -euo pipefail

if [[ -z "${ANDROID_NDK_HOME:-}" ]]; then
  echo "ERROR: ANDROID_NDK_HOME must be set before invoking this linker wrapper." >&2
  exit 1
fi

NDK_CC="${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android24-clang"
ZIG_LIBCXX_DIR="${HOME}/.cache/runewright/zig-libcxx"

for lib in libc++.a libc++abi.a libunwind.a; do
  if [[ ! -f "${ZIG_LIBCXX_DIR}/${lib}" ]]; then
    echo "ERROR: ${ZIG_LIBCXX_DIR}/${lib} not found. Run build_android_ffi.sh to seed the cache." >&2
    exit 1
  fi
done

# Shim: provides bcmp, __ctype_b_loc, __ctype_tolower_loc, catopen/gets/close,
# strtod_l, strtof_l, __errno_location — glibc symbols not in Android Bionic.
# Compiled from ffi/android_shims.c; cached by content (recompiled if src newer).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SHIM_SRC="${SCRIPT_DIR}/../ffi/android_shims.c"
SHIM_O="${HOME}/.cache/runewright/android_shims/arm64-android.o"
if [[ ! -f "${SHIM_O}" ]] || [[ "${SHIM_SRC}" -nt "${SHIM_O}" ]]; then
  mkdir -p "$(dirname "${SHIM_O}")"
  # -fno-emulated-tls: NDK clang defaults to emulated TLS (__emutls_v.* call-
  # based thread-locals) for this target config, which doesn't touch the real
  # PT_TLS segment. The over-aligned dummy TLS variable in this file (see its
  # comment) only forces correct PT_TLS placement if it's *real* ELF TLS,
  # matching what Rust's std already emits.
  "${NDK_CC}" -fno-emulated-tls -c "${SHIM_SRC}" -o "${SHIM_O}"
fi

# Shim: explicit instantiation of std::basic_streambuf<char>, providing
# seekpos/seekoff symbols missing from Zig's bundled libc++.a (M3.4 finding —
# only surfaces when linking a binary target, not the cdylib FFI build).
# Must be compiled with Zig's own c++ (matching __1 ABI), not NDK clang++.
CPP_SHIM_SRC="${SCRIPT_DIR}/../ffi/android_shims_streambuf.cpp"
CPP_SHIM_O="${HOME}/.cache/runewright/android_shims/arm64-android-streambuf.o"
if [[ ! -f "${CPP_SHIM_O}" ]] || [[ "${CPP_SHIM_SRC}" -nt "${CPP_SHIM_O}" ]]; then
  ZIG_BIN="$(command -v zig || true)"
  if [[ -z "${ZIG_BIN}" ]]; then
    DETECTED_ZIG=$(find "${HOME}" -maxdepth 1 -iname 'zig-*' -type d 2>/dev/null | sort -V | tail -1)
    [[ -n "${DETECTED_ZIG}" && -x "${DETECTED_ZIG}/zig" ]] && ZIG_BIN="${DETECTED_ZIG}/zig"
  fi
  if [[ -z "${ZIG_BIN}" ]]; then
    echo "ERROR: zig not found (checked \$PATH and ~/zig-*). Needed to compile ${CPP_SHIM_SRC}." >&2
    exit 1
  fi
  mkdir -p "$(dirname "${CPP_SHIM_O}")"
  # -fno-sanitize=all: zig c++ enables UBSan checks by default, which emit
  # calls to __ubsan_handle_* runtime symbols. We're not linking via zig (the
  # final link is NDK clang, below), so those symbols would be undefined.
  "${ZIG_BIN}" c++ -target aarch64-linux-android \
    -isystem "${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/include" \
    -isystem "${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/include/aarch64-linux-android" \
    -D__ANDROID_API__=24 -O2 -fno-sanitize=all \
    -c "${CPP_SHIM_SRC}" -o "${CPP_SHIM_O}"
fi

# Filter NDK's -lc++ and -lc++_shared (both use __ndk1 namespace, incompatible).
# We inject Zig's static libc++ (__1 namespace) explicitly below.
args=()
for arg in "$@"; do
  [[ "$arg" == "-lc++" || "$arg" == "-lc++_shared" ]] && continue
  args+=("$arg")
done

exec "${NDK_CC}" \
  "${args[@]}" \
  "${SHIM_O}" \
  "${CPP_SHIM_O}" \
  -Wl,-u,runewright_tls_align_force \
  "${ZIG_LIBCXX_DIR}/libc++.a" \
  "${ZIG_LIBCXX_DIR}/libc++abi.a" \
  "${ZIG_LIBCXX_DIR}/libunwind.a"
