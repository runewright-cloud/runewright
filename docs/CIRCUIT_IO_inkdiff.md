# `CIRCUIT_IO.md` — Contract diff for the ink-substrate ruleset

*Apply this to `CIRCUIT_IO.md` as the **first task** of the circuit-rework milestone,
before any Noir is written. Per §0 of the contract, the circuit is built against this
doc and the golden vectors enforce it — so the contract changes first, then the circuit,
then vector regen. This diff describes only what the finalized neutral "ink" ruleset
changes; everything not listed here is unchanged and should stay frozen.*

**Canonical oracle for the neutral branch:** `lib/engine/ink_step.dart` (called by
`stepper.dart`'s `CAStep.step` via `CARules.isNeutral`). Where this diff and the Dart
disagree, the Dart wins — surface it.

---

## Finalized neutral ruleset (the thing being encoded)

All birth-only, synchronous, computed from the prior generation, union-applied. No cell
in the inscribable/buffer region ever deactivates (Rule D). Border cells are the
exception — see the §10.5 border paragraph, unchanged.

- **Rule A — gap-fill/merge.** An inactive cell with ≥1 *complete antipodal axis* (both
  opposite neighbors active) becomes active. **Distance-1, self-gather. Cheap.**
- **Rule B — tip extension.** An active cell with *exactly one* active neighbor activates
  that neighbor's antipode (the line continues straight off its free end). **Distance-2 —
  the one expensive rule. Encode as two distance-1 passes (spec below).**
- **Rule E — serif flare.** On a pulse generation, an inactive cell with *exactly one*
  active neighbor becomes active. This is birth-on-1 gated by parity. **Distance-1, count.
  Folds into the existing lookup as a parity-selected row.**
- **Rule D — no deaths.** Invariant; realized structurally by unioning with the prior
  state, not as a death rule. Border override still applies.
- **Rule C — removed.** (Was the rosette burst; it scattered onto 7 neighbors and drove
  the distance-2 cost. Gone.)

`cadence = 4`, pinned as a circuit global matching `InkRules`' production default. The
sandbox may vary it; the circuit is frozen at the production value.

---

## §6 — `ruleset_version`: bump 1 → 2

The ink ruleset is a consensus-visible CA rule change — exactly the case §6 says should
bump the epoch. Change `global RULESET_VERSION: Field = 1` → `= 2` and keep the in-circuit
`assert(ruleset_version == RULESET_VERSION)`. This is a deliberate, VK-breaking change
(the intended kind, distinct from the §5 owner-binding lock). Nothing has shipped, so
there are no v1 proofs to orphan — clean bump.

> **Open decision for you to confirm:** bump to 2 (recommended, disciplined) vs. redefine
> v1 in place (defensible since pre-release). The diff assumes the bump.

---

## §2 / constants — neighbor ordering is now load-bearing; add the antipode convention

The old circuit only needed the *set* of each cell's neighbors (counting is order-blind).
Ink needs *which neighbor is opposite which*, so the `NEIGHBORS[N][6]` table must be
emitted in an order where **slot `i` and slot `(i+3) % 6` are antipodal**, matching
`InkStep.directions`:

```
slot 0: (+1,  0)
slot 1: (+1, -1)
slot 2: ( 0, -1)
slot 3: (-1,  0)   // antipode of 0
slot 4: (-1, +1)   // antipode of 1
slot 5: ( 0, +1)   // antipode of 2
```

Axis pairs are therefore implicit in the slot ordering: `(0,3), (1,4), (2,5)`. No separate
axis constant is needed *if* this ordering holds — but `gen_grid_constants.py` must be
updated to emit `NEIGHBORS` in this exact direction order (it previously had no ordering
constraint), and `GRID_ORDERING_v2.md` should note that slot order is now semantic.

Off-grid neighbor slots (only border cells have them, since inscribable/buffer cells all
have 6 in-grid neighbors within radius 12) use the existing sentinel and **read as
inactive**, matching `ink_step.dart`'s out-of-grid-is-inactive convention.

> **Two-oracle reconciliation item, do this in orientation:** confirm `constants.nr`'s
> current `NEIGHBORS` ordering against `InkStep.directions`. If they differ, regenerate
> `NEIGHBORS` to match `ink_step.dart` — the Dart is canonical and the antipode math is
> wrong if the orders disagree.

---

## §10.5 — rewrite the neutral branch of the CA-evolution constraint

The clause currently reads "baseline (hex Conway 2/2) + element rule sets + dominance."
**Three changes:** replace the **neutral baseline** (now the ink rules); **gate elemental
dispatch behind supreme dominance** (next subsection); and **generalize decay + tie
handling** (subsection after that). Unchanged: the four elemental count-rules themselves,
the supreme-dominance *computation* (dominant zone's running total of activations-minus-decay
> the other three combined),
and the border-cell evolution paragraph (border forced to 0, activation still counted). The
per-generation dominant determination changes only in how it reports ties (below).

### Rule dispatch — gated behind supreme dominance `[design change, confirmed]`

Previously the dominant element's rule set applied whenever that element led on pressure.
Now it applies **only when that element is supremely dominant** in generation `g`;
otherwise the neutral ink rules run:

```
rule(g) = (supreme_dominance_flags[g] == 1)
            ? elemental_rules[ dominant_element(g) ]
            : neutral_ink_rules
```

- `dominant_element(g)` (argmax of each zone's net counter = activations minus decay; ties
  report 0 — see the decay/ties subsection) and `supreme_dominance_flags[g]` (dominant zone's
  net counter > the other three combined) are computed **exactly as today**. The supreme flag
  is now a **dispatch signal as well as a public output** — the value driving dispatch and
  the value emitted MUST be identical (compute once, use for both), or evolution won't match
  the declared flags.
- **The dominance counter accumulates through neutral generations.** Each zone keeps one
  counter — *border activations minus decay* ("pressure" is just its name); there is no
  separate raw-activation tally feeding supreme. It rises by +1 per border activation in its
  zone every generation regardless of dispatch (including neutral), and only decay (next
  subsection) lowers it. Any "reset when neutral activates" logic from older specs must NOT
  apply, or supreme becomes unreachable.
- `dominance_trajectory[g]` still reports the **dominant** element (the spell's elemental
  signature), not the rule applied. A generation may report fire in the trajectory while
  the grid evolves under neutral ink — intentional decoupling that preserves the existing
  recipe/trajectory system. *(Confirm: the alternative, trajectory-follows-dispatch, would
  gut recipe matching and is not assumed here.)*
- Lands as a **Dart-oracle change first** (`ca_run.dart` rule selection), merged and tested
  on `feature/ink-substrate` before the circuit is built — see the separate CC task. The
  circuit then mirrors it: the per-generation rule mux selects neutral-vs-elemental on the
  supreme flag, not on mere dominance.
- Consequence: neutral runs for most of a typical simulation (supreme is a high bar), so
  the serif-pulse saturation question (§7/feel) now applies across the whole run, not just
  the opening — watch border-contact and density on a multi-tip seed.

### Decay, ties, and dominance reporting `[design change, confirmed]`

The old "only the dominant element decays by `floor((gen+1)/2)`" generalizes to one rule
that also covers ties. Per generation `g`, with `D = floor((gen+1)/2)`:

- Let `maxP` be the highest pressure across the four elements and `k` the number of
  elements holding `maxP`. **Every element at `maxP` decays by `ceil(D / k)`**
  (`= (D + k − 1) / k`), floored at 0. Unique leader → `k = 1` → decays by `D` (old
  behavior exactly); a `k`-way tie splits the rounded-up decay across the tied set. If
  `maxP == 0`, nothing decays (true neutral).
- **Rationale:** the calmer ink-dominated sims make sustained top-of-table ties common.
  Decaying only a single nominal dominant (or halting decay when a tie meant "no dominant")
  let a careful player hold one element just below supreme while the other three banked
  pressure unchecked — an exponentially growing wait for the intended element to cycle back
  to the lead. Splitting decay across the tied set keeps the table moving and bounds that
  wait.
- **Tie reporting:** a tie (`k ≥ 2` at `maxP`) reports **no dominant** —
  `dominance_trajectory[g] = 0` — and cannot be supreme. A unique `maxP` element is the
  dominant, reported as today. This supersedes the old sticky-tie rule *for reporting* (a
  tie no longer holds the prior leader); dispatch is unaffected since ties can't be supreme
  and so run neutral anyway. *(Confirm: this is the interpretation that makes "ties add no
  formula element" fall out of the external parser with no new circuit output.)*

Pressure *accumulation* is unchanged: every element gains +1 per border activation in its
zone every generation, including neutral ones. Only the decay side generalizes.

> **Formula accrual is external and unaffected.** Turning trajectory + supreme flags into a
> spell formula — lead-change entries (rule 1), per-step supreme entries (rule 2),
> cadence-step entries (rule 3), at most one element per generation — is downstream parsing
> over the emitted outputs plus the known cadence constant. It needs no new circuit output
> and is out of scope here: the circuit's job is unchanged, emit `dominance_trajectory`
> (per-gen dominant, 0 on tie/neutral) and `supreme_dominance_flags`. A tie reporting 0 is
> what lets the parser skip it.

New neutral-branch next-state for a **non-border** cell `Y`:

```
next[Y] = OR(
    prev[Y],                       // Rule D — monotone union, never deactivates
    bornA[Y],                      // Rule A
    bornB[Y],                      // Rule B (from the §B two-pass intermediate)
    pulse ? bornSerif[Y] : 0       // Rule E
)
```

where:
- `bornA[Y]   = (prev[Y] == 0) AND (Y has ≥1 complete axis)`  — axis = both endpoints of
  one of the 3 antipodal slot-pairs active.
- `bornSerif[Y] = (prev[Y] == 0) AND (active-neighbor-count(Y) == 1)`.
- `pulse = ((gen + 1) % cadence == 0)` — **see the off-by-one note below; this must fire
  on exactly the generations the Dart oracle pulses on.**

For a **border** cell `Y`: `next[Y] = 0` unconditionally (unchanged). If any neutral birth
condition (`bornA OR bornB OR (pulse AND bornSerif)`) would have fired on `Y`, increment
`border_activations` for `Y`'s zone, then force 0 — same write-only-sink mechanism as
today, with the trigger set now being the ink birth conditions rather than the old count
rule.

### Generation indexing / the pulse off-by-one `[TRAP — pin with a golden vector]`

`ink_step.dart` is 1-indexed: it computes `generation = stepCount` and pulses when
`generation % cadence == 0` (generations 4, 8, 12, …). The circuit's internal loop is
0-indexed `g`, and §10.5 already establishes `stepCount = g + 1` (this is the same
convention the decay formula uses: `floor((g+1)/2)`). Therefore the circuit's pulse
predicate is:

```
pulse(g) = ((g + 1) % cadence == 0)      // fires at g ∈ {3, 7, 11, ...}
```

Mirror the decay convention exactly. A golden vector with `T` spanning a pulse boundary
(e.g. `T ≥ 4`, seed with a free tip) must confirm the flare lands on the same generation
in both oracles. This is the single easiest place to introduce a silent off-by-one.

### §B — Rule B as two distance-1 passes `[encode it this way; don't discover the scatter mid-build]`

Rule B is scatter (an active cell writes onto a neighbor's antipode), which in gather form
needs each cell to inspect its neighbors' neighbors — distance-2. Decompose into two
distance-1 passes per generation with one intermediate witness array:

**Pass 1 — per cell `X`, compute `b_ext[X] ∈ {0..6}`** (0 = not a B-source; 1..6 =
extension direction + 1):
- `X` is a B-source iff `prev[X] == 1` AND `active-neighbor-count(X) == 1`.
- When it is, the single active neighbor's slot is `s = Σ_{i=0..5} i · active[i]` (valid
  precisely because the count is 1 — no mux needed). The extension direction is the
  antipode `d_ext = (s + 3) % 6`. Set `b_ext[X] = d_ext + 1`.
- Otherwise `b_ext[X] = 0`.

**Pass 2 — per non-border cell `Y`, gather:**
```
bornB[Y] = OR over slots e ∈ {0..5} of:
    let X = NEIGHBORS[Y][e];
    X in-grid AND b_ext[X] == ((e + 3) % 6) + 1
```
Rationale: if `X` is at slot `e` from `Y`, then `Y` is at slot `(e+3)%6` from `X`, so `X`
extends into `Y` exactly when `X`'s extension direction equals `(e+3)%6`.

`b_ext` is a `[Field; N]` intermediate witness, recomputed each generation. **It is attack
surface** — see the new §11 negative vector. Both passes read only the 6 immediate
neighbors, so each is distance-1; the cost is two passes plus one intermediate array per
generation, paid every generation (B is not parity-gated). Light, but not free.

---

## §10 — two new positive constraints

Add to the §10 enumerated list:

- **§10.10 — Neutral monotonicity (Rule D).** In a neutral generation, every
  inscribable/buffer cell satisfies `next[i] ≥ prev[i]` (an active cell stays active).
  This is automatic if `next` is built as the union above, but it must be *enforced* so a
  witness cannot claim a death to forge a different trajectory. (Border cells are exempt —
  they are forced to 0 by the unchanged border rule, which overrides this.)
- **§10.11 — `b_ext` intermediate is correctly derived.** Each `b_ext[i]` equals the Pass-1
  function of `prev` and the neighborhood — a prover cannot supply an arbitrary
  intermediate. Constrain `b_ext[i]` against `prev[i]`, the neighbor bits, and the count.

---

## §11 — new negative vectors

The existing negative vectors (#1–#7) all still apply; #4 (forged trajectory) and #5
(forged activations) now exercise the ink neutral evolution as their oracle — same vector
*category*, regenerated values. Add:

- **§11.8 — Forged death (monotonicity break).** A neutral witness in which a live
  inscribable cell goes to 0 from one generation to the next. If §10.10 is missing, a
  prover can suppress births/cells to forge a cheaper-looking or different trajectory.
- **§11.9 — Tampered `b_ext`.** A witness supplying a `b_ext` entry that does not match its
  Pass-1 derivation (e.g. claiming a non-source cell extends, or a wrong direction) to
  manufacture an extra `bornB` activation. If §10.11 is missing, the two-pass intermediate
  is a free-form forgery vector. This is the most ink-specific new exploit surface; pair it
  with §10.11 explicitly.

---

## §7 — cost section: mark stale, name the driver, flag the tier-12 bucket

- The old per-generation slope (~19,650 gates/gen) and the tier gate-count/band figures
  were measured on the **count-only** circuit. Mark them **estimated, pending
  remeasurement** for the ink circuit.
- The neutral branch now costs: the count machinery (for the serif row and the elemental
  mux) **plus** Rule B's two-pass overhead (one `[Field; N]` intermediate + two distance-1
  passes), paid **every** generation and mux'd against the elemental count rules. Rule A
  and the serif are distance-1; **Rule B is the sole distance-2 rule and the cost driver.**
- **tier-12's 2^18 padded bucket is UNVERIFIED and the margin is thin.** The count-only
  circuit already sits at **≈236k gates** (§7's measured figure), and UltraHonk pads
  tier-12 up to **2^18 = 262,144** rows — so there are only **~26k gates of headroom**, not
  the ~50k I estimated earlier. Rule B's two-pass overhead at even ~2k gates/gen over 12
  generations is right at that edge; crossing 2^18 into 2^19 (524,288) roughly doubles
  tier-12 proving time and memory — the tier you most want cheap. **Run `bb gates` early, at
  tier-12, on a neutral-heavy multi-tip seed, before building tiers 24/48.** This is a
  go/no-go on the rules as written, not a precaution: the count circuit is already ~90% of
  the way to the ceiling. If B busts the bucket, the cheapest lever is dropping its
  distance-2 requirement (collapsing toward plain B1), at the cost of directional line
  growth — the medium's core feel, so a design retreat, not a free optimization.
- The mana prose in §7 (`1.25^…`, "bloomers are tier-gated") is stale against the new
  1.05 + transition-tax model and the deferred radial/symmetry work, but mana is **not** a
  public input or a circuit constraint (it's derived client-side from public `T` + cells),
  so this is prose hygiene only — fix the text, no contract impact.

---

## Explicitly UNCHANGED (scope guard — do not touch)

§1 (2-state encoding, element indices, `border_activations` order) · §2 ordering &
region-by-distance (only the `NEIGHBORS` *slot order* changes, above) · §3 bit-packing ·
§4 commitment (it hashes the *initial seed*, not the evolved grid — ink does not touch it)
· §5 owner binding · §8 public-input **schema** (types/sizes stable; only the golden-vector
*values* change) · §9 witness · §10.1–10.4, §10.6–10.9 · the §10.5
border-cell-evolution paragraph (decay generalizes — see the decay/ties subsection above) ·
§12 identity/custody.

---

## Milestone sequencing

0. **Prerequisite — separate CC task, Dart-only, lands first:** gate elemental dispatch
   behind supreme dominance in `ca_run.dart` (see the §10.5 dispatch clause). The circuit
   is built against this updated oracle, so it must be merged and tested on the branch
   before step 3.
1. Apply this diff to `CIRCUIT_IO.md` (the bump decision, §10.5 rewrite + dispatch clause,
   §10.10/10.11, §11.8/11.9, §7 honesty, the `NEIGHBORS` ordering note).
2. Reconcile `NEIGHBORS` ordering vs. `ink_step.dart`; regenerate `constants.nr` /
   `gen_grid_constants.py` if needed.
3. Write the tier-12 v2.5 circuit against the updated contract.
4. **`bb gates` at tier-12 — go/no-go on the bucket.**
5. Regenerate golden vectors (two-oracle: stepper for CA, `nargo execute` for commitment),
   including the pulse-boundary vector for the §10.5 off-by-one and the §11.8/11.9
   negatives.
6. Only after tier-12 is green and in-budget: replicate to tiers 24/48.
