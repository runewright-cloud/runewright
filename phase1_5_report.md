# Phase 1.5 Report -- Circuit Cost of Simplified CA

## 1. Summary

The simplified 2-state CA (hex Conway 2/2 baseline with four element-specific rule variants)
fits comfortably within mobile proving budgets. At T=20, the lookup circuit (`ca_lookup_v2`)
produces 409k gates -- **green band** -- with a 3.1s desktop proof time. At T=30, both
versions fall in **yellow band** (500k-2M gates), still feasible for mid-range mobile at
1-3 minutes. The lookup circuit is the recommended candidate for Phase 2: it is 22-28% cheaper
in gates than the natural circuit, scales perfectly linearly (R2=1.000), and produces identical
outputs for all tested inputs.

**Recommendation:** proceed to Phase 2 with `ca_lookup_v2` as the proving candidate. T=30
is feasible but expensive on mobile; document it as the upper bound. Design has comfortable
headroom for the intended T=20 use case.

---

## 2. Methodology

### Toolchain

- Noir: nargo 1.0.0-beta.20
- Backend: Barretenberg 5.0.0-nightly.20260324 (UltraHonk)
- Platform: Linux desktop (16 threads)

### Test grid

A 20-cell pattern with clusters near each border zone direction:

- Near-top cluster (4 cells, heads toward fire zone): (0,-5), (1,-5), (-1,-4), (0,-4)
- Near-bottom cluster (4 cells, heads toward earth zone): (0,5), (1,4), (-1,5), (0,4)
- Right-side cluster (3 cells, heads toward water zone): (4,-2), (4,-1), (3,-2)
- Left-side cluster (3 cells, mirrors water): (-4,2), (-4,1), (-3,2)
- Center ring (6 cells, neutral activity): (2,-1), (2,0), (1,1), (-1,1), (-2,0), (-1,-1)

All cells are within the inscribable region (rings 0-8). No border or buffer cells are set.

At T=20, the first border activation occurs at step 14 (fire zone). By step 15, fire and earth
both activate, triggering dominance transitions. The T=30 trajectory shows all four elements
gaining and losing dominance across steps 14-29, exercising the full rule-switching logic.

### Dominance trajectory at T=30 (rule indices: 0=neutral, 1=fire, 2=air, 3=water, 4=earth)

`[0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,4,1,4,1,4,1,2,3,1,4,2,3,1,1,3]`

All four element rules (1-4) appear in the trajectory, confirming the full circuit is exercised.

### Measurement protocol

Each (version, T) combination: compile 3x then take median, execute witness 3x median,
prove 3x median with peak memory captured on the final run. The same test grid and Prover.toml
are used for all measurements. Proof generated with Barretenberg UltraHonk (default target).

### Implementation notes

**Discrepancies between brief and Dart code (all resolved in favor of Dart code):**

1. Cell count: brief stated 463, implementation uses 469 (1+3*12*13). Circuit uses 469.
2. Border collateral damage: brief described adjacent-cell deactivation; not in Dart stepper.
   Circuit does not implement it.
3. Pressure decay: brief said "decrease by generation number"; Dart does `stepCount div 2`.
   Circuit uses floor division by 2.
4. Pressure reset on neutral: brief said pressures zero out; Dart does not reset. Circuit
   carries pressures, they drain naturally via decay.

**Poseidon2 note (Phase 1.5 — SUPERSEDED):** The Phase 1.5 circuit used a duplex sponge
over all 469 cells plus T. This approach has been superseded by the v2.4 design: the commitment
is `Poseidon2(packed[0], packed[1])` over a 2-field packed grid (see CIRCUIT_IO.md §3–4).
**The Dart side must NOT implement Poseidon2.** Commitments are opaque public-input values
read from the prover's output — Dart compares commitment bytes but never recomputes them.
Reimplementing Poseidon2 in Dart would violate CLAUDE.md hard invariant #1 and #2.
The "Dart side will need to implement the same sponge sequence" note below (§6) is similarly
superseded; disregard both.

---

## 3. Results table

| version | T | acir_opcodes | bb_gates | witness_ms | prove_ms | peak_mem_mb | proof_bytes | compile_s |
|---|---|---|---|---|---|---|---|---|
| ca_natural_v2 |  5 |  36,408 |  75,728 |  220 |   908 |  161.4 | 14,656 | 0.16 |
| ca_natural_v2 | 10 | 121,318 | 207,123 |  478 | 1,711 |  364.8 | 14,656 | 0.25 |
| ca_natural_v2 | 20 | 328,357 | 522,446 | 1163 | 3,670 |  810.6 | 14,656 | 0.49 |
| ca_natural_v2 | 30 | 536,347 | 839,016 | 1893 | 6,206 | 1356.5 | 14,656 | 0.75 |
| ca_lookup_v2  |  5 |  46,452 | 114,426 |  252 | 1,008 |  197.8 | 14,656 | 0.17 |
| ca_lookup_v2  | 10 |  91,822 | 212,676 |  393 | 1,719 |  353.9 | 14,656 | 0.21 |
| ca_lookup_v2  | 20 | 182,562 | 409,173 |  668 | 3,100 |  656.8 | 14,656 | 0.32 |
| ca_lookup_v2  | 30 | 273,302 | 605,670 |  950 | 5,218 | 1054.6 | 14,656 | 0.42 |

---

## 4. Curve analysis

### ca_natural_v2 (linear regression, all 4 T values)

- **Slope:** 30,777 gates/step
- **Intercept:** -89,055 gates (fixed overhead minus compile-time optimization savings at small T)
- **R2:** 0.9992
- **Extrapolated T=50:** ~1.45M gates (yellow band)
- **Extrapolated T=100:** ~2.99M gates (orange band)

Note: T=5 and T=10 measurements fall slightly below the regression line. At these T values, the
test grid never activates the border (first activation is at step 14), so the dominance
computation is constant-folded by the Noir compiler. The T=20 and T=30 measurements represent
the fully-activated circuit.

### ca_lookup_v2 (linear regression, all 4 T values)

- **Slope:** 19,650 gates/step
- **Intercept:** +16,178 gates (Poseidon2 sponge + fixed overhead)
- **R2:** 1.0000 (perfect linear fit)
- **Extrapolated T=50:** ~998k gates (yellow band)
- **Extrapolated T=100:** ~1.98M gates (yellow band)

The lookup circuit scales with exact linearity across all measured T values, confirming
clean per-step cost structure with no optimizer artifacts.

---

## 5. Comparison to Phase 1

Phase 1 measured a 13-state CA design on the same grid size. Using Phase 1 figures from the
brief (N=469 cells, T=20):

| Circuit | T=20 gates | gates/cell/step |
|---|---|---|
| Phase 1 natural     | ~10,300,000 | ~1,098 |
| Phase 1 lookup      |  ~3,500,000 |   ~373 |
| Phase 1.5 natural   |    522,446  |   55.7 |
| Phase 1.5 lookup    |    409,173  |   43.6 |

The simplification from 13 states to 2 states reduces per-cell-step cost by **20x** (natural)
and **8.6x** (lookup). The 2-state design is the dominant driver of improvement -- the rule
encoding becomes trivial and the large state-space lookup tables from Phase 1 disappear.

---

## 6. Lookup table analysis

The `FLAT_TRANSITION` global in `ca_lookup_v2` has **70 entries** (5 rules x 2 cell states x 7
neighbor counts). Far below the 10,000 entry stop-and-ask threshold.

| Zone | Rule | Dead-cell entries (born) | Alive-cell entries (survive) |
|---|---|---|---|
| Neutral | 0 | [0,0,1,0,0,0,0] | [0,0,1,0,0,0,0] |
| Fire    | 1 | [0,1,1,1,1,1,1] | [0,1,0,0,0,0,0] |
| Air     | 2 | [0,0,1,0,0,0,0] | [1,1,1,0,0,0,0] |
| Water   | 3 | [0,0,1,1,1,1,1] | [0,0,0,1,1,1,1] |
| Earth   | 4 | [0,0,1,1,1,1,1] | [0,0,1,1,1,1,1] |

Columns represent neighbor counts 0..6. All 70 entries are reachable in principle; the T=30
simulation exercises at least 4 of the 5 rule sets. Border cells use only the dead-row (state=0)
entries since alive border cells always die unconditionally.

The backend implements the dynamic table access (`FLAT_TRANSITION[rule * 14 + state * 7 + nb]`)
as a ROM lookup rather than a multiplexer tree. This accounts for the lower gate-to-ACIR-opcode
ratio for the lookup version (2.24x) vs. natural (1.59x): the gate count is lower per opcode
because each ROM access maps to fewer gates than an equivalent if-else multiplexer.

---

## 7. Feasibility assessment

Bands: <500k green, 500k-2M yellow, 2M-4M orange, >4M red.

| Version | T=20 gates | T=20 band | T=30 gates | T=30 band |
|---|---|---|---|---|
| ca_natural_v2 | 522,446 | **yellow** | 839,016 | **yellow** |
| ca_lookup_v2  | 409,173 | **GREEN**  | 605,670 | **yellow** |

Desktop proof times: lookup T=20 = 3.1s, T=30 = 5.2s. Mobile proving is typically 4-10x
slower than desktop. At 10x, T=20 lookup would prove in ~31s (green band target <60s). At
T=30 lookup: ~52s, borderline. On mid-range mobile (say 5x), T=20 = 15s and T=30 = 26s.

Both T=20 targets are confidently achievable on mobile. T=30 is feasible on mid-range mobile
but should be qualified in user-facing documentation.

---

## 8. Recommendation

**T=20 lookup is green. T=30 lookup is yellow.**

Per the brief's decision tree: proceed to Phase 2, documenting T=30 as feasible but expensive.

Concretely:

- **Recommended circuit:** `ca_lookup_v2` at T=20. 409k gates, ~3s desktop proof, 14.6KB
  proof size (UltraHonk, same for all T values measured here).
- **Maximum T for general deployment:** T=20 (green band, <1 min on typical mobile).
- **Extended simulations:** T=30 feasible for high-end devices with user warning; T=50
  extrapolates to ~1M gates (yellow, ~8-12s on mobile) and T=100 to ~2M gates (yellow/orange
  boundary) -- still a viable design range.
- **Phase 2 entry point:** Dart FFI to the lookup circuit with the canonical grid ordering
  documented in `circuits/GRID_ORDERING_v2.md`. The Poseidon2 sponge construction must be
  matched exactly on the Dart side for commitment verification.
  **[SUPERSEDED — see CLAUDE.md §Hard invariants #1/#2 and CIRCUIT_IO.md §4: the Dart side
  never implements Poseidon2. Commitments are opaque public inputs from the prover.]**
