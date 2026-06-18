# M2 FFI Spike — Build & Measurement Guide

> This document records the gating-check outcome, the version triple used, and
> the exact steps Soren needs to run on the Pixel 6 to collect the tier-48
> acceptance data.  See `docs/M2_ffi_spike_instructions_for_claude_code.md` for
> the spec that drove this work.

---

## Gating check outcome (2026-06-15)

| Item | Our toolchain | noir-rs (zkmopro/noir-rs rev 745dd15) | Compatible? |
|------|--------------|---------------------------------------|-------------|
| nargo / acvm | 1.0.0-beta.20 | 1.0.0-beta.19 | **No — bytecode format mismatch** |
| barretenberg | bb 5.0.0-nightly.20260324 | barretenberg-rs 4.2.0-aztecnr-rc.2 | **No — different version** |

**Classification: "Won't load"** — confirmed by two concrete incompatibilities:

1. `poseidon2_permutation` changed from 2-argument form (beta.19) to 1-argument form
   (beta.20); the beta.19 nargo rejected our beta.20-compiled `main.nr`.
2. Non-ASCII characters (`—`) in comments: allowed in beta.20, rejected in beta.19.

**Remedy applied (spike only):**  All three tier circuits were recompiled under the
isolated nargo beta.19 installation at `/tmp/nargo-beta19-bin/nargo` with two
source-level patches (see `Spike circuit patches` section below).  The main
codebase toolchain (beta.20 + bb 5.0.0-nightly) is **unchanged**.

**Timings note:** The proving data collected in M2 use barretenberg-rs 4.2.0.  bb
5.0.0-nightly is known to be faster/leaner, so the M2 numbers are a mild
**pessimistic bound** relative to the aligned M3 toolchain.  Flag this in any
go/no-go write-up.

---

## Version triple for this spike

```
nargo (spike only): 1.0.0-beta.19      ← isolated at /tmp/nargo-beta19-bin/nargo
barretenberg-rs:    4.2.0-aztecnr-rc.2 ← via noir-rs rev 745dd15
flutter_rust_bridge: ^2.0.0
noir-rs commit:     745dd15 (zkmopro/noir-rs, main branch tip as of 2026-06-15)
```

---

## Spike circuit patches

Two patches were applied to the ca_lookup_v2 source for beta.19 compatibility
(**spike copies only** — the source under `circuits/ca_lookup_v2/` is unchanged):

1. **Non-ASCII comment** (`—` → `--`) in `constants.nr` line 1.
2. **poseidon2_permutation** called with second arg `4` in `main.nr` (the state
   size, removed in beta.20).

The patched sources live at `/tmp/ca-spike/tier{12,24,48}/` and were compiled
with the isolated nargo beta.19.  Compiled artifacts: `ca_spike_t{12,24,48}.json`.

---

## Build steps (run on the dev machine before device testing)

### 1 — Prerequisites (one-time)

```bash
# Rust + Android target (bootstrap.sh handles this)
bash bootstrap.sh

# cargo-ndk for Android cross-compilation
source ~/.cargo/env
cargo install cargo-ndk
rustup target add aarch64-linux-android

# flutter_rust_bridge codegen tool
cargo install flutter_rust_bridge_codegen

# Android cmdline-tools (needed by flutter doctor)
# Download from https://developer.android.com/studio#command-line-tools-only
# then:
#   sdkmanager --licenses
#   sdkmanager "platforms;android-35" "build-tools;35.0.0"
```

### 2 — Generate FRB Dart bindings (one-time, or after Rust API changes)

```bash
cd /home/soren/runewright
flutter_rust_bridge_codegen generate
```

This overwrites the stubs in `lib/src/rust/` with real type-safe bindings.

### 3 — Compile the Android .so

```bash
# Set NDK path (adjust version as appropriate)
export ANDROID_NDK_HOME=~/Android/Sdk/ndk/<version>

bash scripts/build_android_ffi.sh       # release
# or
bash scripts/build_android_ffi.sh --debug   # debug (slow, for development)
```

Output: `android/app/src/main/jniLibs/arm64-v8a/librunewright_ffi.so`

Record the `.so` file size — it contributes to the APK size delta.

### 4 — Copy spike circuit artifacts to Flutter assets

```bash
mkdir -p assets/circuits
for T in 12 24 48; do
  cp /tmp/ca-spike/tier${T}/target/ca_spike_t${T}.json assets/circuits/
done
```

Add to `pubspec.yaml` under `flutter.assets`:
```yaml
  assets:
    - assets/circuits/ca_spike_t12.json
    - assets/circuits/ca_spike_t24.json
    - assets/circuits/ca_spike_t48.json
```

---

## SRS sizing

| Tier | Gate count (approx) | Required SRS points | G1 data size |
|------|--------------------|--------------------|-------------|
| 12   | ~100k              | 2^18 (~262k)       | ~16 MB      |
| 24   | ~200k              | 2^18 (~262k)       | ~16 MB      |
| 48   | ~1M                | 2^20 (~1M)         | ~64 MB      |

The default barretenberg SRS covers only 2^18.  Tier 48 **requires** the larger
SRS.  `initSrs()` calls `setup_srs_from_bytecode()` which queries the circuit's
actual gate count and fetches exactly as many points as needed.

**On-device SRS strategy for the spike:**
- First run: `initSrs()` downloads from the Aztec SRS server (~16–64 MB depending
  on tier) and caches at `getApplicationSupportDirectory()/runewright_srs.dat`.
- Subsequent runs: loads from the cache (fast, no network).
- The `.dat` file persists across app restarts but not across uninstalls.

For production, bundle the SRS in the APK or deliver it via a one-time in-app
download; the on-first-run download approach is fine for the spike.

---

## Device measurement procedure (Soren runs this)

### Setup

```bash
# Connect Pixel 6, enable USB debugging
adb devices                 # confirm device is listed
flutter devices             # should show Pixel 6

# Open a logcat filter for prove lines in a second terminal:
adb logcat -s flutter | grep RUNEWRIGHT_PROVE
```

### Run

```bash
# Release mode only — debug numbers are meaningless (5-10× slower)
flutter run --release -d <pixel6-device-id>
```

In the app, trigger a prove for each tier (12 → 24 → 48) using the spike UI
(or call `proveAndTime` programmatically from a test widget).

### Expected logcat output

```
flutter: [runewright.prover] wall=24000ms rss=850000kB proof=12345B
I/flutter: RUNEWRIGHT_PROVE wall_ms=24000 peak_rss_kb=850000 proof_len=12345
```

Record `wall_ms` and `peak_rss_kb` for each tier.

### Acceptance criteria

| Check | Criterion |
|-------|-----------|
| Tier-12 proof verified | `verifyProof()` returns `true` |
| Tier-24 proof verified | `verifyProof()` returns `true` |
| Tier-48 proof verified or OOM noted | PASS if verified; record tier at failure if OOM |
| No ANR during prove | UI remains responsive (confirm by tapping the screen during proving) |
| wall_ms logged for all tiers | Numbers in logcat |
| peak_rss_kb logged for all tiers | Numbers in logcat |

### APK size delta

```bash
flutter build apk --release
# Compare size with and without librunewright_ffi.so + SRS asset
ls -lh build/app/outputs/flutter-apk/app-release.apk
```

---

## What M3 changes about this setup

The M2 spike is intentionally disposable:

- The FFI interface (`proveAndTime`, `computeVk`, etc.) will be reworked once
  the real v2.4 circuit is built; v2.4 has additional public inputs
  (`owner_pubkey`, `ruleset_version`, masked activations) and a different
  commitment scheme.
- The barretenberg-rs version should be aligned upward to match our bb
  5.0.0-nightly toolchain.  This is an M3 decision (requires checking for a
  newer noir-rs branch or building barretenberg-rs at our bb version).
- The spike circuits (`ca_spike_tN`) are replaced by the real v2.4 three-tier
  circuit crates under `circuits/`.
- Stub files `lib/src/rust/frb_generated.dart` and `lib/src/rust/api/prover.dart`
  are replaced by the real FRB-generated output.

---

## File map

| File | Purpose |
|------|---------|
| `ffi/Cargo.toml` | Rust crate manifest; noir-rs git dep pinned to rev 745dd15 |
| `ffi/src/lib.rs` | `init_srs`, `compute_vk`, `prove_and_time`, `verify_proof` |
| `lib/ffi/prover.dart` | Dart wrapper; Isolate.run, logcat logging |
| `lib/src/rust/frb_generated.dart` | FRB codegen stub (replaced by codegen) |
| `lib/src/rust/api/prover.dart` | FRB API stub (replaced by codegen) |
| `scripts/build_android_ffi.sh` | cargo-ndk build + FRB codegen trigger |
| `/tmp/nargo-beta19-bin/nargo` | Isolated nargo beta.19 (not in repo) |
| `/tmp/ca-spike/tier{12,24,48}/` | Patched circuits compiled under beta.19 (not in repo) |
