# Phase 1.5 Brief — Circuit Testing for Simplified CA

**Goal:** Measure the circuit cost of the current cellular automaton design and determine whether it fits within mobile proving budgets. Produce data to decide between proceeding to Phase 2 (mobile integration) or further design adjustment.

**Status going in:** Phase 1 measured an earlier 13-state CA design at ~10.3M gates at T=20 (red band, not mobile-feasible) for the natural translation, and ~3.5M gates (orange band) for the lookup-optimized version. The design has since undergone significant simplification. This phase re-measures the simplified design.

**Out of scope:** No Flutter integration, no Rust FFI, no mobile builds, no on-device measurement. This phase is desktop-only Noir circuit work and benchmarking. Trajectory parsing, recipe matching, residual tracking, and wild magic computation are all external to the circuit and out of scope.

---

## Current design state (canonical reference: existing Dart implementation)

**Read the Dart simulation code as the canonical source of truth.** This brief describes the design intent, but the implementation is the reference. Where they differ, the implementation wins; surface the discrepancy and ask before proceeding.

The relevant files in the Dart codebase implement the CA simulation, dominance tracking, rule state management, and trajectory output. Verify cell counts, neighbor adjacency conventions, and rule details against these files before encoding them in Noir.

### Grid structure

- Hexagonal grid, axial coordinates (q, r), vertex-down orientation
- Inscribable region: rings 0-8 (radius 8) — 217 cells
- Buffer region: rings 9-11 — participates in simulation, starts empty, cannot be inscribed
- Border region: ring 12 — counts activations and triggers rule modifications, deactivates immediately each generation

Verify these counts against the Dart code. The design intent is 463 cells total participating in simulation, but the implementation is canonical.

### Cell states

Two states: inactive (0) and active (1). Encode as Field elements; do not attempt smaller types.

### CA rules

**Baseline rules (hex Conway 2/2):**
- Active cells with exactly 2 active neighbors survive
- Empty cells with exactly 2 active neighbors become active
- All other cells become or stay empty

**Element-specific rule modifications:** When an element holds dominance (per the dominance system below), the baseline rules are replaced by that element's specific rules. Verify exact rules against the Dart implementation; the design specifies four element rule sets plus the baseline.

**Border collateral damage:** Cells adjacent to an active border cell (in the previous generation) deactivate. This is a separate check applied after the normal CA transition logic.

### Dominance system

Each element maintains a "pressure" value, tracked as integers:

- Pressure increases by +1 for each border cell activation in that element's zone, per generation
- The currently dominant element's pressure decreases by the current generation number each generation
- The element with the highest pressure is the active rule (sticky on ties — current leader stays unless strictly exceeded)
- When all pressures drain to zero, rule reverts to baseline
- Pressures reset to zero when neutral baseline activates

### Border zone partitioning

The border ring is partitioned into elemental zones in a landscape layout (verify exact partitioning against the Dart implementation):

- Bottom region: Earth (~18 cells)
- Lower flanks: Water (~9 cells each side, ~18 total)
- Upper flanks: Air (~9 cells each side, ~18 total)
- Top region: Fire (~18 cells)

The partitioning function should be a compile-time constant per cell.

### Public outputs from circuit

The circuit must emit:
- `commitment: Field` — Poseidon hash of (grid_state || T)
- `border_activations_per_element: [Field; 4]` — total activations per element across all generations
- `dominance_trajectory: [Field; T]` — dominant element index per generation (0 = neutral, 1-4 = elements)
- `supreme_dominance_flags: [Field; T]` — boolean per generation indicating if dominant element's activations exceeded sum of other three

Private inputs (witness):
- `grid_state: [Field; N]` where N is the total participating cell count (verify against Dart)

The trajectory output enables external recipe matching, residual tracking, supreme dominance bonuses, and wild magic computation. The circuit does not need to know about recipes or any of these downstream concepts.

### Commitment scheme

`commitment = Poseidon(grid_state || T)`

No salt. The grid pattern itself is what makes spells distinguishable. Same grid + same T = same commitment = same spell. Different grid OR different T = different commitment = different spell.

---

## Deliverables

By the end of this phase, the repository should contain:

1. **`circuits/ca_natural_v2/`** — Noir crate implementing the simplified CA rules as a direct translation of the Dart implementation. Optimize for clarity, not constraint count.

2. **`circuits/ca_lookup_v2/`** — Noir crate implementing the same logical CA via parallel lookup tables keyed on (self_state, neighbor_count, current_rule_state). Optimize for constraint count.

3. **`scripts/bench_phase1_5.sh`** — Reproducible benchmark script that builds both circuits, runs them at T ∈ {5, 10, 20, 30}, and emits `phase1_5_results.csv`.

4. **`phase1_5_results.csv`** — Output of the benchmark script, one row per (circuit_version, T) combination.

5. **`phase1_5_report.md`** — Short markdown report (1-2 pages) with findings, regression analysis, and recommendation.

6. **`circuits/GRID_ORDERING_v2.md`** — Document the canonical ordering used for the grid_state flat array, for eventual Dart-side matching.

---

## Two-version mandate

### Version A — Natural translation (`circuits/ca_natural_v2/`)

Direct translation of the Dart simulation into Noir. Use match-on-state, conditional arithmetic, whatever reads cleanly. Do not optimize prematurely. Its purpose:

1. Establish a correctness baseline that the lookup version's outputs can be verified against
2. Quantify the cost of the natural expression for comparison

If version A is slow to compile or large in constraints, that's a finding, not a failure.

### Version B — Lookup tables (`circuits/ca_lookup_v2/`)

Use parallel lookup tables, one per rule state (baseline + four element-specific rules). Each table is keyed on (self_state, active_neighbor_count, border_collateral_flag) and maps to next_state.

Build the tables by enumerating reachable input combinations. With 2 cell states, 6 hex neighbors, and a small number of rule states, the total table size should be modest — likely under 1000 entries per rule state. If tables grow beyond ~10,000 entries per rule state, something is wrong with the encoding; stop and diagnose.

**Correctness check:** Version B must produce identical outputs to version A on a suite of test grids. Include this as a unit test, run it before benchmarking.

---

## Measurement protocol

For each circuit version (A, B) at each T ∈ {5, 10, 20, 30}, collect:

| Metric | How |
|---|---|
| ACIR opcodes | `nargo info` |
| Backend gate count | `bb gates` (verify exact command for current bb version) |
| Witness generation time (ms) | Wall-clock around `nargo execute` |
| Proof generation time (ms) | Wall-clock around `bb prove` |
| Peak memory during proving (MB) | `/usr/bin/time -v` max RSS |
| Proof size (bytes) | File size of generated proof |
| Circuit compilation time (s) | Wall-clock around `nargo compile` |

Run each measurement 3 times, take the median.

Use a fixed test grid for all measurements — pick one with non-trivial CA evolution that exercises multiple element rule transitions. Document the test grid in the report.

CSV columns: `version,T,acir_opcodes,bb_gates,witness_ms,prove_ms,peak_mem_mb,proof_bytes,compile_s`

---

## Stop-and-ask conditions

Halt work and report findings if:

- **Version A exceeds 5M ACIR opcodes at T=20.** Simplification should have dramatically reduced per-cell cost; if it hasn't, diagnose before proceeding.

- **Lookup tables grow beyond 10,000 entries per rule state.** Suggests the rule state space isn't decomposing as expected.

- **`bb gates` to ACIR opcode ratio exceeds 3x on either version.** Suggests backend lowering is doing surprising work.

- **Versions A and B disagree on outputs for any test grid.** Don't paper over this — find the bug. Version A is the correctness reference.

- **Compilation of either version takes longer than 10 minutes.** Tooling issue or pathological pattern (similar to the `nb as u32` issue from Phase 1). Diagnose separately before continuing.

- **The Dart implementation disagrees with this brief's description of the design.** This brief is a description; the code is canonical. Stop and ask before encoding the brief's version.

---

## Feasibility bands

Map the T=20 gate count to mobile feasibility:

- **<500k gates: green.** Comfortable mid-range mobile proving, expected <1 minute.
- **500k-2M: yellow.** Feasible mid-range, 1-3 minutes.
- **2M-4M: orange.** High-end only, 3-10 minutes, possible OOM on low-end devices.
- **>4M: red.** Not feasible without further redesign or cloud-assisted proving.

Apply the same bands at T=30 to assess headroom for longer simulations.

---

## Report structure (`phase1_5_report.md`)

Required sections:

1. **Summary** — One paragraph: did the simplified circuit fit, which version is the recommended candidate, what's the recommendation for Phase 2.

2. **Methodology** — Test grid description, measurement protocol, anything notable about the implementation. Specifically note any discrepancies between the Dart implementation and this brief that were resolved during implementation.

3. **Results table** — The CSV rendered as a markdown table.

4. **Curve analysis** — For each version, linear regression of gate count vs. T:
   - Slope (gates per generation)
   - Intercept (fixed overhead — Poseidon, IO binding, dominance tracking, etc.)
   - R² (linearity sanity check)
   - Extrapolated values for T=50, T=100 (for design planning purposes)

5. **Comparison to Phase 1** — Per-cell cost (gates per cell per generation) compared between Phase 1's natural translation, Phase 1's lookup version, and this phase's two versions. Quantifies the simplification's effect.

6. **Lookup table analysis** — Number of entries per rule state, distribution of how often each entry is exercised by the test grid, any observations about table structure.

7. **Feasibility assessment** — Map T=20 and T=30 results to feasibility bands.

8. **Recommendation** — Based on the data:
   - If T=30 is green: proceed to Phase 2 with confidence, design has headroom for longer simulations
   - If T=20 is green and T=30 is yellow: proceed to Phase 2, document T=30 as feasible but expensive
   - If T=20 is yellow: proceed to Phase 2 with target hardware constraints documented
   - If T=20 is orange: stop, consult before proceeding
   - If T=20 is red: stop, this phase's data suggests further redesign is needed

---

## What's explicitly *not* in this phase

- Mobile builds, FFI, Flutter integration (Phase 2)
- Cloud proving infrastructure (later, contingent on Phase 2 results)
- Recipe matching logic (external to circuit, outside scope)
- Residual tracking, supreme dominance bonus calculation (external)
- Wild magic hash computation (external)
- Counter-spell mechanic implementation (external)
- Spell effect table design (gameplay, not circuit)
- The harmonic concatenation / spell hash computation (post-verification, outside circuit)

If any of these come up as blockers, surface them rather than expanding scope.

---

## Practical notes

**The Dart implementation is canonical.** This brief describes design intent. Where the brief and the code disagree, the code is correct and the brief should be updated. Surface discrepancies before encoding them in Noir.

**Verify Poseidon parameters.** Note the exact parameter set (curve, t, RF, RP, S-box) being used by the Noir stdlib. The eventual Dart-side Poseidon will need to match exactly.

**Save intermediate state.** The benchmark script may take significant compute time. Structure it to write partial results as it goes, so a crash or interruption doesn't lose all data.

**Run unattended.** The full benchmark suite should run without supervision. Use background processes, write to disk, return when complete.
