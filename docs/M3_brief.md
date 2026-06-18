# M3 — Brief: Real v2.4 Circuit + Production Flutter Integration

You are starting M3. **Do not begin building yet.** First orient against the repo's canonical sources, produce a gap analysis and a dependency-ordered plan, and wait for approval. This milestone is large; the cost of a wrong structural assumption is high, so the short-leash discipline (orient → propose → wait → execute) applies throughout, especially for circuit changes.

## Where the project is

The M2 spike concluded **GO** on on-device proving. On a Pixel 6 (8 GB), the Phase 1.5 proxy circuit `ca_lookup_v2` proved at T=12 / T=24 / T=48 in ~8.9 / ~16.9 / ~32.2 s with ~717 MB / ~1.18 GB / ~2.10 GB peak RSS, all verified. Those numbers are a **floor** — they come from the proxy circuit, not the real v2.4 circuit, which adds gates (see scope). See `docs/M2_findings.md` for the full closeout, including the integration risk map and the proven production stack.

The proven proving core is **`zkpassport/noir_rs` at v1.0.0-beta.20-1** (barretenberg-rs 4.2.0-aztecnr-rc.2), which matches the main toolchain (nargo beta.20). **The beta.19 detour from the spike is retired** — compile v2.4 with the main beta.20 toolchain, no isolated environment.

## Read these first (ground truth — your gap analysis must be grounded in them, not in this brief)

- The v2.4 design document (CA rules, dominance system, tiers, commitment scheme).
- `CIRCUIT_IO.md` — the byte-level I/O contract; specifically §8 (public inputs), §10.1 (boolean constraints), §10.2 (buffer/border init), §7 (masking model), §1–2 (element ordering, cell ordering).
- `GOLDEN_VECTORS.md` — the two-oracle harness spec.
- `CLAUDE.md` — invariants and scope fence.
- The existing circuits `circuits/ca_lookup_v2/` and `circuits/ca_natural_v2/`, and the M1 stepper oracle in `lib/engine/` (`stepper.dart`, `ca_run.dart`, `ca_rules.dart`).
- `test/engine/ca_run_test.dart` — in particular the three tests tagged `phase15_divergence` (run `flutter test --tags phase15_divergence`). These assert, via `isFalse`, that the current circuit rules diverge from `ca_rules.dart`. **When you align the circuit rules in M3, these flip to passing — that flip is your signal to remove the `isFalse` wrappers.** They document exactly what must change: the circuit's birth conditions are too broad relative to the Dart canonical.

If anything in this brief conflicts with those sources, the sources win. Flag the conflict; do not silently follow this brief.

## Invariants that must not be broken

1. **Two-oracle discipline.** CA simulation outputs come from `stepper.dart` / `ca_rules.dart` (Dart is canonical). Commitments come from the Noir side only. **Never compute or reimplement a commitment (Poseidon2) in Dart** — the client reads the commitment from the proof's public inputs and treats it as opaque. The golden-vector harness validates Dart CA outputs against circuit CA outputs; commitments are checked on the Noir side, never cross-checked in Dart.
2. **Dart is canonical for CA rules.** When circuit and Dart disagree, fix the circuit. The `phase15_divergence` tests define the current disagreements.
3. **Version alignment.** Compile v2.4 with nargo beta.20 (matches the zkpassport/noir_rs beta.20 production core). Do not reintroduce beta.19.
4. **Cost is provisional until re-measured.** Any gate-count change moves proving time and memory. The tier-48 GO is "GO on 8 GB, open question on 4 GB" and assumes the proxy's gate count; the real circuit must be re-measured.

## Scope of M3 (verify exact details against the sources above)

**A. The real v2.4 circuit**, replacing the `ca_lookup_v2` proxy. Land it in new per-tier directories (e.g. `circuits/ca_v2_4_tier12/`, `_tier24/`, `_tier48/`). It adds, on top of the proxy's lookup-optimized CA loop:
- Rule alignment to `ca_rules.dart` (narrow the circuit birth conditions; flip the three `phase15_divergence` tests).
- §10.1 boolean constraints on all 469 cells.
- §10.2 buffer/border initialization constraints.
- §7 border-activation masking to `gen < T` (the neg_mask_abuse backstop).
- The bit-packed Poseidon2 commitment per `CIRCUIT_IO.md` (grid-only, bit-packed to 2 fields — confirm exact construction from the spec; it differs from the proxy's `sponge(grid || T)`).
- The full §8 public-input structure. **Confirm from the spec whether `owner_pubkey` is wired in M3 or deferred** — owner-binding (`commitment = Poseidon2(grid || owner_pubkey)`) and per-match signing belong to the later networking/identity layer, and no identity module exists yet (the §5 Ed25519 byte order is still `[CONFIRM when identity module is added]`). Do not invent an identity module here.
- Three discretely compiled tiers, `T_max ∈ {12, 24, 48}`, each with its own VK, `T` as a public input within the tier, masking applied to the actual `T ≤ T_max`.

**B. Cost re-validation.** Measure v2.4 gate counts per tier and compute the delta vs `ca_lookup_v2`. Re-measure tier-48 proving time and peak RSS on device with the real circuit; surface the 4 GB question explicitly.

**C. Production Flutter integration** — wrap `zkpassport/noir_rs` beta.20 with flutter_rust_bridge directly (not the zkmopro fork). Gated by the Step-0 check below.

## Immediate cheap gate — run this in parallel with orientation (~30 min)

**Step 0 — zkpassport API read.** Read the `zkpassport/noir_rs` (beta.20-1) Rust source and confirm the prove / verify / setup_srs surface — plus SRS bytes and circuit size — are exposed as public Rust API *above* the Kotlin/JNI boundary, sufficient for an `SRS_CACHE` + per-thread SRS-reinit pattern (barretenberg's SRS is thread-local; FRB dispatches across pool threads). This single fact decides whether the production integration (track C) is ~1 day of plumbing or a fork-patch/reimplement effort. Report the finding before proposing the track-C plan. If the useful surface only exists above JNI, the architecture decision reopens (patch the fork vs. fall back to a Kotlin platform channel — the proven Phase 2 path).

Reusable from the spike for track C: the Zig/NDK link recipe in `scripts/build_android_ffi.sh`, the `SRS_CACHE` / `reinit_srs_on_thread()` pattern, and the FRB codegen flow (`crate::api::prover` module layout, FRB pinned at v2.12.0). The `zkpassport` `build.rs` arm64-android download is the bounded risk; the `BB_LIB_DIR` workaround is the escape hatch.

## Suggested decomposition (refine this in your proposal — it's a starting point, not a mandate)

- **M3.0** — Orient: gap analysis (current `ca_lookup_v2` state vs. v2.4 target, per CIRCUIT_IO section), plus the Step-0 result. Propose the ordered plan. **Wait for approval.**
- **M3.1** — Stand up a single-command iteration loop (recompile circuit → regenerate VK → run golden vectors). Build v2.4 at the smallest tier (`T_max=12`) first: align rules, add §10.1/§10.2/masking/packed commitment/§8 public inputs. Validate against the two-oracle golden-vector harness; confirm the three `phase15_divergence` tests flip and remove their `isFalse` wrappers.
- **M3.2** — Replicate to tiers 24 and 48; measure gate counts; report the v2.4-vs-proxy delta.
- **M3.3** — Re-measure tier-48 on device (time + peak RSS); address the 4 GB question.
- **M3.4** — Track-C production FRB integration on zkpassport/noir_rs beta.20 (per Step-0 outcome).

## Definition of done (high level)

The three v2.4 tier circuits compile under beta.20, pass the two-oracle golden-vector harness with no remaining rule divergences, and produce proofs that verify against their VKs. Gate-count delta vs the proxy is documented. Tier-48 is re-measured on device. The production integration path is either built (track C) or has a clear, decided plan if Step 0 reopened it.

## Explicitly out of scope (later phases)

- Owner-binding commitment (`grid || owner_pubkey`) and per-match signing — networking/identity layer.
- The identity module / Ed25519 wiring.
- Any iOS build (kept *open* by the one-Rust-core FRB choice, but not built here).
- Talewright / narrative addon.

---

Start by reading the canonical sources and running Step 0. Then come back with the gap analysis and proposed plan, and wait for approval before building the circuit.
