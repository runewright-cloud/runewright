# M0 + M1: Refinements and Directives

Your M0+M1 plan is approved with the changes below. The §13 reconciliation work was good (center-index arithmetic and the `seeds.example.json [0]` border-cell §10.2 violation are both correct). These directives tighten the parts most likely to ship silent bugs.

---

## Answers to your three questions

1. **`anchor_single_center` index:** use **234**. Simplest, and it preserves the hand-verifiable property. But treat this vector as a smoke test only — it is degenerate (all-zero output) and is **not** evidence the oracle is correct. See the upgraded M1 gate below.
2. **`Stepper.run()` location:** new file **`lib/engine/ca_run.dart`**. Keep the single-step primitive (`CAStep.step`) separate from the multi-step oracle.
3. **CI:** there **is** a GitHub remote (currently used as a sync repo), so Actions are available — write the workflow; it runs on push. The repo owner is new to Git, so keep the workflow fully self-contained: no required secrets, triggers on push + PR, no manual setup steps.

---

## Required changes to the plan

### 1. Pin the decay formula as a concrete integer sequence — do not leave it as prose

Your plan writes decay as `floor((gen+1)/2)`. The canonical spec (design doc v2.3, Phase 1.5 report, Dart) says `floor(generation_count/2)` / `stepCount div 2`. These diverge at the **first** decaying generation (`floor(gen/2)` → 0,0,1,1,2…; `floor((gen+1)/2)` → 0,1,1,2,2…). Your version may be the correct 0-indexed restatement of the Dart's 1-indexed `stepCount`, but it does not textually match the doc, and this is exactly the off-by-one that corrupts every golden vector containing decay.

Do this:
- Derive the exact behavior from the Dart `stepCount` semantics: **when does `stepCount` increment relative to the decay subtraction, and what is the decay at the first dominant generation?**
- Write the decay as an explicit table for `gen = 0..6` and **assert that exact sequence in a Dart unit test.** Reconcile `floor((gen+1)/2)` vs `floor(generation_count/2)` to one sequence and document which is authoritative.
- This is the highest-priority correctness item. Do not proceed to golden-vector generation until the sequence is pinned and tested.

### 2. Tier architecture is RESOLVED — reconcile the design doc to match

The 3-tier design (12/24/48) is ratified. Rationale to record: the large tiers exist so rare "big finisher" spells are possible for spectacle/story; their long inscribe/prove time is accepted (and treated as a feature — these spells feel special). Most players stay on lower tiers and are unaffected.

Do this:
- Update **design doc v2.3** — its "single max-T circuit / one VK / `T_max = 20`" section now **contradicts** the ratified decision. Replace it with the 3-tier model and the rationale above. (CIRCUIT_IO.md already reflects tiers; the design doc is the stale one.)
- Document the proving-cost reality so it is not a surprise later: tier 48 ≈ ~940k gates (yellow band, multi-minute proving on mid-range mobile). Note this is the expected, accepted cost for the top tier.
- Confirm masking (count only `gen < T` within the selected tier) is required in **all** tiers — this is consistent regardless of the architecture choice.

### 3. Fix the oracle's authority direction, and cross-check the single-step primitive

The Phase 1.5 report states the **Dart code is canonical** ("all resolved in favor of Dart code") — the circuits were derived from it. So:
- Frame `Stepper.run()` as wrapping the **canonical Dart single-step**, not as "implementing the same loop as `ca_natural_v2/src/main.nr`." When Dart and circuit disagree, Dart wins unless explicitly re-ratified.
- Phase 1.5 only verified Noir-vs-Noir (`ca_natural_v2` == `ca_lookup_v2`). The Dart `CAStep.step` was **never directly cross-checked against the Noir per-cell transition.** Add a **single-generation Dart↔Noir full-grid diff** (run one step in both from a non-trivial grid, compare all 469 cells) before trusting the multi-step runner. A multi-step output match can hide compensating per-step errors.

### 4. Border-zone per-cell verification is an M1 gate, not a bonus

The `18/18/18/18` count assertion in `gen_grid_constants.py` is necessary but **not sufficient** — the Python generator feeds the circuit and `BorderZones._compute()` feeds the oracle; they are independent implementations (7-segment clockwise vs 4-segment counter-clockwise). If they disagree on *which* cell sits in which zone while still summing to 18 each, every dynamic golden vector is silently wrong.

Do this: enumerate all 72 border cells, diff the generated `BORDER_ZONE` constant against `BorderZones._compute()` **per cell**, and assert identity. This must pass before any dynamic vector is generated.

### 5. Commitment stays opaque on the Dart side — resolve the doc conflict

The Phase 1.5 report says "the Dart side will need to implement the same sponge sequence." Design doc v2.3 says the opposite: never reimplement Poseidon2 in Dart; treat commitments as opaque public-input values. **Resolve in favor of v2.3.** Opaque value-comparison covers both counter-charm targeting (compare observed commitment values) and re-inscription (the prover recomputes in-circuit). Annotate the stale note in the Phase 1.5 report so it does not pull a future implementer into writing a Dart Poseidon2.

---

## Smaller, practical items

- **`bootstrap.sh` pins a `bb` nightly** (`5.0.0-nightly.20260324`). Nightlies fall off release feeds; the laptop-replication use case needs this to survive months later. Either vendor the binary in-repo with a checksum, or document a pinned-stable fallback. Do not depend on an un-checksummed nightly URL.
- **`.gitignore`:** ignore bulky proving keys and `target/` build output, **but commit the small VK + ACIR bytecode** for audit/reproducibility — M2's FFI links against a VK, and committing it keeps the spike deterministic.
- **CI gate:** change "skip if `corpus.json` empty" to **"error if `corpus.json` is present but the Noir runner is still stubbed."** Otherwise vectors accumulate that nothing ever checks.
- **Element-order fix is doc-only *only if*** nothing consumed the transposed `[fire, water, earth, air]` order. The Dart is name/enum-keyed (immune), but confirm the 64-effect table worksheet did not bake the wrong order positionally before treating this as a pure doc edit.
- **M2 scope note:** the spike de-risks toolchain/linking, **not** v2.4 witness/public-input marshalling (packed commitment, `owner_pubkey`, `ruleset_version`, masking, tiers). Expect the FFI interface to be reworked at M3 regardless; size the spike accordingly.

---

## Upgraded M1 acceptance gate

Replace "the two anchor vectors produce all-zero outputs" with:

1. The pinned decay sequence (item 1) is asserted in a passing unit test.
2. The per-cell border-zone diff (item 4) passes.
3. The single-generation Dart↔Noir full-grid diff (item 3) passes.
4. **At least one non-trivial dynamic vector** — one that activates a border zone **early** (low T, so the first decay steps are exercised) and contains at least one dominance transition — matches between the Dart multi-step oracle and the single-step Noir check.
5. No `[CONFIRM vs stepper]` items remain in CIRCUIT_IO.md except the deferred Ed25519 one.

Rationale: the existing benchmark grid does not touch the border until step 14, and all-zero anchors exercise none of the decay/zone/transition logic. An oracle validated only on those is trivially correct and useless. The early-activation vector is what catches the item-1 off-by-one.
