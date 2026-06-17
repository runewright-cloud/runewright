# Runewright — Golden & Negative Vector Harness (`GOLDEN_VECTORS.md`)

*The correctness contract between `stepper.dart` and the Noir circuit, and the spell-leak
backstop. A golden vector is a known input paired with its frozen, known-correct output;
the harness feeds every vector to each implementation and fails loudly if any output
drifts. Positive vectors prove the circuit computes the right thing; **negative vectors
prove it rejects the things it must** — and that second category is where ZK exploits
actually live.*

---

## 0. Why this exists (read once)

The security model rests on the Dart stepper and the Noir circuit computing **byte-identical**
CA evolution. If they diverge by a single cell, proofs attest to the wrong thing. The
vectors are the mechanism that catches divergence cheaply and automatically, across the
language boundary.

The threat is rarely "wrong answer." It's an **under-constrained circuit that accepts a
witness it shouldn't** — a quiet acceptance, not a crash. A positive-only test suite sails
right past that. So this harness is half positive (does it compute correctly?) and half
negative (does it refuse what it must?). Treat a failing negative vector as a **release
blocker**, identical in severity to a forged-proof bug.

## 0.1 Two oracles, not one `[important]`

- **CA outputs** (`dominance_trajectory`, `border_activations`, `supreme_dominance_flags`)
  → the oracle is **`stepper.dart`**. The generator runs the stepper to produce them.
- **`commitment`** → the oracle is the **Noir/Poseidon2 side**, *never Dart*. Computing the
  expected commitment in Dart would mean reimplementing Poseidon2 in Dart, which the
  hard invariants forbid. The generator obtains each expected commitment from the circuit
  toolchain (Noir/`bb`), and the Dart side only ever reads it back.

This split is load-bearing: it keeps the test fixtures themselves honest to the
architecture.

---

## 1. Corpus format

One JSON file (or sharded by tier). Grids are stored **sparsely** — a list of active cell
indices — so vectors stay human-readable instead of being 469-element arrays. The loader
expands a sparse grid to the full `[0/1; 469]` array.

```jsonc
{
  "id": "string, unique",
  "kind": "positive" | "negative",
  "description": "what this vector checks, in one line",
  "tier_max": 12,                 // which tier circuit this targets (12 | 24 | 48)
  "input": {
    "active_cells": [/* inscribable cell indices; must satisfy max(|q|,|r|,|q+r|) ≤ 8 (rings 0–8). With q×r flat ordering these are NOT all ≤216; valid indices range 62–406 non-contiguously. Center (0,0)=234. */],
    "T": 6,                       // active generation count, 1 ≤ T ≤ tier_max
    "owner_pubkey_hex": "…",      // 32-byte Ed25519 pubkey, hex; a fixed test key is fine
    "ruleset_version": 1
  },
  "expected": {
    "commitment": "IMPL",         // "IMPL" in the hand-authored seed; the generator fills it
                                  //   from the Noir side (never Dart). Frozen once generated.
    "border_activations": [0,0,0,0],            // [fire=0, air=1, water=2, earth=3]
    "dominance_trajectory":   [/* length tier_max; entries 0=neutral,1=fire,2=air,3=water,4=earth */],
    "supreme_dominance_flags":[/* length tier_max; 0/1 */],
    "verifies": true
  }
}
```

**Negative vectors** need to express *malformed* inputs the sparse form can't, plus the
ability to declare outputs that *don't* match the true evolution. Two optional override
blocks do this:

```jsonc
{
  "id": "neg_…",
  "kind": "negative",
  "description": "…",
  "tier_max": 12,
  "input": { "active_cells": [/*…*/], "T": 6, "owner_pubkey_hex": "…", "ruleset_version": 1 },

  "raw_overrides":   { "0": 2, "300": 1 },   // cell index → arbitrary value (non-boolean,
                                             //   or active cell in buffer/border ≥217)
  "declared_override": {                     // force public outputs that disagree with the
    "dominance_trajectory": [1,1,1,1,1,1,1,1,1,1,1,1],   //   witness's true evolution
    "border_activations": [9,9,9,9],
    "commitment": "0xdeadbeef…"
  },

  "violates_constraint": "§10.1 boolean cells",   // which CIRCUIT_IO constraint should catch it
  "expected": { "verifies": false }
}
```

The runner applies `raw_overrides` after expanding `active_cells`, and substitutes any
`declared_override` values for the public inputs the prover submits. The circuit must
**fail to produce a verifying proof.**

---

## 2. Positive vectors

### 2.1 Hand-verified anchors (ground-truth floor)

Two cases whose evolution is hand-derivable under the baseline hex 2/2 rule, so the corpus
has a floor that doesn't depend solely on the stepper being correct. (Their `commitment`
is still IMPL — only the *CA outputs* are hand-derived.)

- **`anchor_empty`** — `active_cells: []`. Nothing is active; nothing is ever born (a birth
  needs exactly 2 active neighbours, and there are none). Every generation stays empty.
  → `border_activations [0,0,0,0]`, `dominance_trajectory` all `0`, `supreme_flags` all `0`.
- **`anchor_single_center`** — `active_cells: [0]` (center). The lone cell has 0 active
  neighbours, so it dies next generation (survival needs exactly 2); no empty cell has 2
  active neighbours, so nothing is born. Gen 1 onward is empty.
  → same all-zero outputs as `anchor_empty`.

> Deliberately **do not** hand-author multi-generation evolutions of non-trivial patterns.
> Hex neighbour counting by hand is error-prone, and the exact adjacency/orientation is a
> `[CONFIRM vs stepper]` detail anyway. Anything past the two anchors is stepper-generated.

### 2.2 Stepper-generated bulk (the oracle does the work)

The generator runs `stepper.dart` over a curated set of input grids and freezes the
outputs. Curate to cover the behaviours that matter, not random grids:

- a **low-seed bloomer** (few cells → grid-wide growth) — the tier-gated archetype;
- patterns that drive **each element** to dominance (one per element, to pin the enum/zone
  mapping — §1 of CIRCUIT_IO);
- a **multi-formula** trajectory (≥2 completed triplets);
- a **supreme-dominance** run (sets supreme flags);
- a pattern that **first reaches the border around gen 4** (pins the T−4 free threshold);
- **boundary T**: `T=1`, `T=tier_max`, and one spell per tier (12/24/48);
- a **near-border / buffer-interaction** case (growth crossing rings 9–11 into 12).

Each becomes a frozen positive vector. Regenerating must reproduce identical values — a
diff means the stepper changed and the change needs review.

---

## 3. Negative vectors (the reject-list — Fable's hunting ground)

One vector per `CIRCUIT_IO.md` §11 item. The first five are hand-authorable; the last two
are noted as needing care.

| id | malformed how | should be caught by |
|---|---|---|
| `neg_nonboolean_cell` | `raw_overrides {"0": 2}` | §10.1 cells ∈ {0,1} |
| `neg_seeded_buffer` | `raw_overrides {"300": 1}` (active cell at index ≥217) | §10.2 buffer/border empty at T=0 |
| `neg_seeded_border` | `raw_overrides {"400": 1}` (active border cell) | §10.2 |
| `neg_commitment_mismatch` | valid grid + `declared_override.commitment` = wrong value | §10.4 commitment binds grid |
| `neg_forged_trajectory` | valid grid + `declared_override.dominance_trajectory` = a lie | §10.5 trajectory = true evolution |
| `neg_forged_activations` | valid grid + `declared_override.border_activations` = wrong totals | §10.6 activations = true masked sum |
| `neg_out_of_range_T` | `T: 0`, and a sibling with `T: tier_max+1` | §10.7 / §11.7 range |

**The subtle one — author with the generator's help:**
- `neg_mask_abuse` — a grid that is **quiet before generation T but produces border
  activity after**, paired with a `declared_override.border_activations` that *includes*
  the post-T activity. The circuit must reject because the correct value masks generations
  `≥ T`. This is the exact shape of a spell-leak via a sloppy mask (§10.6), and it's the
  single most important negative vector. It needs the stepper to *find* a grid with the
  quiet-then-active profile, so generate it rather than hand-authoring it.

  **[RESOLVED M3.1, 2026-06-16]** Found via `scripts/find_mask_vector.dart`: full ring-8
  (48 cells) is quiet through generation 2 and fires at generation 3. But `declared_override`
  vectors of this shape (here and the other three below) turned out to test **SNARK
  public-input binding**, not a Runewright circuit constraint — `border_activations`,
  `dominance_trajectory`, and `commitment` are all circuit *return values*, so `nargo execute`
  structurally cannot accept a declared value that disagrees with what the witness computes;
  §10.4/§10.5/§10.6 are enforced by construction, not by an explicit assert that could be
  dropped. The circuit-relevant half of each is discharged by a positive vector instead (see
  `test_vectors/seeds.json`: `mask_boundary_zero` for `neg_mask_abuse`, `first_border_activation`
  for `neg_forged_activations`, every positive vector's frozen commitment for
  `neg_commitment_mismatch`). The only piece these four still owe is whether `bb verify` rejects
  a proof whose public-input *bytes* were tampered with post-hoc — a property of UltraHonk's
  encoding, not of this circuit — deferred to **one** end-to-end tamper smoke test in M3.4
  (prove, flip a byte, confirm `bb verify` rejects), which also resolves the `[CONFIRM: noir]`
  CLI question in §7 below.

  **[RESOLVED M3.4]** `ffi/src/bin/tamper_test.rs`: proved a real tier-12 proof, flipped one
  byte of the commitment (public-input index 3, byte offset 100 — see §7), and confirmed
  `verify_ultra_honk` returns `Ok(false)`. All four `declared_override` vectors are now fully
  discharged — the circuit-relevant half by the positive vectors (as above), the SNARK-binding
  half by this one test.

> Discipline: when CC implements each §10 constraint, it pairs the constraint with the
> negative vector that fails if the constraint is dropped, and confirms the vector
> actually fails *before* the constraint is added (red), then passes after (green). That
> red-then-green step is what proves the constraint is load-bearing rather than decorative.

---

## 4. The generator (Dart → frozen corpus)

Skeleton. The `// [CONFIRM: stepper API]` and `// [CONFIRM: noir]` lines are integration
points CC fills against the real stepper and circuit — do not assume these signatures.

```dart
// scripts/gen_vectors.dart  — produces test_vectors/corpus.json from seed inputs
Future<void> main() async {
  final seeds = loadSeedInputs('test_vectors/seeds.json'); // hand-authored inputs
  final out = <Map<String, dynamic>>[];

  for (final seed in seeds) {
    final grid = expandSparse(seed.activeCells, seed.rawOverrides); // [0/1; 469]

    if (seed.kind == 'positive') {
      // CA outputs come from the stepper (oracle #1):
      final result = Stepper.run(grid, seed.T, seed.tierMax);  // [CONFIRM: stepper API]
      // commitment comes from the Noir side (oracle #2), NEVER Dart Poseidon2:
      final commitment = NoirHash.commitmentOf(grid);          // [CONFIRM: noir] e.g. bb/nargo call
      out.add(freeze(seed, result, commitment));
    } else {
      // negatives carry no trustworthy expected outputs — only `verifies:false`.
      out.add(seed.toJson());
    }
  }
  writeJson('test_vectors/corpus.json', out);
}
```

The seed file (`seeds.json`) is hand-authored (the anchors + the curated bulk *inputs* +
all negatives). The generator turns it into the frozen `corpus.json`. Commit both: seeds
are the human intent, corpus is the frozen contract.

---

## 5. The two runners

### 5.1 Dart stepper-regression runner

Loads `corpus.json`, runs the stepper on each **positive** vector's input, asserts the CA
outputs match the frozen values. Ignores `commitment` (not the stepper's job). Catches
stepper regressions. Runs in `flutter test`.

### 5.2 Noir circuit runner (the contract enforcement)

For each vector, build the witness + public inputs (applying overrides), then:
- **positive** → `nargo execute` + `bb prove` + `bb verify` must **succeed**, and the
  circuit's computed commitment must equal the frozen one. // [CONFIRM: noir CLI]
- **negative** → witness generation or proving/verification must **fail**. A negative that
  *verifies* is a release-blocking bug.

Runs per tier (12/24/48) against that tier's circuit.

---

## 6. CI wiring & the rule

- One script — `scripts/run_vectors.sh` — runs §5.1 then §5.2 across all tiers and exits
  nonzero on any drift or any negative that verifies.
- **The rule (also in `CLAUDE.md`):** every change to the stepper or a circuit runs the
  full corpus before commit. Adding a constraint? Add/confirm its negative vector first.

---

## 7. Integration checklist (what CC fills in)

- [x] Confirm the `Stepper.run` API and output shape; wire §4 + §5.1. → `runStepper` in
      `lib/engine/ca_run.dart`; wired into `scripts/gen_vectors.dart`.
- [x] Confirm how to get a commitment from the Noir side (`bb`/`nargo`) for §4; never Dart.
      → `nargo execute` against `circuits/ca_v2_4_tier12`, parsed from its `Circuit output:`
      line. `bb prove`/`verify` (full proof, not just witness) still open — see M3.4 below.
- [x] Confirm the `nargo`/`bb` execute/prove/verify CLI for §5.2. → `nargo execute` confirmed
      and wired (`scripts/gen_vectors.dart`); `bb prove`/`verify` deferred to M3.4 (only needed
      for the four `declared_override` vectors' SNARK-binding half, see §3 resolution above).
- [x] Author `seeds.json`: the 2 anchors, the curated bulk inputs (§2.2), all negatives (§3).
- [x] Generate `corpus.json`; eyeball the two anchors (must be all-zero CA outputs). → confirmed
      all-zero; `first_border_activation`/`mask_boundary_zero`/`neg_mask_abuse` (real, ring-8
      based) replaced an earlier hand-picked 6-cell stub that never actually reached the border.
- [x] Build `neg_mask_abuse` with stepper help (§3) — the priority negative. → done via
      `scripts/find_mask_vector.dart`; its circuit-relevant half is now also covered by the
      `mask_boundary_zero` positive vector (see §3 resolution above).
- [x] Wire `run_vectors.sh` into CI; make a dropped constraint demonstrably turn a negative
      vector red. → `scripts/run_vectors.sh` runs stepper tests → recompile → `gen_vectors.dart`
      in one command; exit 0 confirmed on the current tier-12 circuit.
- [x] **M3.4 follow-up:** one end-to-end `prove_ultra_honk` + public-input-byte-tamper +
      `verify_ultra_honk` smoke test (`ffi/src/bin/tamper_test.rs`), resolving the
      SNARK-binding half of the four `declared_override` vectors. **Encoding confirmed
      empirically** (not assumed): `[4 bytes BE num_public_inputs][public inputs, 32B
      each][proof, 32B fields]`. Public inputs are ABI-declaration order — `pub`
      *parameters* first (`T`, `owner_pubkey`, `ruleset_version` — indices 0-2), then the
      `pub` return tuple (`commitment` at index 3, `border_activations[4]` at 4-7,
      `dominance_trajectory[12]` at 8-19, `supreme_flags[12]` at 20-31). Confirmed by
      printing all 32 fields of a real tier-12 proof and matching each to its known
      plaintext value. Flipping one byte of the commitment (byte offset 100) makes
      `verify_ultra_honk` return `Ok(false)` — tampering correctly rejected.
