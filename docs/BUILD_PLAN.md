# Runewright — Crypto-Core Build Plan (no-deadline cut)

*The dependency-ordered milestone sequence for building the cryptographic core with Claude
Code. Each milestone has a hard **acceptance criterion** — "done" means the criterion is
green, not "the code looks finished." Effort estimates are rough shape, not promises;
there is no external clock now (see Context), so the order optimizes for de-risking, not
for racing a date.*

---

## Context (why this cut changed)

The earlier plan front-loaded the circuit to hit a security review by a fixed date. That
date is gone: the model we were targeting for review (Fable) was pulled from availability,
indefinitely, so the review is now a "when a capable reviewer exists" step rather than a
deadline. **The safety mechanism was never the reviewer anyway — it's the negative
vectors** (the things the circuit must *reject*), and those are ours regardless.

With no clock, the smart move is to **fail fast on the riskiest remaining item first.**
Mobile proving itself is a supported path (`noir_rs` + the Swoir/noir_android wrappers), so
the risk isn't *feasibility* — it's the Flutter/Dart glue and whether the biggest circuit
tier fits on a phone. This cut pulls that spike forward, right after the foundational work,
before we invest in the full circuit.

---

## Glossary (jargon used below)

- **Cellular automaton (CA):** the grid simulation at the heart of the game — cells turn
  on/off each generation by fixed rules. `stepper.dart` is its reference implementation.
- **Zero-knowledge proof (ZK proof):** a proof that a computation ran correctly *without
  revealing its secret inputs* — here, proving your spell simulated correctly without
  showing your secret grid.
- **Circuit:** the program, written in Noir, that the ZK proof is *about*. Its size is
  measured in **gates** (the **gate count** sets proving time and memory).
- **Witness:** the private inputs to a proof — here, the secret initial grid.
- **Noir / `nargo`:** the language the circuit is written in (Noir) and its command-line
  tool (`nargo`).
- **Barretenberg / `bb`:** the proving backend (it actually generates/verifies the proof)
  and its command-line tool (`bb`). Backend type: UltraHonk.
- **Verification key (VK):** a small public artifact a verifier needs to check proofs from
  one specific circuit. Three circuit tiers → three VKs.
- **Poseidon2:** the ZK-friendly hash function used to compute the grid commitment.
- **Ed25519:** the digital-signature scheme used for player identity keys (off-circuit).
- **Foreign function interface (FFI):** the bridge that lets Dart (the app language) call
  the native Rust proving code. `noir_rs` is the Rust crate that proves/verifies Noir
  circuits; **Swoir** (iOS) and **noir_android** (Android) are its mobile wrappers;
  `flutter_rust_bridge` is the tool that auto-generates a Dart↔Rust binding.
- **SRS (structured reference string):** a one-time public setup artifact the prover needs;
  bundled with the app or downloaded.
- **Spike:** a short, throwaway piece of work whose only goal is to answer one risky
  question (e.g., "can we even prove on a phone?"), not to ship polished code.
- **Tracer bullet:** a thin end-to-end slice that pierces every layer once (here:
  inscribe → prove → store → verify), proving the whole pipeline connects.
- **Golden vector / corpus:** a known input with its frozen correct output (golden
  vector); the whole collection is the corpus. See `GOLDEN_VECTORS.md`.
- **Continuous integration (CI):** the automated test runner that runs the vector corpus
  on every change.
- **Green / yellow band:** your Phase 1 performance classification — green ≈ comfortable
  mobile proving, yellow ≈ slow-but-acceptable (1–3 min) inscription proving.

---

## Pre-build scaffolds (authored with Soren)

- `CIRCUIT_IO.md` — the byte-level input/output contract for the circuit. ✅
- `CLAUDE.md` — invariants, canonical-source rules, scope fence (Claude Code reads it). ✅
- `GOLDEN_VECTORS.md` + `seeds.example.json` — the test-vector harness spec + schema. ✅
- `bootstrap.sh` — toolchain setup script. ← write in M0.

---

## Milestones

### M0 — Repo skeleton + CI + bootstrap  ·  ~0.5 day
**Goal:** a repo Claude Code can work in, with the test-vector runner wired into continuous
integration (CI) from day one — even against an empty corpus, so the discipline exists
before there's anything to test.
**Tasks:** reconcile the proposed folder layout against the existing repo; add the scaffold
docs; write `bootstrap.sh` (installs Flutter, `nargo`, `bb`, and the Rust/FFI toolchain);
stub `scripts/run_vectors.sh`.
**Acceptance:** `bootstrap.sh` produces a working toolchain on a clean machine; CI runs the
vector script green on an empty corpus.

### M1 — Stepper reconciliation + first golden vector  ·  ~1.5 days
**Goal:** close every `[CONFIRM vs stepper]` gap in the contract and produce one real,
frozen test vector. Also orients Claude Code in the codebase.
**Tasks:** work the `CIRCUIT_IO.md` §13 checklist against `stepper.dart` (element numbering,
cell ordering, buffer/border index ranges, Ed25519 key byte order, the masking model);
regenerate `CIRCUIT_IO.md` and emit `GRID_ORDERING.md` *from* the stepper; author the two
hand-checkable anchor vectors; confirm the stepper reproduces them.
**Acceptance:** the two anchors show all-zero CA outputs and the Dart stepper-regression
test passes on them. (Commitment values stay as `IMPL` placeholders until M3 wires the Noir
hash — see `GOLDEN_VECTORS.md` §0.1.)

### M2 — FFI spike: noir_rs → Flutter, desktop → phone  ·  ~1–3 days  ·  ⚠ de-risk
**Goal:** answer the narrowed risky question early — *can we drive `noir_rs` from Flutter
and does the biggest tier fit on a phone?* — using the **existing Phase 1.5 circuit**
(already benchmarked and proving on desktop). Mobile proving itself is a supported path
(see below), so this is plumbing + one perf check, not a feasibility hunt. It's a spike:
throwaway wiring, not the real pipeline, and it does **not** depend on the not-yet-built
v2.4 circuit, so it runs before M3.
**Context (why this is bounded, not existential):** `zkpassport/noir_rs` proves/verifies
Noir circuits on-device via UltraHonk, with maintained mobile wrappers — **Swoir** (iOS)
and **noir_android** (Android) — and documented Android cross-compilation. The gap is that
none of those wrappers is Dart, so the work is the Flutter glue, plus confirming the
largest tier's cost.
**Tasks:** stand up the Dart↔Rust bridge over `noir_rs` — either `flutter_rust_bridge`
(auto-generated binding directly over noir_rs) or a Flutter **platform channel** to the
Kotlin **noir_android** layer; pin `nargo`/`bb` to versions matching the noir_rs tag
(it's on `v1.0.0-beta.19-1`; Phase 0 used beta.20 — reconcile); handle the SRS (structured
reference string) on device (bundle or download); call prove + verify from Dart on desktop
first, then on a ≥4 GB Android device; **measure the 48-generation tier (~943k gates)
specifically** for proving time and peak memory.
**Acceptance:** a Dart-driven round trip (build witness → prove → verify) succeeds on a
phone, and the 48-tier's proving time + peak memory are recorded and acceptable. (The 12/24
tiers are effectively pre-validated by the ~24 s / 409k Pixel 6 smoketest; the 48-tier is
the real measurement.)
**If it fights you:** the likely friction is version skew or the Dart binding, not
feasibility. Fallback order: try the platform-channel route to noir_android if
flutter_rust_bridge resists; reconcile toolchain versions; if the 48-tier specifically
blows the memory budget, ship 12/24 now and treat 48 as hardware-improves-over-time (or a
design conversation). Don't push past a hard wall silently — stop and flag it.

### M3 — Circuit to the v2.4 I/O spec, three tiers  ·  ~2 days
**Goal:** bring the benchmarked circuit up to the full contract.
**Tasks:** grid packing (469 cells → 2 field elements) and `commitment = Poseidon2(packed)`;
the §8 public inputs (`owner_pubkey = Poseidon2(key halves)`, `ruleset_version`, masked
`border_activations`, padded trajectory/flags); supreme-dominance-flag output; build the
three tier circuits (max generations 12 / 24 / 48) from one parameterized source; wire the
generator so it fills the `IMPL` commitments *from the Noir side, never Dart*.
**Acceptance:** all three tiers compile; gate counts land near projection
(~236k / 472k / 943k); the commitments fill in; the **positive** vectors verify.

### M4 — Full corpus, positive AND negative  ·  ~1.5 days  ·  ★ SECURITY-REVIEW-READY
**Goal:** the reviewable core — the circuit rejects everything it must.
**Tasks:** implement the §10 constraints, **each paired with the §11 negative vector** that
fails if the constraint is dropped (red before, green after); build the priority
`neg_mask_abuse` vector with stepper help; run the Noir runner across all tiers.
**Acceptance:** every positive vector verifies *and* every negative vector **fails to
verify**, across all three tiers, in CI. ← This is the artifact a security reviewer (a
restored Fable/Mythos, another frontier model, or a human auditor) would examine.

### M5 — Tracer bullet (real circuit, on device)  ·  ~1–2 days
**Goal:** the full vertical slice with the *real* v2.4 circuit, reusing the FFI path proven
in M2.
**Tasks:** wire the M3/M4 circuit through the M2 bridge; add minimal on-device persistence
(store the proof + public inputs + grid).
**Acceptance:** on a ≥4 GB Android device, **inscribe a grid → prove → persist → verify**
end to end.

---

## Critical path & risk

```
M0 → M1 → M2 ⚠ (FFI spike, the unknown)
              └→ M3 → M4 ★ (review-ready) → M5
```

- **M2 is the early de-risk.** It uses the existing circuit, so a Dart-integration snag or a
  48-tier memory problem surfaces *before* the full circuit work — the reason it was pulled
  forward. (Feasibility itself is not in question; noir_rs + noir_android already prove on
  phones.)
- **If M2 is easy:** momentum straight into the core (M3/M4), and M5 is mostly assembly.
- **If M2 is hard:** you've learned the expensive thing first and can pivot the approach
  before sinking days into M3.
- **M4 stays the review-ready gate.** The negative vectors are the point; never cut them.
- **No deadline pressure** — pace is sustainable. If you want, the 24- and 48-generation
  tiers in M3 can come after a 12-tier-only first pass; the contract and vectors are
  tier-agnostic, so that costs nothing structurally.
- **Scope fence holds:** anything on the `CLAUDE.md` out-of-scope list that starts to look
  necessary is a signal to stop and confirm, not to build.

---

## Definition of done for "security-review-ready" (the M4 gate)

- [ ] `stepper.dart` and the circuit agree on the full positive corpus (both runners green).
- [ ] Every §11 negative vector fails to verify, across all built tiers.
- [ ] Each §10 constraint demonstrably load-bearing (its negative goes red if dropped).
- [ ] `neg_mask_abuse` exists and fails (the priority spell-leak case).
- [ ] `CIRCUIT_IO.md` reconciled against the stepper (no `[CONFIRM]` left on the path).
- [ ] Commitments come from Noir, never Dart (the no-Poseidon2-in-Dart invariant intact).
