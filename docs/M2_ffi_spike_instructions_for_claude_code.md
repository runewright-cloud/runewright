# M2 — FFI Spike: Flutter Proving Round-Trip + Tier-48 Measurement

## Goal

De-risk the on-device proving path: get one Dart → native → proof → verify round-trip working on a physical Pixel 6 via **flutter_rust_bridge (the Mopro / noir-rs path)**, and measure the proving cost of the largest tier so we know whether tier 48 is viable on-device.

This is a spike. It deliberately uses the disposable Phase 1.5 circuit (`ca_lookup_v2`, already compiled and proven). It does **not** build or touch the real v2.4 circuit — that's M3.

## Status going in

- M0+M1 complete; test suite is green (`+25 -0`) after the `phase15_divergence` inversion fix.
- Toolchain: nargo 1.0.0-beta.20, bb 5.0.0-nightly.20260324.
- Phase 2 already established the Pixel 6 (Tensor G1) can generate valid UltraHonk proofs (~24 s at ~T=20 scale, ~8x slower than the NUC). So "can the phone prove at all" is **already retired** — M2's open risks are the **Flutter+FRB integration** and the **tier-48 ceiling**, not basic feasibility.
- Phase 1.5 recommended circuit: `ca_lookup_v2` (409k gates at T=20, green; ~1M gates at T≈50, yellow). Use `ca_lookup_v2`, not `ca_natural_v2`.

## Numbering note (read this)

The repo carries two numbering schemes. The current operative one is the M-series (M0 skeleton → M1 stepper oracle → M2 FFI spike → M3 real v2.4 circuit). The older docs' "Phase 2 = mobile integration" overlaps M2/M3. The older docs' **"Phase 3 = noir_android Kotlin platform channel" is SUPERSEDED** — we chose flutter_rust_bridge / Mopro instead. Do not follow any Kotlin-platform-channel plan, and do not scaffold a standalone Android Studio / Kotlin project (that *is* the rejected path).

---

## Gating first step — version-alignment check (do this before any build work)

The mobile prover is pinned far behind our toolchain (it targets bb ~0.82 / 1.0-nightly-2025; we're on bb 5.0.0-nightly.20260324). Expect the formats not to match on first contact. Resolve the question with data before building anything:

1. Clone `zkmopro/noir-rs` and read its **actual** branches/tags — the docs page may lag the repo. Record the newest supported nargo + bb it can pull.
2. Attempt to load and prove our existing `ca_lookup_v2` bytecode through noir-rs's bb, then verify the resulting proof against our existing VK. Use `prove_ultra_honk` (Poseidon2, off-chain) — **not** the `_keccak` variant; keccak is for on-chain Solidity verifiers, which we don't have.
3. Classify the outcome:
   - **Loads + verifies against our VK** → no gap, proceed.
   - **Loads but won't verify** → proof/format drift; investigate and report before proceeding.
   - **Won't load** (most likely) → do *not* downgrade the main toolchain. See remedy below.

**Remedy if it won't load (spike-only):** in an *isolated* environment (separate nargo via `noirup -v <version>`, separate checkout — do not change the project's main toolchain), compile a circuit under the version noir-rs supports. Stage it:
- First prove noir-rs's bundled trivial example (`a*b=res`) to confirm the FFI plumbing works at all.
- Then recompile `ca_lookup_v2` under the compatible nargo and prove that, for a representative gate count.

**Do not downgrade the main toolchain to close the gap.** Downgrading drags the real circuit onto an older compiler and — critically — older bb, losing the UltraHonk proving-performance improvements, which would make the tier-48 numbers *worse* (the opposite of what we're measuring). Aligning noir-rs *up* to bb 5.0-nightly (newer branch, or building bb-android at our version) is an **M3** decision, not now.

Caveat to record: timings taken against the old bb are a representative-but-not-exact proxy. bb 5.0 should be faster/leaner, so old-bb numbers are a mild pessimistic bound — fine for a go/no-go, but flag it as such.

---

## Build directives

- **Path:** flutter_rust_bridge over noir-rs, via the Mopro Flutter template. One Rust core (noir-rs targets both `aarch64-linux-android` and `aarch64-apple-ios`, keeping the iOS option open).
- **One workspace.** Build, deploy, and run from VS Code + CLI (`flutter run -d <pixel6>`, mopro / cargo-ndk build steps). No separate Android Studio project.
- **Proving runs off the UI thread.** It's a multi-second-to-tens-of-seconds blocking call; on the Flutter main isolate it ANRs. Background isolate / native thread.
- **SRS sizing.** noir-rs's default SRS covers up to 2^18 (~262k) constraints. `ca_lookup_v2` at T=20 (409k) already exceeds that, and tier 48 (~1M) needs roughly 2^20. Fetch the circuit-specific SRS via noir-rs's `srs_downloader` and bundle/make it available on-device. This is a real gotcha — the default SRS silently won't cover the circuit. The SRS also feeds the APK-size number below.
- **Commitments stay opaque on the Dart side.** Do NOT reimplement Poseidon2 in Dart. The stale Phase 1.5 report note ("the Dart side will need to implement the same sponge") is superseded by design doc v2.3: the client reads the commitment from the proof's public inputs and compares values; it never computes the hash. Proof verification is bb's job. If anything pulls you toward a Dart Poseidon2, stop — that's out of scope and contradicts the design.

---

## The tier-48 measurement (human-in-the-loop)

Claude Code cannot tap the phone or read the Android Studio Profiler GUI. So instrument the measurement to emit numbers programmatically; Soren runs it on the device and reports back.

- **Instrument the prove call** to log, to logcat/stdout: wall-clock around the call, and peak resident memory read from the native side (`VmHWM` in `/proc/self/status`, or equivalent native heap API). The deliverable is a logged figure to copy, not a graph to eyeball. Android Studio's Profiler is an optional cross-check only.
- **Release/profile mode only.** Debug-mode Flutter + debug Rust is wildly slower and heavier and the number would be meaningless.
- **Tier 48 = `ca_lookup_v2` compiled at T=48** (~1M gates) as the proxy for the v2.4 top tier. Also capture tier 12 and tier 24 (T=12, T=24) for the full curve.
- **The tier-48 number is a FLOOR.** The real v2.4 circuit adds boolean constraints (469 cells), border masking, the bit-packed Poseidon2 commitment, `owner_pubkey`, and `ruleset_version` — all extra gates on top of the CA loop. So if the Phase 1.5 proxy at T=48 is already near the device ceiling, v2.4 tier 48 will exceed it. Interpret as best-case; real circuit is worse. (Conservative, correct direction for a go/no-go.)
- **APK size delta.** Record the size added by bundling the aarch64 bb `.so` plus the SRS. Relevant to the sideload / donation-only ethos.

---

## Acceptance gate

1. A Flutter app on the physical Pixel 6, **release mode**, generates a valid proof for `ca_lookup_v2` via flutter_rust_bridge, and the proof **verifies** against the VK.
2. The version triple (nargo / bb / noir-rs) used for the spike is documented, with the outcome of the gating check and any isolated-environment workaround clearly noted.
3. Tier 12 / 24 / 48 proving measured on-device: wall-clock + peak RSS for each. Clear **PASS** (tier 48 completes without OOM) or **FAIL** (and the tier at which it falls over). Floor caveat stated.
4. APK size delta recorded.
5. Proving demonstrably runs off the UI thread (no ANR during a prove).

---

## Explicitly NOT in M2

- The real v2.4 circuit (M3).
- v2.4 witness / public-input marshalling. This spike de-risks toolchain, linking, FRB bindings, threading, SRS handling, and Flutter packaging — **not** the final v2.4 data layout, which has a different commitment, extra public inputs (`owner_pubkey`, `ruleset_version`, masked activations), and tiers. Expect the FFI interface to be reworked at M3; size the spike accordingly.
- Aligning noir-rs up to bb 5.0-nightly (M3 decision).
- Cloud proving (later, contingent on these results).

---

## Stop-and-ask conditions

Halt and report rather than pushing through if:

- noir-rs cannot be made to prove *any* circuit on-device after a reasonable effort — this is a path-viability problem worth surfacing before more work.
- Tier 48 OOM-kills on the Pixel 6 even in release mode — report the tier at which it fails and the peak RSS, so the tier ceiling can be redesigned (the tier system exists precisely to contain this).
- The gating check shows proofs load but won't verify against our VK — that's a correctness/format issue, not a perf issue; diagnose before building UI around it.
- Anything requires reimplementing Poseidon2 in Dart, or scaffolding a Kotlin/Android Studio project — both are out of scope and signal a wrong turn.
