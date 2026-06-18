# M2 — FFI Spike Findings & Closeout

## Verdict: GO

On-device UltraHonk proving is viable on the target hardware. All three tiers complete and verify on a Pixel 6. The top tier (T=48) is confirmed as an opt-in spectacle tier with a hardware caveat (below).

## Measurements

Device: Pixel 6 (Tensor G1, 8 GB RAM, Android 16, AArch64).
Circuit: `ca_lookup_v2` (the Phase 1.5 proxy circuit), compiled at nargo beta.20.
Stack that produced these numbers: `zkpassport/noir_rs` v1.0.0-beta.20-1 via the **noirandroid** Kotlin library, `barretenberg-rs 4.2.0-aztecnr-rc.2`.

| Tier | wall_ms | peak RSS | verified |
|------|---------|----------|----------|
| T=12 | 8,926   | ~717 MB  | ✓ |
| T=24 | 16,853  | ~1,175 MB | ✓ |
| T=48 | 32,240  | ~2,104 MB | ✓ |

Scaling is clean and roughly linear in T: ~8.4 s per 12 generations of time, ~45–60 MB RSS per generation. Peak RSS at T=48 (~2.1 GB) sits well inside the Pixel 6's 8 GB.

## Two caveats that must travel with these numbers

Both push the *real* shipping cost above the table.

1. **Floor caveat — this is the proxy circuit.** `ca_lookup_v2` lacks the v2.4 additions: boolean constraints on all 469 cells, border-activation masking, the bit-packed Poseidon2 commitment, `owner_pubkey`, and `ruleset_version`. Those add gates on top of the CA loop, so v2.4 at T=48 will cost more than 2.1 GB / 32 s. The exact multiplier is unknown until the v2.4 circuit exists (M3) and its gate count is measured against `ca_lookup_v2`.

2. **4 GB edge.** 2.1 GB is comfortable on an 8 GB device. On the project's stated 4 GB floor, 2.1 GB plus Android's own footprint, the Flutter engine, and the v2.4 increment is close to the edge — and Android terminates the foreground app under memory pressure without warning. So the honest reading is **GO on 8 GB; open question on 4 GB for the top tier.** Tiers 12 and 24 are comfortable everywhere.

## Tier-48 decision (ratified)

T=48 stays as the opt-in spectacle tier. The <8 GB risk is surfaced to players rather than designed around — interested users are warned that inscribing mega-spells may fail on lower-RAM hardware ("time to upgrade your spellbook from parchment to vellum"). Everyday play (tiers 12/24) is unaffected and fits the 4 GB floor. Mitigations held in reserve for the top tier on constrained devices: `low_memory` proving mode, and a re-measurement on an actual 4 GB device before promising T=48 there (deferred to M3).

## Integration risk map (what the spike actually surfaced)

The spike's primary value beyond the numbers was clearing integration landmines on a throwaway circuit instead of on the real one at M3.

1. **libc++ ABI wall (resolved).** `barretenberg-rs`'s prebuilt static lib uses upstream-LLVM libc++ (`__1` inline namespace); the Android NDK's `libc++_shared.so` uses the incompatible NDK fork (`__ndk1`). Bundling or static-linking the NDK runtime cannot work — zero symbol overlap. **Resolution:** link the final `.so` with Zig (0.14.x), which statically satisfies the `__1` symbols from its own libc++ — the same way Aztec builds `bb` for Android. This is now the production Android link recipe, captured in `scripts/build_android_ffi.sh`.

2. **Two-fork reality (the key finding).** Two on-device stacks exist and must never be confused:
   - `zkpassport/noir_rs` (beta.20-1, via noirandroid Kotlin) — **works**, and matches the main-toolchain beta.20 circuits with no recompile.
   - `zkmopro/noir-rs` (beta.19 era, via flutter_rust_bridge / Mopro) — **crashed** with `std::out_of_range("vector")` in the circuit builder, on both `compute_vk` and `prove`.
   Both pin the *same* `barretenberg-rs 4.2.0-aztecnr-rc.2`. Since that binary proved successfully on this exact device via the zkpassport path, **the barretenberg arm64-android binary is not broken** — the crash is specific to the zkmopro fork / beta.19 / hand-zig-linked path. The proven core is `zkpassport/noir_rs` at beta.20.

3. **Fork-choice course correction.** Mopro was originally chosen for its turnkey Flutter template, which dragged in the older beta.19 pin and the crashing fork. Corrected approach: take the measurement via the proven path now, and target the production Flutter integration at the proven core (`zkpassport/noir_rs` beta.20) wrapped with FRB directly — FRB binds any Rust crate; Mopro's specific fork is not required.

4. **Phase 2 setup gotchas (carry forward).** noirandroid needs hex-string witness inputs (`"0x0"`, `"0x1"`), the `INTERNET` permission for the SRS download from `crs.aztec.network`, and a `Theme.AppCompat` theme or it hard-crashes on launch.

## Production integration plan (M3 lead-in)

Goal: a Flutter production path on the proven core, with iOS kept open. **iOS cross-play is a confirmed live goal** — a single Rust core via FRB (zkpassport/noir_rs supports `aarch64-apple-ios`) is the reason to invest the integration days rather than ship the working Kotlin path Android-only. The motivation is explicit: avoid dividing players by platform.

**Step 0 — gating API read (do before any wrapping work).** Read the `zkpassport/noir_rs` Rust source and confirm the prove/verify/setup_srs surface, plus SRS bytes and circuit size, are exposed as public Rust API *above* the Kotlin/JNI boundary — enough for the `SRS_CACHE` + per-thread SRS reinit pattern. This single check decides whether the integration is ~1 day or ~1 week. If the useful surface only exists above JNI, the fork must be patched or reimplemented and the estimate breaks.

**Reusable from the spike (the hard parts, already solved):**
- Zig/NDK link recipe in `build_android_ffi.sh`.
- `SRS_CACHE` + `reinit_srs_on_thread()` pattern (barretenberg SRS is thread-local; FRB dispatches across pool threads).
- FRB codegen flow and the `crate::api::prover` module structure; FRB pinned at v2.12.0.

**Bounded risks:**
- `zkpassport/noir_rs` `build.rs` arm64-android artifact download — may need the `BB_LIB_DIR` workaround already proven against the zkmopro fork. Escape hatch exists; costs hours, not days.
- FRB version compatibility with the zkpassport fork.

**Estimate:** 1–2 days of focused work, contingent on Step 0. Main risk is the zkpassport `build.rs` Android behavior and the API-surface question.

## CA rule iteration (forward note)

Playtesting is expected to drive rule tuning, and the architecture supports it cheaply. The proving pipeline is rule-agnostic — none of the integration work above is touched by a rule change. A rule change is: edit `ca_rules.dart` and the Noir circuit *in lockstep*, regenerate constants/lookup table, recompile, regenerate the VK, and re-run the M1 golden-vector harness (which enforces Dart↔circuit agreement). The only non-free part is cost re-validation: value tweaks within the existing rule structure leave the gate count (and thus tier costs) roughly unchanged, while structural changes (new rule variants, more dominance states, more black-box ops) grow the lookup table and gate count and warrant a re-measurement of the tier ceiling. Recommendation: script the recompile → regen-VK → golden-vectors loop into a single command before playtest so rule iteration is a tight inner loop.

## Explicitly NOT done in M2 (deferred to M3+)

- The real v2.4 circuit (boolean constraints, masking, packed Poseidon2 commitment, `owner_pubkey`, `ruleset_version`).
- The Flutter + FRB production integration on zkpassport/noir_rs beta.20 (scoped above, not built).
- The v2.4-vs-`ca_lookup_v2` gate-count delta, and the resulting true tier-48 cost.
- Tier-48 re-measurement on a 4 GB device.
- Any iOS build.
- Owner-binding commitment and per-match signing (networking/identity layer).
