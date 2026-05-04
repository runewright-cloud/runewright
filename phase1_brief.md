# Runewright — Phase 1 Brief

**Goal:** Determine whether the full Runewright cellular automaton circuit fits within a practical mobile proving budget, and produce the data needed to decide between local proving, cloud-assisted proving, and rule simplification.

**Status going in:** Phase 0 complete. Toolchain (nargo 1.0.0-beta.20, bb 5.0.0-nightly.20260324) verified working. Trivial Poseidon circuit and a 7-cell / 4-state / 3-generation CA stub both prove and verify cleanly on desktop. Stub came in at 2,696 ACIR opcodes.

**Out of scope for Phase 1:** No Flutter integration. No Rust FFI. No mobile builds. No on-device measurement. This phase is desktop-only Noir circuit work and benchmarking.

---

## Context

Runewright is an Android wizard duel game (Flutter/Dart) where players inscribe spells via a hexagonal cellular automaton and prove correctness of the simulation with ZK proofs (Noir/Barretenberg). The full design lives in `runewright_design.md` — read it before starting circuit work, particularly the sections on cell states, CA rules, and the cryptographic system.

The relevant facts for this phase:

- **Grid:** Hexagonal, axial (q, r) coordinates, vertex-down orientation
- **Inscribable region:** 91 cells (center + 5 rings)
- **Buffer rings 6-8:** 60 additional cells, participate in simulation but start empty
- **Border ring 9:** 18 cells, count activations but immediately deactivate (do not participate in CA rules going forward)
- **Total cells in simulation:** 169 (verify against `stepper.dart` before encoding — these counts are the design doc's intent but the canonical source is the implementation)
- **Cell states:** 13 total (Empty, Fire, Water, Earth, Air, 6 hybrids, Void, Chaos)
- **Encoding:** 4-bit field values, 0-12 with 13-15 reserved/invalid

The CA rules — pure element reproduction with directional drift, hybrid formation, Chaos corruption, Void replacement — are specified in the design doc. Implement them as written. Do not simplify rules in this phase. Measure first.

---

## Deliverables

By the end of Phase 1, this directory should contain:

1. **`circuits/ca_natural/`** — Noir crate implementing the full CA rules as a direct, readable translation of the design spec. Conditional-heavy. Optimize for clarity, not constraint count.

2. **`circuits/ca_lookup/`** — Noir crate implementing the same logical CA via lookup tables. Aggressively optimized for constraint count. See "Lookup table strategy" below.

3. **`scripts/bench_phase1.sh`** (or `.py` — whichever is cleaner) — Reproducible benchmark script that builds both circuits, runs them at T ∈ {1, 2, 5, 10, 20}, and emits `phase1_results.csv`.

4. **`phase1_results.csv`** — Output of the benchmark script, one row per (circuit_version, T) combination, columns described below.

5. **`phase1_report.md`** — Short markdown report (1-2 pages) with findings, the curve plotted (ASCII or linked PNG), regression analysis, and a recommendation.

---

## Circuit specification

### Cell encoding

```
0  Empty
1  Fire
2  Water
3  Earth
4  Air
5  FireWater
6  FireEarth
7  FireAir
8  WaterEarth
9  WaterAir
10 EarthAir
11 Void
12 Chaos
```

In Noir, represent cells as `Field` elements. Don't try to pack into smaller types — Noir's underlying constraint cost is per-Field regardless.

### Grid serialization

Use a single canonical ordering for the 169-cell flat array. Suggested: row-major over axial coordinates with rows ordered by `r` ascending, cells within a row by `q` ascending, with each row's valid `q` range determined by the hex shape.

Document this ordering in `circuits/GRID_ORDERING.md` so the eventual Dart side has a spec to match. This file is a deliverable.

### Neighbor adjacency

Hex neighbors at axial offset `(q, r)` are: `(+1, 0)`, `(-1, 0)`, `(0, +1)`, `(0, -1)`, `(+1, -1)`, `(-1, +1)`.

Precompute the adjacency table at circuit-compile time (Noir global `comptime` constants or generated source). Each cell has up to 6 neighbors; cells on the outer edge of ring 8 have fewer (some neighbors are in ring 9, which is special — see below).

### Ring 9 (border) handling

Ring 9 cells **count activations** for spell hash computation but **do not participate as neighbors** in subsequent CA generations. Implementation choice: treat ring 9 as a "write-only sink" — when a CA rule would activate a ring 9 cell, increment the per-element activation counter and leave the cell as empty for next generation's neighbor counting.

The output of the circuit must include:
- `border_activations: [Field; 6]` — counts per element (Fire, Water, Earth, Air, Chaos, Void), summed across all T generations
- `dominant_element: Field` — index of the element with the most border activations, with the Chaos/Void override per design doc

### Directional drift

Per design doc:
- Fire → upper-left (northwest)
- Air → upper-right (northeast)
- Water → lower-right (southeast)
- Earth → lower-left (southwest)
- Chaos and Void: no preference

Encode the "X's preferred growth direction" rule (an empty cell with exactly 2 neighbors of element X becomes X if the cell is in X's preferred direction relative to those neighbors) carefully — this is one of the trickier rules to get right and easy to encode in a way that explodes constraint count. In version A, prioritize correctness and readability.

### Public inputs / outputs

The circuit's public inputs:
- `commitment: Field` — Poseidon hash of (grid_state || salt)
- `T: Field` — generation count (constrained at compile time; one circuit per supported T value, OR a single circuit with T as a public input and an internal loop bound — pick one and document the choice)
- `border_activations: [Field; 6]`
- `dominant_element: Field`

Private inputs (witness):
- `grid_state: [Field; 169]` — initial inscribable region populated, buffer rings empty, ordered per `GRID_ORDERING.md`
- `salt: Field`

Constraints:
- `Poseidon(grid_state || salt) == commitment`
- Running CA for T generations from grid_state produces the declared `border_activations` and `dominant_element`

---

## Two-version mandate

### Version A — Natural translation (`circuits/ca_natural/`)

Goal: be the readable reference implementation. The code should look like the design doc rules, expressed in Noir. Use match-on-state, conditional arithmetic, whatever reads cleanly.

**Do not optimize version A prematurely.** Its purpose is twofold:
1. Establish a correctness baseline that version B's outputs can be verified against
2. Quantify the cost of the "natural" expression so we know how much optimization headroom version B exploits

If version A is slow to compile or huge in constraints, that's fine — that's a finding, not a failure.

### Version B — Lookup table (`circuits/ca_lookup/`)

Goal: aggressively reduce constraint count via precomputed transition tables.

**Lookup table strategy:**

For each cell, the next state is a deterministic function of:
- Current cell state (13 possibilities)
- Per-element neighbor counts (6 element types × 0-6 count each)
- Cell's directional zone (which element's preferred direction it lies in, or none)

A naive table indexed by all of these would be enormous, but the reachable state space is much smaller. Specifically:

- Most `(state, neighbor_count_vector)` combinations are unreachable in valid CA evolution
- Many transitions collapse to identity (cell stays the same)
- Hybrid formation rules can be expressed as a small sub-table keyed on which pure elements are "eligible" (a 4-element bitmap, 16 entries)

**Suggested approach:**
1. Enumerate all reachable `(self_state, eligibility_bitmap, count_signature)` inputs by simulating valid grids in Dart/Python offline
2. Build a minimal table mapping those inputs to next-state outputs
3. Encode the table as a Noir constant array
4. The per-cell circuit logic reduces to: compute eligibility bitmap from neighbors, compute count signature, look up next state

Don't get clever about packing the table itself in fancy ways. Just get a working lookup-based version with measurably fewer constraints than version A.

**Correctness check:** Version B must produce identical outputs to version A on a suite of test grids. Include this as a unit test, run it before benchmarking. A version B that's faster but wrong is worse than no version B.

---

## Measurement protocol

For each circuit version (A, B) at each T ∈ {1, 2, 5, 10, 20}, collect:

| Metric | How |
|---|---|
| ACIR opcodes | `nargo info` |
| Backend gate count | `bb gates` (verify the exact command for bb 5.0 nightly — the CLI is unstable) |
| Witness generation time (ms) | Wall-clock around `nargo execute` |
| Proof generation time (ms) | Wall-clock around `bb prove` |
| Peak memory during proving (MB) | `/usr/bin/time -v` max RSS |
| Proof size (bytes) | File size of generated proof |
| Circuit compilation time (s) | Wall-clock around `nargo compile` (informational, not a primary metric) |

Run each measurement 3 times, take the median. Cold runs and warm runs both fine — just be consistent.

Use a fixed test grid for all measurements — pick one with non-trivial CA evolution (some growth, some hybrids forming, ideally some border activation). Document the test grid in the report so results are reproducible.

CSV columns: `version,T,acir_opcodes,bb_gates,witness_ms,prove_ms,peak_mem_mb,proof_bytes,compile_s`

---

## Report structure (`phase1_report.md`)

Required sections:

1. **Summary** — One paragraph: did the full circuit fit, which version was needed, what's the recommendation for Phase 2.

2. **Methodology** — Brief: test grid description, measurement protocol, anything notable about the implementation.

3. **Results table** — The CSV rendered as a markdown table.

4. **Curve analysis** — For each version, a linear regression of gate count vs. T:
   - Slope (gates per generation) — this is the per-generation cost
   - Intercept (fixed overhead) — Poseidon, IO binding, etc.
   - R² (sanity check that the relationship is actually linear)
   - Extrapolated gate count at T=20 (should match the measured value closely)

5. **ACIR-to-gates ratio** — For each version at each T, ratio of `bb gates` to `nargo info` opcodes. If this ratio is wildly different between versions or grows non-linearly with T, call it out.

6. **Feasibility assessment** — Map the T=20 gate count to mobile feasibility bands:
   - <500k gates: green (comfortable mid-range mobile, <1 min proving)
   - 500k-2M: yellow (feasible, 1-3 min mid-range)
   - 2M-4M: orange (high-end only, 3-10 min, possible OOM low-end)
   - \>4M: red (not feasible without redesign or cloud)

7. **Recommendation** — Based on the data:
   - If green/yellow: proceed to Phase 2 mobile integration
   - If orange: proceed to Phase 2 with target hardware constraints documented, consider whether T=20 is the right design target or if a lower T (with re-measurement) is more comfortable
   - If red: recommend a Phase 1.5 rule-simplification pass before mobile work begins

---

## Stop-and-ask conditions

Halt work and report findings (do not push through) if:

- **Version A exceeds 8M ACIR opcodes at T=20.** This suggests the natural translation has a structural problem worth diagnosing before building version B on the same foundation.

- **`bb gates` to ACIR opcode ratio exceeds 5x on either version.** This suggests the backend is doing surprising amounts of work to lower the circuit, which is worth understanding before optimizing further.

- **Versions A and B disagree on outputs for any test grid.** Don't paper over this — find the bug. Version A is the correctness reference.

- **Compilation of either version takes longer than 30 minutes.** Tooling issue, not a circuit issue, and worth investigating separately.

- **Poseidon parameters in the Noir stdlib don't match what's documented for BN254.** This is a paranoia check — note the parameter set being used (curve, t, RF, RP, S-box) so the eventual Dart-side Poseidon can be matched exactly.

In any of these cases: stop, write up what was found, and surface it before continuing.

---

## What's explicitly *not* in this phase

- Mobile builds, FFI, Flutter integration (Phase 2)
- Cloud proving infrastructure (later, contingent on Phase 2 results)
- Rule simplification (Phase 1.5, contingent on Phase 1 results)
- Chain decay, mana cost tuning, spell effect logic (gameplay, not circuit)
- The harmonic concatenation / spell hash computation (post-verification, outside the circuit by design)

If any of these come up as blockers for completing Phase 1, surface them rather than expanding scope.

---

## A note on the rule-simplification fallback

If Phase 1 results land in the orange or red bands and version B's optimizations don't bring them into yellow, the next step is a Phase 1.5 negotiation about which CA rules to simplify. **Do not preemptively simplify in Phase 1.** The point of Phase 1 is to measure what each rule costs. Once costs are known, simplification becomes a game-design decision (which rules can we cut without ruining the spell-design space) informed by data, rather than a guess.

Candidate rules likely to be expensive, for awareness only — not a directive to simplify them:
- Hybrid formation's 2+ hybrid types → Void rule (requires tracking which hybrids are eligible per cell)
- Chaos corruption (overrides normal transitions for cells adjacent to Chaos)
- Directional drift (per-cell directional zone lookup)

If version B comes in green, none of this matters and we proceed to Phase 2.
