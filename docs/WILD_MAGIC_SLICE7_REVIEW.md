# Wild Magic vNext — Slice 7 review gate (pre-coding)

*Written 2026-09-03. **No code changed.** `git status` is clean.*

This slice was specified as "collect → coalesce → order → resolve" for simultaneous
Wild Magic triggers. The brief carried two explicit pre-coding stop gates:

> §3 — "If current action resolution makes full collection impossible without a
> substantial engine restructuring, report the narrowest safe boundary available
> **before coding a larger architecture**."

> §8 — "Stop and report before inventing a materially new entropy scheme if necessary."

**Both fired.** This document is that report.

---

## 1. The decisive finding

**Within a single cast, two triggers can never share an effect kind.**

`wildMagicEffectFor` is a total function from 3 rows × 4 elements → 12 effect kinds,
and every one of the 12 cells maps to a *distinct* `WildMagicEffectKind` (verified by
counting the lookup table: each constant appears exactly once). A single cast produces
triggers as the cross product of *its* fired rows × *its* eligible elements
(`WildMagic.triggersFor`), so every trigger a single cast emits lands in a different
cell, and therefore a different effect kind.

Consequences:

* Coalescing **cannot fire** at the per-cast boundary. Building the pipeline there
  would be pure ceremony — an engine-version bump and a consensus-visible RNG change
  buying exactly zero behavioural coalescing.
* The brief's §2 premise *"If Fire and Earth both produce the same effect kind"* is
  **not reachable under today's fixed table.**
  *(Corrected 2026-09-03: this bullet went on to say it becomes reachable under
  Mutable Leylines, "the slice that can remap (row, element) → effect". It is
  now ratified that **Mutable Leylines does NOT rekey `wildMagicEffectFor`** —
  a mutable leyline rekeys Wild Magic solely through `leylineConfigHash`, which
  already ships. Same-cast duplicates are therefore permanently unreachable, and
  the machinery this slice built exists for cross-cast simultaneous duplicates
  and N-player semantics — which is what it is actually used for.)*
* Every duplicate that is reachable **today** is a *cross-cast* duplicate: two
  different casts in the same Phase 5 whose hashes hit the same row and whose eligible
  elements overlap. e.g. both players cast `000`/air spells → **two Zephyrs, one after
  the other, everyone teleported twice.** That is the live bug, and it sits at the
  boundary that needs the restructuring.

So the only boundary worth building is the one the brief predicted might be blocked.

---

## 2. Where Wild Magic actually fires today

```
TurnLoop.runTurn
 └─ Phase 5: DeterministicResolution.resolveActions(actions: [local, peer, ...delayed fires])
      sorted := stable total order (group → T → commitmentHex → playerId)
      for (actor, action) in sorted:
          if (!actor.isAlive) continue                 ← a dead caster is skipped
          breaksStatuesque / chain / mana …
          case SpellCastAction:
              cert     := delayed ?? own-proof ?? certifiedPeerCasts   (triggers live here)
              fizzle / cloud / out-of-range  → no cast
              resolvedTarget := _turbulentTarget(...)                  ← consumes RNG
              counterHit     := _findCounteringCharm(castSequence)     ← consumes a charm
              if (fullyCountered) → skip applySpell entirely  (invariant A1)
              else applySpell(...)
                     └─ _fireWildMagic(ctx, actor, spell, certWildMagic)
                          for trigger in triggers:      ← row-then-element order
                              rng = HashRng(wildMagicSeed(entropy, playerId, nonce++))
                              WildMagicApplicator.apply(...)     ← MUTATES STATE NOW
                          await drainForcedCasts(entropy)
                     └─ Rippling coin → LOS → formula effects
```

Three structural facts follow:

1. **Wild Magic is interleaved per-action**, not phased. Caster A's triggers fully
   resolve — terrain placed, bodies teleported, forced casts drained — before caster
   B's action is even examined.
2. **A cast's admission is decided inside the loop.** Whether a cast reaches
   `applySpell` at all depends on `fizzledForMana`, the cloud restriction, range, and
   the counter-charm match — and the counter-charm check *consumes* a charm, while
   `_turbulentTarget` *consumes* RNG. Collecting triggers ahead of time means hoisting
   all of that into a first pass.
3. **The per-trigger RNG seed is order-dependent by construction.**
   `TurnLoop.wildMagicSeed` folds `_consumeWildMagicNonce()` — a per-turn counter
   incremented in *encounter order*. Any change to which triggers are encountered, or
   in what order, reseeds every subsequent trigger in the turn. This is precisely the
   property §8 forbids for a coalesced event.

---

## 3. Collection-boundary options

| | **A — per cast** (`_fireWildMagic`'s trigger list) | **B — full Phase 5** (all admitted casts) |
|---|---|---|
| Coalescing value | **none** (§1: kinds are distinct within a cast) | catches every reachable duplicate |
| Restructuring | none | `resolveActions` splits into admission pass + WM phase + effect pass |
| Rulings needed | 0 | **4** (§7) |
| Changes design v4.0 §1250 ordering | no | **yes** |
| Worth an engine bump | no | yes |

**Recommendation: B, after the four rulings land.** A is not worth a consensus change.

### What B costs, concretely

`resolveActions`' single loop becomes three passes over the same `sorted` list:

1. **Admission pass** — per action, in `sorted` order: Statuesque break, chain/mana
   handling for non-casts, then for each cast the fizzle/cloud/range check, the
   turbulent roll, and the counter-charm match. Emits an `AdmittedCast` record
   (actor, spell, resolvedTarget, certified semantics, `suppressedFormulas`) or a
   rejection. Charm consumption and the turbulent nonce still advance in `sorted`
   order, so both are byte-identical to today.
2. **Wild Magic phase** — collect every admitted cast's triggers, coalesce, order,
   resolve, then **one** `drainForcedCasts`.
3. **Effect pass** — `applySpell` for each admitted cast with `fireWildMagic: false`,
   in `sorted` order. Rippling, LOS, formula effects, Scattered Gust consumption all
   unchanged.

The passes are mechanical. What is *not* mechanical is that pass 1 no longer sees the
world pass 3 builds — which is what raises rulings R2 and R3.

---

## 4. Effect classification

Coalescing key (proposed): **`effectCode` alone**, within one collection phase.
Not caster, affinity, spell, row, commitment, or arrival order — exactly per brief §2.
`effectiveBracketSteps = max(contributing bracketSteps)`.

| Effect | Class | Coalescing behaviour | Snapshot |
|---|---|---|---|
| **Zephyr** | world | one shuffle, one assignment. **Live bug today: two Zephyrs teleport everyone twice.** | phase-start (already internal to `_zephyr`'s pool build) |
| **Mountains** | world | **run `selectMountainTiles` once.** Today a second trigger re-runs the whole capped selection, so the ≤3-per-wizard bound holds per *firing*, not per *phase* — two Mountains can raise 6 walls around a wizard. | phase-start; `blockedBefore`/`occupiedBefore` already snapshotted inside |
| **Chasm** | world | **AMBIGUOUS — see R4.** Two Chasms roll two *different axes*. Coalescing to one discards a real world event; not coalescing means two intersecting chasms. | per-effect pre-mutation (`planChasmEvacuation` already does this correctly) |
| **Glacier** | world | idempotent (skips tiles already carrying terrain); coalesce for bracket/event-count only | live |
| **Mana Flood** | world | idempotent (fills to max) | live |
| **Spontaneous Combustion** | world, recipient = living wizards | **must coalesce.** `queueForcedCast` appends a *request per call*, so two SC triggers queue two forced casts per wizard — violating the ratified "exactly one per living wizard" at phase scope. One coalesced event → one request. | live at phase start |
| **Burning Hot** | world scalar | `armSpellDamageBonus` **sums** on the same target round → today two triggers stack additively. Coalescing to `max` drops that. **Pinned by an existing test** (`wild_magic_lifecycle_test.dart`, "still sums two armings for the same round"). See R5. | live |
| **Updraft** | recipient (all living) | union recipients, max bracket → longest `turns` | live |
| **Phoenix** | recipient | `_arm` merges windows; union recipients. Already non-additive. | live |
| **Statuesque** | recipient | as Phoenix | live |
| **Rippling Reflections** | world | `armRippling` merges the window and `??= 50` — deliberately idempotent across re-arms. Already correct. | live |
| **Scattered Gusts** | recipient | `armScatteredGusts` takes `min(existing, armedFrom)` — idempotent. Union recipients. | live |

**Nothing is inherently per-caster.** Every effect in the table is symmetric by
construction (`livingAvatars`, never the caster) — the file's central invariant. The
only field that is caster-specific is `WildMagicEvent.casterId`, which is attribution
for the reveal card, not targeting. See §6 for what it becomes.

**Snapshot policy.** Per brief §5, *not* one frozen world for the whole phase.
Different effect kinds still resolve in order and still see each other's mutations —
a Chasm that opens after a Zephyr lands people in it is intended. Only *within* one
coalesced event is a common snapshot required, and Zephyr, Mountains and Chasm each
already build theirs internally. No new whole-`BattleState` snapshot is needed.

---

## 5. Canonical ordering

Plan §11 ratifies "canonical row → element order". Today each effect kind *is* exactly
one (row, element) cell, so that order coincides with `WildMagicEffectKind`'s
declaration order. Per brief §4, do **not** rely on `.index`: propose an explicit
pinned code, so an enum reorder cannot silently move consensus ordering. (The
review also cited a Mutable-Leyline remap here; that is now ruled out — see §1 —
but pinning the code rather than using `.index` remains correct on its own.)

```dart
/// Canonical Wild Magic effect codes. PINNED CONSENSUS ENCODING — these numbers
/// are the phase's resolution order and enter the event RNG preimage. Never
/// derive them from `.index`; never renumber.
const Map<WildMagicEffectKind, int> kWildMagicEffectCode = {
  burningHot: 0, mountains: 1, manaFlood: 2, zephyr: 3,          // row 1 `000`
  spontaneousCombustion: 4, chasm: 5, glacier: 6, updraft: 7,    // row 2 `111`
  phoenix: 8, statuesque: 9, ripplingReflections: 10, scatteredGusts: 11, // row 3
};
```

Resolution order = ascending `effectCode`. This preserves row→element semantics
exactly while surviving an enum reorder. (Written when the table was expected to
become mutable; it will not — see §1. The pinned codes stand regardless.)

---

## 6. Proposed event-level RNG (the §8 gate)

Today: `SHA-256(entropy ‖ matchId? ‖ uint32be(turn) ‖ 0x09 ‖ utf8(playerId) ‖ uint32be(nonce))`
— caster-keyed and **encounter-order-keyed**. Unusable for a coalesced event.

**Recommended (minimal form).** The world event's stream is a function of the world
event, nothing else:

```
eventSeed = SHA-256(
      entropy[32]
    ‖ matchId[N]?                    // optional, matching _phaseSeed
    ‖ uint32be(turnNumber)
    ‖ 0x0C                           // NEW domain tag: wild-magic EVENT
    ‖ uint8(effectCode)              // §5, 0..11
    ‖ uint8(effectiveBracketSteps)   // range-checked, not truncated
)
```

Properties, against brief §8's requirements:

* **domain-separated** — new tag `0x0C`; `0x09` stays the per-*trigger*/bookmark-burn
  tag and is no longer read by the applicator.
* **order-independent** — no playerId, no nonce, no counter, no set iteration. There
  is exactly one event per `effectCode` per phase, so no collision.
* **same trigger set → same RNG**, trivially.
* **a coalesced duplicate does not reroll anything** — a second contributor changes the
  seed only if it raises `effectiveBracketSteps`, which is a deliberate part of the
  rule (a stronger event is a different event) and must be stated as such.
* uses only entropy, matchId, turn number and the effect's own public identity. **No**
  proof bytes, private state, UI state, wall clock, or object identity.

**Alternative (contributor-bound).** Also fold in the canonically-sorted contributor
tuples `(casterId, rowCode, elementCode, bracketSteps)` under a length prefix. More
entropy and binds the roll to who actually caused it; costs a longer preimage and makes
"a second caster joins" reroll the event. **Not recommended** — it buys no
unpredictability that matters (entropy is only revealed at reveal time, so there is no
pre-commit advantage either way) and it adds a canonical-ordering surface for no gain.

**Consumption is unchanged in shape:** one `HashRng` per coalesced event, handed to the
applicator exactly where `ctx.rng` is handed today. Mountains' selection, Chasm's axis
and evacuation draws, and Zephyr's shuffle all keep their current draw order *within*
the event.

---

## 7. Rulings needed before coding (all for Soren)

**R1 — Collection boundary.** Adopt boundary **B** (full Phase 5) and accept the
three-pass restructuring of `resolveActions`? *Recommendation: yes.* Boundary A is a
consensus change for zero behaviour.

**R2 — A caster killed earlier in the same phase.** Today `if (!actor.isAlive) continue`
means a wizard killed by an earlier-sorted cast never acts and never fires Wild Magic.
Under B, triggers are collected before any formula effect resolves, so that wizard's
Wild Magic *would* fire. Which is right?
*Recommendation: collect from admission, i.e. their Wild Magic fires.* The spell was
cast; Wild Magic is a property of the channelling, not of surviving to see it. It is
also the only reading that is independent of resolution order, which is the point of
the slice. But it is a real rules change and needs your word.

**R3 — Cross-caster ordering vs design v4.0 §1250.** The doc says *"Within a single
player's spell: wild magic first, then formula effects."* Under B, **all** Wild Magic
fires before **all** formula effects, so caster B's Zephyr moves people before caster
A's fireball lands. Ratify the wider reading and amend §1250?
*Recommendation: yes* — plan §11's "world events" framing already implies it, and the
per-spell reading cannot survive N-player play. But it changes existing 2-player
outcomes and is not something to assume.

**R4 — Chasm.** Two simultaneous Chasm triggers roll two different axes. Options:
(a) coalesce to one event, one axis, max bracket — consistent with "identical effects
coalesce", but silently discards a world event the players earned;
(b) treat Chasm as **not coalescible** — both axes open, intersecting at centre, one
evacuation plan computed from a single pre-effect snapshot over the union.
*Recommendation: (b), as a documented exception.* Chasm's world transition is
parameterised by a rolled axis, so two firings are not the *same* world event the way
two Zephyrs are — the brief's own carve-out for "per-trigger targeting that cannot be
represented as one event". Flagged rather than decided, per brief §2.

**R5 — Burning Hot's additive stack.** `armSpellDamageBonus` sums two armings for the
same round; this is pinned by a passing test but appears in no design doc. Plan §11
says do not stack identical global transitions.
*Recommendation: coalesce to `max` bracket, drop the additive path, update the test.*

---

## 8. Event accounting / schema

`WildMagicEvent` is **presentation only** — `lastWildMagicEvents` is rebuilt per turn
and is not read by `BattleState.toCanonicalBytes` (which hashes `WildMagicState`'s
windows and scalars, not the event list). So the representation change is free of
consensus and wire cost.

Proposed shape: **one event per coalesced world event**, with
`casterId` → `contributingCasterIds` (canonically sorted) and `bracketSteps` →
`effectiveBracketSteps`, keeping `affectedPlayerIds` as the recipient **union**.
Player-facing counts then equal resolved world events, per brief §9.

`casterId` is currently read by the reveal card; that is the only migration.
**No BattleProtocol change. No BattleState schema change.**

---

## 9. Versions, tests, replay

* `kBattleEngineVersion` **11 → 12** on implementation (RNG derivation and resolution
  semantics both move). `kBattleProtocolVersion` stays **7**, `kRulesetVersion` stays
  **3**, circuits/VK untouched. Confirmed against the brief's expectation.
* **Replay: zero deltas expected.** No script in `test/battle/replay/replay_scripts.dart`
  fires Wild Magic at all (the only mention is a comment noting invariant A1). The
  corpus is a regression net for *everything else* the restructuring touches — the
  admission-pass hoist in particular — which is exactly the value it should provide here.
* Baseline at this gate: the four Wild Magic suites + the full replay corpus pass,
  **235/235 green**, tree clean.
* Test plan for implementation: build all 18 of the brief's cases directly against the
  collect/coalesce/order seam (a `WildMagicPhase` unit taking a trigger list plus
  contributing casters), not through natural hash fixtures — per brief §10. Cases 4,
  5, 6, 13 are only expressible once boundary B exists.

---

## 10. Architecture discovered, worth recording

1. **The 12-distinct-cells property** (§1) is load-bearing and undocumented. It is why
   coalescing has been invisible so far.
   *(Corrected 2026-09-03: this item said the property "stops being true the moment
   Mutable Leylines can remap the table". Ratified: **no leyline remaps the table.**
   The property is permanent. Should any FUTURE design ever remap two affinities onto
   one effect kind, this pipeline becomes mandatory rather than optional — but Mutable
   Leylines is not that design.)*
2. **`_consumeWildMagicNonce` is an order-dependence generator.** Any future change to
   which triggers fire, or in what order, reseeds every later trigger in the turn.
   Boundary B removes the applicator's dependence on it entirely.
3. **`queueForcedCast` has no phase-scope dedup** — it appends a request per call. The
   ratified "exactly one forced cast per living wizard" is enforced per *firing*, not
   per phase. Reachable today with two SC casts in one turn.
4. **`WildMagicApplicator.selectMountainTiles`' ≤3 cap has the same shape of hole** —
   per firing, not per phase.

(3) and (4) are pre-existing bugs at phase scope, independent of this slice's
architecture, and both are fixed for free by boundary B.

---

## 11. Implementation record (2026-09-03, engine v12)

The four rulings landed as R1 (boundary = **one batch**, not the whole turn),
R2 (**liveness at admission**), R3 (**wider phase reading**, design v4.0 §1250
amended), R4 (**Chasm coalesces**, overriding this document's §7 R4(b)
recommendation), R5 (**Burning Hot by maximum**).

### What was built

| | |
|---|---|
| `lib/battle/engine/wild_magic_phase.dart` | NEW. `kWildMagicEffectCode`, `WildMagicTriggerRecord` (production), `CoalescedWildMagicEvent` + `coalesceWildMagicTriggers` (coalescing), `wildMagicEventSeed` (the pinned RNG). Production and coalescing are separate layers so Mutable Leylines plugs into the producer. |
| `deterministic_resolution.dart` | `_ResolutionGroup` → public `ResolutionGroup` + pinned `kResolutionBatchCode`. `resolveActions`' single loop became **three passes per batch** (admission / wild magic / effects), plus `_AdmittedCast` and `_resolveBatchWildMagic`. `_fireWildMagic` deleted; `applySpell` lost `certWildMagic` and `fireWildMagic`. |
| `wild_magic_applicator.dart` | Context takes a `CoalescedWildMagicEvent` instead of a `caster` + `trigger` pair; `WildMagicEvent.casterId` → `contributingCasterIds`. |
| `wild_magic_state.dart` | **Unchanged behaviour** — comments only. See "Burning Hot is batch-scoped" below. |
| `battle_screen.dart` | The reveal banner names one, both, or neither side. |
| `battle_engine_version.dart` | 11 → 12. |

### Boundary chosen

**B, scoped to a batch** — the review recommended B and the ruling narrowed it
correctly. Quick / Normal / Sluggish stay separate collection boundaries, so the
batch code is a field of the event RNG; without it a Quick Chasm and a Sluggish
Chasm on one turn would open the same axis.

### Burning Hot is batch-scoped, and the primitive stays additive

R5's "they do not add together" is a rule about ONE simultaneous batch, so it is
enforced entirely by `coalesceWildMagicTriggers` — a batch hands the applicator
one Burning Hot event at `max(contributing brackets)`, which arms the state
exactly once. `WildMagicState.armSpellDamageBonus` was deliberately left
**additive and behaviourally unchanged**: it is a persistent-state primitive and
must not be the thing that decides which events were simultaneous. A Quick
Burning Hot and a Normal one on the same turn are two separate world events
under R1, and they stack on the round they both arm exactly as before Slice 7.
A stale arming from a previous round is still replaced, not combined.

Three engine-level tests separate the cases: same batch → max (3, not 4);
Quick + Normal in one turn → separate events, additive (4); previous round →
replaced.

### Admission-pass audit — Pass / Dash / Meditate

Complete pass-1 write set:

| Action | Writes |
|---|---|
| Pass | `_regressChain(actor)` — the actor's own chain |
| Dash | + `_breakStatuesque(actor)` — the actor's own window |
| Meditate | + `applyManaGain(actor, 25)` |

Chain state and the Statuesque window are read by **no** admission input:
not `_cloudBoundToAdjacent`, not `effectiveSpellRange` (base + armor +
rangeUp/rangeDown status), not `hasTurbulent`, not `_findCounteringCharm`, and
not `action.fizzledForMana` — which is a **commit-time field, not a live mana
read**, so resolution-time mana cannot fizzle a cast. Both are also the actor's
own, and a Pass/Dash/Meditate actor has no cast being admitted. **Pass and Dash
therefore cannot reach another action's admission at all.**

**Meditate can, through exactly one channel.** `_findCounteringCharm` skips a
charm whose owner cannot afford `counterCharmManaCost`, and `applyManaGain`
raises mana — the meditator's own, and, through a Reflections `manaMirror`
link, **another wizard's**. So a Meditate can decide whether a later-sorted cast
is countered.

**Resolved by invariance, not by new semantics.** Pass 1 walks the same `sorted`
list the old single loop did, so a Meditate still executes before the admission
of every later-sorted action, at the identical position. The interaction
pre-dates Slice 7 and its ordering is byte-identical. Nothing was moved, and the
three actions were deliberately NOT relocated for symmetry — relocating them is
what would change it. Pinned by the audit group in `wild_magic_phase_test.dart`
(Meditate enables the charm; the Pass control does not; Pass and Dash reach
nothing a no-op turn does not).

*One consequence worth naming separately:* under R3, effects of a cast sorted
EARLIER no longer run before a later cast's admission. So an effect that spends
a rod, charges mana or moves a body can no longer influence a same-batch cast's
counter-charm or cloud check. That is the ruling working as intended
("no formula effect may mutate world state while the batch is being admitted"),
not a Pass/Dash/Meditate issue.

### Two findings from implementation

1. **The R3 test writes itself, in the opposite direction to the one expected.**
   The natural fixture — caster A kills caster B, B carries Mountains — does not
   end with B dead. B's walls go up during the wild-magic phase, *before* A's
   spell flies, and the spell resolves on the wall (WALL_LOS_PLAN §2.1). That is
   a sharper proof of the ordering than "B's wild magic fired at all", because it
   is order-sensitive in both directions, and it is what the test now asserts.
2. **`_regressChain` and Meditate's mana gain stayed in the admission pass**, per
   R1's "mana/admission bookkeeping retains its current ordering". Both are
   per-actor and each actor acts once, so hoisting them cannot interact across
   casts — but the `ResolvedSpellEvent` of a *fully countered* cast is stashed on
   the admission record and emitted in pass 3, because that one IS cross-cast
   ordering: emitting it during admission would have moved it ahead of every
   resolved cast's card in `ctx.resolvedSpells`.

### Verification

* Full suite **2358/2358 green**; analyzer clean (one pre-existing unrelated
  warning in `spell_test_lab_screen.dart`).
* **Replay corpus: zero deltas, no golden regenerated.** As predicted in §9 — no
  script fires wild magic — so its value here was as a regression net for the
  admission-pass hoist, which is exactly what it caught nothing in.
* `kBattleProtocolVersion` 7, `kRulesetVersion` 3, circuits/VK untouched.

### Still open

* **§16b's generalized forced relocation** — untouched, as before.
* **Same-cast duplicate effect identities** are structurally impossible
  (12 distinct cells), and — ratified 2026-09-03 — **permanently so**: Mutable
  Leylines does not rekey `wildMagicEffectFor`. The coalescing layer's customer
  is cross-cast simultaneous duplicates and N-player semantics, which is what it
  already serves.
* **§9's balanced-affinity policy** is still open and still plugs into the
  trigger producer, not into coalescing.
