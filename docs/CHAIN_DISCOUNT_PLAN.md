# Chain Casting Discount — implementation plan

*Drafted 2026-07-26 on `feature/practice-mode`. Rules ratified by Soren the same day (§3).
Target: bring the chain discount system into agreement with `runewright_design_v3_0.md`
§Chain Discount System, **as amended by the simplifications in §3 below**.*

---

## 1. Where we actually are

The chain system is **already partly built** — this is a correction-and-completion job, not
a greenfield one. What exists today:

| Piece | Location | State |
|---|---|---|
| Chain state on the avatar (`activeChainElement`, `chainLengths` map, negatives allowed) | `lib/battle/models/wizard_avatar.dart:208-214` | ✅ built |
| `chainDiscountMultiplier(alignmentFraction)` | `wizard_avatar.dart:370` | ⚠️ **wrong formula** (G1) |
| Chain advancement on cast (`_updateChainState`) | `lib/battle/engine/turn_loop.dart:2637` | ⚠️ partial (G2, G5) |
| Chain regression on inaction (`_regressChain`) | `turn_loop.dart:2659` | ⚠️ regresses by 1, design says 2 |
| Discount applied in the local cost path (`_spellManaCost`) | `turn_loop.dart:4212` | ✅ wired |
| Discount applied in the certified/peer path (`_certifiedManaCost`) | `turn_loop.dart:4144` | ✅ wired, order-matched |
| Chain state folded into the lockstep state hash | `lib/battle/models/battle_state.dart:255-262` | ✅ built (int32) |
| Fire-Water "Chain Interaction" effects (fast/slow/transfer/wipe) | `lib/battle/engine/effect_applicator.dart:415-452` | ✅ built |
| `chainFast` / `chainSlow` status badges | `lib/ui/battle_screen.dart:185` | ✅ built |
| Chain length visible to the player anywhere | — | ❌ missing |
| Any test coverage of chain state | — | ❌ **zero** |

---

## 2. The gaps, in severity order

### G1 — The discount formula is inverted (balance-critical)

The design doc states two things that contradict each other:

```
discount = (0.9 ^ chain_length) × (fraction of formulas aligned)
```
> Examples (chain length 5): pure fire on fire chain `0.9^5 × 1.0 = 59%`

…but the table immediately below says length 5 → **41%** discount. The **table is correct**:
`1 − 0.9^1 = 0.10`, `1 − 0.9^3 = 0.271`, `1 − 0.9^5 = 0.410`, `1 − 0.9^10 = 0.651`. It also
matches the §Spell Mana Cost commentary — *"a maxed chain (~65% off at length 10) offsets
roughly 4–5 generations of exponential growth (`1.25^4.6 ≈ 2.9 ≈ 1/0.35`)"* — which only
closes if length 10 leaves you paying `0.9^10 ≈ 0.35` of base.

So **`0.9^L` is the cost multiplier retained, not the discount.** The prose formula line and
its two worked examples are mislabeled. `chainDiscountMultiplier` transcribed the mislabeled
line, and the call sites then apply `cost × (1 − discount)`. Net effect today:

| Chain length | Design cost multiplier | Current code cost multiplier |
|---|---|---|
| 1 | 0.90 | **0.10** |
| 3 | 0.73 | 0.27 |
| 5 | 0.59 | 0.41 |
| 10 | 0.35 | 0.65 |

A single aligned follow-up cast currently costs **10% of base**, and the curve runs backwards —
short chains are wildly over-rewarded and long chains are *punished* relative to short ones,
which destroys the "chains are the currency that purchases T" design intent.

### G2 — Advancement keys on the wrong thing, and disagrees with the discount

`_updateChainState` reads `formulas.first.affinity` only. So a water-fire spell cast on a fire
chain is read as a pure *water* cast and breaks the chain — while `_certifiedManaCost` reads
the same spell as ½-aligned and hands it a discount. The advancement and discount paths do not
share a definition of "aligned". Under the §3 purity rule both collapse to the same check, so
this is fixed by construction — but they must be **refactored onto one shared helper** so they
can't drift again.

### G3 — Regression is by 1, design says 2

`_regressChain` does `current - 1`, and drops the chain entirely at `current <= 1`. Design:
*"Taking no chain action that turn → the chain regresses by 2."*

### G4 — Summons free-ride on chains

`_parsedFormulas` runs on summon spells too, so a summon **takes** the chain discount at commit
time — but `_applySpell` returns early for `spell.isSummon` (`turn_loop.dart:2429`), before
`_updateChainState` at line 2503. A summon therefore spends a chain without ever advancing,
breaking, or regressing it: a free chain-preserving turn that also collects the discount.

### G5 — `chainSlow` is a silent no-op

`_updateChainState` does `increment = multiplier >= 2.0 ? 2 : 1`, so the Earth-flavor "chains
grow at half speed" effect (`chainAccMultiplierPct: 50`) has **no mechanical effect at all**.

### G6 — No player-visible chain state

The player sees `Chain+`/`Chain−` status badges but not their actual chain element or length,
which is the number the entire mana economy pivots on. A chain that decays invisibly is a chain
nobody plays around.

### G7 — Zero test coverage

Nothing in `test/` touches `chainLengths` or `activeChainElement`. Given this feeds
`_certifiedManaCost`, which both peers must compute identically (the B-1/B-8 trust boundary
in CLAUDE.md), that's the real risk here.

---

## 3. Ratified rules `[RESOLVED — Soren, 2026-07-26]`

These amend `runewright_design_v3_0.md` §Chain Discount System. **Hybrid chaining is
deliberately deferred**, not cut: revisit after playtest if players report it would be fun and
balanced.

**R1 — Formula.** `cost_multiplier = 0.9 ^ chain_length`; equivalently
`discount = 1 − 0.9 ^ chain_length`. The doc's table is canonical; its prose formula line and
two examples are mislabeled and get corrected.

**R2 — Purity gate.** Only **one** discount chain is active at a time, and only a **pure**
spell — every completed formula sharing the same first-element — is eligible for a discount.
Hybrids get no discount. The alignment-fraction term is removed from the model entirely.

**R3 — Hybrids break the chain.** Casting any hybrid spell resets the chain to 0 and clears
the active element (a hybrid has no single affinity to become the new active one). Purity is
the whole rule: anything not pure-and-aligned costs you the chain.

**R4 — Summons are ordinary chain casts**, for both building and discounts. A summon's chain
affinity is the **creature's derived affinity** — `CreatureSpec`'s most-common-element rule
with first-appearance tiebreak (`creature_spec.dart:132`), the same affinity the minion
actually fights with. That is single by construction, so every summon is chain-eligible.

**R5 — Modifiers compose multiplicatively**, never additively, in the fixed order both cost
paths already use: certified base → chain → Efficiency (×⅔) → sorcerer vocal multiplier →
`nextSpellCostDouble`. Each step multiplies the running cost.

**R6 — No negative prices, ever.** The chain term is always a multiplier ≥ 0. The Air-flavor
Chain Interaction sets chains to −1, which yields `0.9^-1 = 1.111` — an ~11% *surcharge*, per
the effect table's "mana cost increased instead of decreased". (The earlier draft's talk of a
"negative discount" meant the *discount fraction* went negative; the price never does. The API
change in Phase 1 makes this unambiguous by returning the multiplier directly.)

**R7 — Regression floors at 0.** Inaction is "a gentler decay", not a penalty; only the Air
effect can push a chain negative.

### Derived rule table

| Event | Effect on chain |
|---|---|
| Pure spell, affinity == active element | advance +1; discount `0.9^L` applies (L = pre-cast length) |
| Pure spell, affinity != active element | break to 0; that element becomes active at length 1; no discount |
| Hybrid spell (2+ distinct formula affinities) | **break to 0, no active element**; no discount |
| Summon | as a pure spell of the creature's derived affinity |
| Pass / Dash / Meditate | regress 2, floor 0 |
| Fizzled or counter-charmed cast | regress 2, floor 0 (unchanged) |
| Air Chain Interaction effect | all chains set to −1 → 1.11× cost surcharge |

Note the discount uses the **pre-cast** length: your first fire cast starts the chain at 1 and
pays full price; the *second* pays 0.9×. That is what makes the doc's table read correctly.

---

## 4. Implementation

Order follows the repo's standing discipline: **contract → Dart oracle → tests**. No circuit
work — chain state is entirely off-circuit game logic, so no golden-corpus regeneration and
**no `RULESET_VERSION` bump** (reserved for consensus-visible *CA rule* changes).

But this **is** lockstep-consensus-visible: chain state feeds both the state hash and
`_certifiedManaCost`. Two devices on different builds desync mid-match. Land it as one commit;
don't stage it across a version boundary.

### Phase 0 — Fix the contract
`docs/runewright_design_v3_0.md` §Chain Discount System:
- correct the formula line to `cost_multiplier = 0.9 ^ chain_length` and relabel the two
  examples as cost multipliers (`0.9^5 = 59% of base cost`, i.e. a 41% discount);
- record R2/R3 as `[RESOLVED — simplified 2026-07-26]`, replacing the hybrid-fractional rule,
  with a one-line note that hybrid chaining is deferred pending playtest feedback;
- record R4, R6, R7 next to the rules they settle.

### Phase 1 — Avatar state and the discount API
`lib/battle/models/wizard_avatar.dart`

- **Storage unit: half-credits.** Keep `Map<SpellAffinity, int>` (so the state hash needs no
  type change) but store chain length in **half-steps**: a normal advance is `+2`, `chainFast`
  (200%) is `+4`, `chainSlow` (50%) is `+1`. Effective length is `credits ~/ 2` — use
  `.floor()` semantics explicitly, since the Air effect can make credits negative and Dart's
  `~/` truncates toward zero. This is what makes `chainSlow` mean something (G5) without
  introducing floats into the hashed state.
- **Replace `chainDiscountMultiplier(double alignmentFraction)` with
  `double chainCostMultiplier(SpellAffinity? pureAffinity)`** returning:
  - `1.0` when there is no active chain, or `pureAffinity` is null (hybrid), or it doesn't
    match the active element;
  - `pow(0.9, effectiveLength)` otherwise.

  Returning the **multiplier** rather than a discount makes R5/R6 structural — the call sites
  become `cost = (cost * caster.chainCostMultiplier(a)).ceil()`, identical in shape to the
  Efficiency and sorcerer steps, and no path can produce a negative price.
- Add a static `SpellAffinity? pureAffinityOf(List<ParsedFormula>)` — returns the single
  affinity if all formulas share one first-element, else null. **One definition of "pure",
  used by both the discount and the advancement paths** (this is the G2 fix).

### Phase 2 — Advancement and regression
`lib/battle/engine/turn_loop.dart`

- `_updateChainState`:
  - summon spells → affinity = `CreatureSpec` affinity derived from the certified element
    sequence (R4); other spells → `pureAffinityOf(formulas)`;
  - null affinity (hybrid) → clear `activeChainElement`, zero the chain (R3);
  - matches active element → `credits += 2 × chainAccumulationMultiplier` (rounded to int);
  - differs → zero the old chain, set active to the new element, credits = 2.
  - Delete the `multiplier >= 2.0 ? 2 : 1` integer hack.
- `_regressChain`: subtract `4` credits, floor at `0`, clear `activeChainElement` at 0 (R7).
- **Summon path (G4):** `_applySpell`'s `spell.isSummon` early-return at line 2429 must call
  `_updateChainState` before returning — or, cleaner, hoist the `_updateChainState` call at
  line 2503 to the caller so every cast path runs it exactly once.

### Phase 3 — Cost paths stay byte-identical
- Both `_spellManaCost` and `_certifiedManaCost` call `chainCostMultiplier` at step 2, same
  relative position as today — the fix lives inside the shared helper, so the operation order
  is unchanged. **Do not** add a second purity computation; both call `pureAffinityOf`.
  (CLAUDE.md: `_certifiedManaCost` is the single source of truth for peer spell cost and must
  stay operation-order-identical to `_spellManaCost`.)
- **Summons in the certified path:** `_certifiedManaCost` currently receives only
  `certFormulas`. For R4 it also needs the certified element sequence —
  `TrajectoryParser.certifiedElementSequence(outputs)`, already computed nearby at
  `turn_loop.dart:3985`. Pass it, and derive the creature affinity from *certified* data, never
  the wire.
- **Trust note (pre-existing, now load-bearing):** `spell.isSummon` is a caster-declared wire
  flag. It already switches resolution wholesale, so trusting it is not new — but under R4 it
  now also selects which affinity gates the discount. Worth a line in the findings doc; not
  in scope to fix here.
- Keep the per-step `.ceil()` in both paths (R5's fixed order). Don't batch the multiplies into
  one expression "for accuracy" — the two paths must round identically, and the current
  per-step form is already mirrored.

### Phase 4 — State hash
`lib/battle/models/battle_state.dart:255-262` — **no code change needed**; `writeInt32` still
receives an int. The *unit* changes from length to half-credits, which changes the hashed bytes'
meaning. Both peers run the same build and every match starts from zero, so there's no
compatibility concern — but note it in the commit message.

### Phase 5 — Chain Interaction effects
`lib/battle/engine/effect_applicator.dart:415-452` — convert to credit units:
- `negativeValue` (−1) → `−2` credits;
- `chainTransferBonus` (+1 under potency) → `+2` credits;
- the transfer/copy path (`chainLengths.addAll(target.chainLengths)`) is unit-agnostic and
  needs no change, since both sides now store credits.

### Phase 6 — UI
`lib/ui/battle_screen.dart` — show the local wizard's active chain element and integer length
near the mana bar (an elemental pip with `×3` and the current `−27%`). The opponent's chain is
already public information in this ruleset (the Water-flavor transfer effect reads it), so
showing theirs is consistent — worth a nod from Soren before building it.

---

## 5. Test plan

New: `test/battle/engine/chain_discount_test.dart`

**Discount table — the design doc's table, verbatim, as the oracle:**
- pure aligned at L = 1, 3, 5, 10 → cost multiplier 0.90, 0.73, 0.59, 0.35 (discounts 10%,
  27%, 41%, 65%)
- L = 0 / no active chain → 1.0
- hybrid spell on a matching chain → 1.0 (R2: no discount)
- L = −1 (Air Chain Interaction) → 1.11× surcharge, **and the resulting price is > 0** (R6)

**Advancement:**
- pure aligned cast advances by 1 (2 credits)
- pure off-alignment cast zeroes the old chain and starts the new element at 1
- hybrid cast zeroes the chain **and** clears the active element (R3)
- summon advances the chain of its creature-derived affinity, including the tiebreak case
  where the most-common element isn't the first (R4)
- `chainFast` (200%) doubles the credit; `chainSlow` (50%) halves it, so two slow casts equal
  one normal step (regression test for G5)

**Regression:**
- Pass / Dash / Meditate regress by 2
- fizzled and counter-charmed casts regress by 2
- regression floors at 0 and clears the active element
- regression does not drive a negative (Air-effect) chain further negative

**Trust boundary — the test that actually matters:**
- parity: for the same avatar chain state and spell, `_spellManaCost` and `_certifiedManaCost`
  return the identical integer, across a matrix of chain lengths × {pure aligned, pure
  off-alignment, hybrid, summon}. This is the B-1/B-8 discipline applied to the chain input,
  and it's what catches a future edit drifting one path from the other.
- state-hash determinism across a serialize round trip with a non-zero chain.

Regression sweep: full `flutter test` (446+ currently green). `effect_applicator_test.dart`
covers the chain effects and will need updating for the credit-unit change.

Hardware gate: per the verification hierarchy, a `flutter run -d linux` pass casting a few
chained spells and watching the HUD number move before calling it done.

---

## 6. Out of scope (deliberately)

- **Hybrid chaining** — deferred by R2, not cancelled. Revisit after playtest. The
  `alignmentFraction` machinery is removed rather than left dormant; re-adding it means
  restoring one term in `chainCostMultiplier` and fractional credits in `_updateChainState`,
  both of which the half-credit storage unit already accommodates.
- **Melee-as-inaction.** Design says a melee attack consumes the cast action and so regresses
  the chain; this implementation runs melee as a *separate* commit-reveal, so a player can cast
  **and** melee in one turn (`turn_loop.dart:30-36`). Under the current structure a
  melee-without-cast turn already regresses via `PassAction`. Flagging, not changing.
- **The Fire-Water Chain Interaction effect semantics** (already implemented; only its units
  change here).
- **Void spells / wild magic interaction with chains** — the doc doesn't define one.
