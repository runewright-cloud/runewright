# Wall Line-of-Sight, Wall HP, and Blocked-Spell Resolution — Implementation Plan

*Drafted 2026-08-05 on `feature/practice-mode`; scope expanded the same day from
walls-only to all spell-placed terrain (see §4). Decisions in §2 are Soren's and are
settled. §3 are rulings made on Soren's behalf — review before building on them. No open
questions remain.*

---

## 1. What this builds

Two related mechanics:

1. **Line of sight.** Earthen walls (`ImpassableTile`) and `Big` creatures block spell line
   of sight. A spell whose path to its declared target is blocked **resolves on the
   blocker's tile instead**.
2. **All spell-placed terrain becomes destructible.** Every `TileEffect` a Terrain
   Sculpting spell can place — lava, wall, slow, conveyor — gains a real HP pool, an
   elemental affinity, and a barrier slot. Each of the 64 (kind × affinity) effect flavors
   is classified as either *applies to the terrain* or *defaults to 1 typed damage*.

The second is what makes the first mean anything, and it exists for its own reason:
permanent, indestructible terrain gives a lava- or slow-tile spam build no counterplay.
Terrain is currently permanent (`terrain.dart`: "Tile effects placed by spells are
permanent (no turn limit); they persist until removed by another effect or match end") and
nothing removes it except another tile effect paving over it.

This exists because the behaviour is currently **broken, not merely missing**:

- Spell targeting has no LOS check at all. The only targeting restriction the engine
  enforces is the cloud adjacent-only rule (`TurnLoop._cloudBoundToAdjacent`).
- `DamageKind.traversal` *appears* to respect walls but does not: the path loop `break`s
  at an `ImpassableTile`, then the code hits the final target unconditionally anyway
  (`EffectApplicator._applyDamage`, the `case DamageKind.traversal` branch). The wall
  suppresses the incidental en-route damage — the upside of Earthen Blast — while the
  primary damage lands regardless. Strictly worse than having no check.
- Ranged summon attacks are a bare distance test (`TurnLoop._creatureTurn`:
  `creature.distanceTo(target.position) <= range`), and target acquisition
  (`_nearestEnemyEntity`) is likewise pure distance. A ranged summon will walk toward a
  wall and shoot through it.
- Terrain has **no HP and no destruction path**. Every `TileEffect` is a stateless const
  class; `tileIsIndestructible` excludes only `ChasmTile`, so the code claims the rest are
  destructible while nothing anywhere damages one.

It also finally wires `StatusEffectId.penetrating`, which was never hooked up because the
thing it is supposed to bypass was never built.

The one place LOS *does* work today and should be left alone: `EffectApplicator._spreadTiles`
does a proper BFS so a wall shadows the tiles behind it for AoE/cloud spread.

### Explicitly out of scope

- Clouds' adjacent-only targeting rule — already built and correct; do not touch.
- **The two wild-magic tiles stay exactly as they are.** `ChasmTile` blocks movement but
  **not** targeting, and is explicitly indestructible for its lifetime
  (`WILD_MAGIC_PLAN.md` A9) — do not fold it into the LOS predicate and do not give it HP.
  `IceTile` expires on its own and gets no HP either. Both already have an expiry mechanism
  in `BattleState.expiringTiles`; "destructible" is for the permanent, spell-placed four.
  `terrain.dart`'s comment on `ChasmTile` is explicit that every new `ImpassableTile`
  consumer must decide about chasms individually — the LOS predicate is such a consumer,
  and the decision is *no*.
- `turbulent`, the Firey Scrying Pool counter-charm reveal, and Watery Energy Flows'
  copy-spell — three other unwired effects found in the same audit. Separate work.
- **No `RULESET_VERSION` bump.** That constant governs the CA rules the ZK circuit
  enforces at inscription; battle-engine rules are invisible to the circuit. Bumping it
  would invalidate every inscribed spell for nothing.

---

## 2. Ratified decisions (do not re-litigate)

### 2.1 Blocked spells resolve on the blocker

If the line from caster to declared target passes through a wall or a `Big` creature, the
spell resolves on that blocker's tile. It is not rejected, not fizzled, and does not
resolve at the original target.

### 2.2 All spell-placed terrain is destructible, with an elemental affinity

Every `TileEffect` placed by Terrain Sculpting gets HP and takes damage through
`applyResistance` (`creature_spec.dart`), exactly as creatures do: same element → half
rounded up, opposite → double, otherwise normal. `_kOpposite` is Fire↔Water, Air↔Earth.

**A terrain tile's affinity is the Terrain Sculpting flavor that places it** — the
Earth-Water row's four columns map straight onto the four tile types:

| Tile | Affinity | Resists (half) | Vulnerable (double) |
|---|---|---|---|
| `FloorIsLava` | Fire | Fire | Water |
| `ImpassableTile` | Earth | Earth | Air |
| `SlowTile` | Water | Water | Fire |
| `ConveyorTile` | Air | Air | Earth |

This falls out of the existing design with no new concepts: dousing lava with water and
eroding a wall with wind already read correctly, and Earth being the *worst* element for
breaking an earthen wall is intended.

Worked example against a 4 HP wall:

| Attack | Damage dealt |
|---|---|
| Firey Blast (4) | 4 — one shot |
| Airy Blast (2) | 4 — one shot (Air opposes Earth) |
| Watery Blast (2) | 2 |
| Earthen Blast (2) | 1 — four casts |

### 2.3 Barrier can be aimed at any terrain tile

Barrier imbues terrain deliberately, not only as a consequence of LOS blocking. This is
what makes the Watery barrier's mana-regen rider live: `ImpassableTile` can never be
occupied, but lava, slow, and conveyor tiles can, so "regen to whoever stands on the tile"
has real cases — most pointedly a lava tile someone is willing to burn on.

Note the two paths that reach terrain are different and both must work:

- **Forced** — LOS blocked, spell retargets onto the wall or `Big` creature (§2.1).
- **Deliberate** — the caster simply targets a terrain tile. Any terrain, not just walls,
  since only walls and `Big` creatures block.

### 2.4 Effects that do not reasonably affect the terrain deal 1 damage instead

Per effect, not per spell. A spell landing on a wall carrying *reduce move speed* and
*mana reflection* deals 2 damage. The 1 damage is **typed** with the effect's affinity and
goes through the wheel, so an Airy non-applicable effect deals 2 to an Earth wall (§3.1).

### 2.5 Barrier imbues the terrain; every other self-targeting effect defaults to damage

Barrier (Earth-Earth) is the deliberate exception: it reinforces or imbues the wall. All
other self-targeting effects — Fuel Transmutation, Multiplier Cycles, Boost (Fire/Water
Speed Manipulation), Shape Artifact's summon flavors, Chain Interaction's Fire/Earth
flavors, Firey Scrying Pool — default to 1 damage even though they never read the target
tile.

**Known cost of this ruling, accepted:** mana is spent at commit time, so a spell carrying
self-buffs that gets blocked charges full price and delivers wall chip damage instead of
the buffs. This creates a targeting incentive — aiming at your own tile guarantees your
self-buffs land, aiming at an enemy risks them. Soren reviewed this and kept the rule: the
disruption is physically legible, and Barrier being the exception gives the mechanic a
flagship teaching case.

### 2.6 The four barrier flavors on terrain

| Flavor | On a terrain tile |
|---|---|
| Earthen (4 HP) | +4 terrain HP |
| Firey (2 HP) | +2 HP, plus the fire aura — adjacent tiles take 1 fire damage at end of turn. A burning wall. |
| Watery (2 HP) | +2 HP, plus mana regen **to whoever occupies the tile** — live on lava/slow/conveyor, inert on a wall nobody can stand in (§2.3) |
| Airy (2 HP) | +2 HP; **on collapse, knock back 1 tile every wizard and summon adjacent to the tile at that moment**. Replaces the caster's free-move rider, which made no sense on remote terrain that may collapse turns later on someone else's turn. |

### 2.7 Clouds place on the terrain tile; Terrain Sculpting paves it

A cloud hangs above terrain, so centering it on the wall tile is coherent and its
adjacent-only restriction still bites nearby entities. Terrain Sculpting replaces the wall
outright — a satisfying answer to being walled in.

---

## 3. Rulings I made on Soren's behalf — review before building

### 3.1 Incidental 1 damage is typed, not flat

Recommended and assumed throughout: the fallback damage carries the effect's affinity and
runs the wheel. Keeps element choice meaningful even in the fallback. If Soren prefers
flat untyped 1, only §2.3 and the table in §6 change.

### 3.2 Terrain Sculpting onto matching terrain repairs it to full HP

Placing a wall on a wall (or lava on lava) is otherwise a pure no-op, which reads as a bug
to a player who just spent mana. Repairing to full gives every flavor a maintenance use on
its own terrain — and gives a terrain-spam build a real cost to defend, since repairing is
a whole effect slot.

### 3.3 Terrain HP is 4 for walls, 2 for the rest

Mirrors the barrier table players already know (Earthen 4, everything else 2): Earth is the
tanky flavor. It also serves §1's stated goal directly — a spam build reaches for whichever
tile is cheapest to place, and those are exactly the flimsy ones. If Soren prefers a flat 4
across the board for predictability, only this ruling and §2.2's example table change.

### 3.4 A terrain tile's affinity is fixed at placement and never changes

Paving lava with a wall replaces the tile outright: new type, new affinity, new full HP,
and **barriers on the old tile are lost**. Terrain is not a creature that can be
re-elemented in place. This keeps the affinity lookup a pure function of the tile type
with no extra state to serialize.

### 3.5 Airy Blast's knockback is dropped, not converted

The damage half of Airy Blast applies to a wall; knockback on terrain is meaningless. Drop
the knockback silently — do **not** add a second point of fallback damage, because the
effect already did its damage thing. Same reasoning for Watery Blast: the radius-2 splash
still radiates from the wall tile, and `_spreadTiles` already shadows behind it.

### 3.6 The 1-damage fallback fires only when an effect finds no recipient

Otherwise it would double-dip. Targeting a wizard who happens to be standing on a lava tile
with a Reflections spell should link the wizard and leave the lava alone — the effect found
its recipient. The fallback applies when an effect resolves on a tile and has **nothing
valid to act on**, which covers both paths in §2.3: a blocker with no occupant, and a
deliberately-targeted bare terrain tile.

Corollary: a *damage* effect hits everything present — entities **and** terrain — the way
`_destroyIllusionTerrainIfPresent` already fires alongside entity damage today. Only the
non-damage fallback is exclusive.

Second corollary: an effect resolving on a tile with **no terrain and no entity** does
nothing at all, as today. The fallback needs something to damage.

### 3.7 Illusory terrain keeps its 1 HP, overriding the type's normal pool

`illusionTerrainTiles` copies are 1 HP by design (Earthen Illusions). The HP lookup must
check the illusion map *first*, or terrain copies silently become as tough as the real
thing and Earthen Illusions turns into a terrain-duplication engine.

### 3.8 Terrain barriers reuse `BarrierState`, keyed by element

Terrain gets a `Map<SpellAffinity, BarrierState>` exactly like `Minion.barriers`, absorbing
before terrain HP. No new damage plumbing, and the elemental wheel applies per layer.

### 3.9 Big creatures block, but do not gain terrain semantics

A `Big` creature is already a full entity with HP, statuses, and a `barriers` map, so a
spell resolving on one uses the **normal** entity resolution path. The fallback-to-1-damage
rule applies only to the narrow set in §6 that genuinely cannot touch a creature. Do not
route creature hits through the terrain code.

### 3.10 The blocker is the *first* blocking tile along the line

Walk `_hexLinePath` from caster to target and stop at the first `ImpassableTile` or `Big`
creature footprint tile. Ties cannot occur — the path is an ordered list.

---

## 4. Resolved: scope question (kept for the reasoning)

This section previously asked whether Barrier could imbue terrain other than
`ImpassableTile`. The question arose because Soren's Watery-barrier ruling — mana regen to
whoever stands *in* the wall, "only really relevant to fire walls which can be stood in at
the cost of continuous burning" — cannot be satisfied by walls alone: an `ImpassableTile`
can never be occupied, and the tile that *can* be stood in at the cost of burning is
`FloorIsLava`, which never blocks LOS.

**Answered 2026-08-05: all spell-placed terrain is destructible and imbuable** (§2.2, §2.3).
Soren's reasoning, worth preserving because it is the load-bearing argument for the larger
scope: *"it's important that all terrain be destructible with damage, otherwise too few
wizards will have answers for builds based on spamming it."* Terrain is permanent today, so
without this a lava- or slow-tile spam build has no counterplay whatsoever.

If a future change is ever tempted to narrow this back to walls-only, that is the
consequence to weigh.

---

## 5. The contract

### 5.0 The terrain model

```
// BattleState side-maps, following the expiringTiles precedent.
Map<HexCoord, int> terrainHp;                                  // current HP
Map<HexCoord, Map<SpellAffinity, BarrierState>> terrainBarriers;
```

**Not fields on `TileEffect`.** That class is deliberately immutable — expiry already lives
outside it in `expiringTiles` for exactly this reason (`terrain.dart` header). Follow that.

- Affinity is a pure function of the tile type (§2.2) — nothing to store.
- Max HP is a pure function of the tile type (§3.3) — nothing to store.
- Placement seeds `terrainHp` at max. Destruction removes the entry from **all three** maps
  (`tileEffects`, `terrainHp`, `terrainBarriers`) or a later tile on that coordinate
  inherits ghost HP and ghost barriers.
- The HP lookup checks `illusionTerrainTiles` first and returns 1 (§3.7).
- `ChasmTile` / `IceTile` never get entries (§1).

### 5.1 The LOS predicate

One shared helper, one implementation, used by every consumer. It must be deterministic —
both peers run it independently and hash the result state.

```
HexCoord? losBlockerTile(BattleState state, HexCoord from, HexCoord to, {bool penetrating = false})
```

Returns the first blocking tile along the line, or null if the line is clear.

- Walks the existing `_hexLinePath` line algorithm (strictly between endpoints, already
  deterministic integer rounding). **Lift it out of `EffectApplicator` into a shared
  location** — `lib/battle/engine/line_of_sight.dart` — since three subsystems now need it.
- Blocks on `state.tileEffects[hex] is ImpassableTile`.
- Blocks on any tile in a living `Big` creature's `occupiedTiles`, **except** the
  attacker's own footprint and the declared target's own footprint (a creature never
  blocks itself, and you can always shoot the Big creature you are aiming at).
- `ChasmTile` never blocks (§1, out of scope).
- `penetrating: true` returns null always — that is the whole of the Firey Inertia wiring.

### 5.2 Consumers

| Site | Change |
|---|---|
| `TurnLoop._applySpell` (cast resolution) | Compute the blocker; if non-null, retarget the effect to the blocker tile before dispatch. This is the authoritative path both peers run. |
| `EffectApplicator._applyDamage`, `DamageKind.traversal` | Fix the existing bug: when the loop breaks at a wall, the final-target hit must **not** run. The retarget in `_applySpell` makes the wall the target, so the trailing block should hit `ctx.targetTile` only when the path was clear. |
| `TurnLoop._creatureTurn` | Gate the ranged-attack branch on a clear line. |
| `TurnLoop._nearestEnemyEntity` | Prefer targets with a clear line; fall back to blocked ones so a creature still advances rather than freezing. |
| `BattleScreen._maxCastRange` (UI mirror) | Must agree with the engine — its own comment notes that disagreement either hides legal casts or offers casts the engine then fizzles. Show the player where the spell will actually land. |
| `EffectApplicator._applyDamage`, every `DamageKind` | Damage at a tile now hits terrain as well as entities (§3.6), through `applyResistance` with the tile's affinity. |
| `EffectApplicator._applyTileModification` | Matching type repairs to full (§3.2); differing type replaces outright, dropping the old barriers (§3.4). |

`penetrating` is read from the caster's status at the `_applySpell` site and threaded into
the predicate. Its `penetrationDamage` modifier — already stored, never read — feeds the
en-route damage tick the design promises ("1 damage to anything in hexes en route").

---

## 6. Per-effect resolution table

Legend: **A** = applies to the terrain · **D** = falls back to 1 typed damage (only when
the effect finds no other recipient — §3.6).

Applies identically whether the tile was reached by LOS retargeting or targeted
deliberately, and to all four terrain types.

| Kind (pair) | Fire | Earth | Water | Air | Notes |
|---|:--:|:--:|:--:|:--:|---|
| Damage (F-F) | A | A | A | A | Air drops knockback (§3.5); Water still splashes from the tile |
| Barrier (E-E) | A | A | A | A | §2.6 |
| Reflections (W-W) | D | D | D | D | Needs an enemy *avatar* — also D on creatures |
| Speed Manipulation (A-A) | D | D | D | D | Terrain has no movement. On a creature: Earth/Air **A**, Fire/Water D (self) |
| Status Effect Interaction (F-E) | D | D | D | D | Terrain carries no statuses. On a creature: all **A** — minions have `activeStatusEffects` |
| Chain Interaction (F-W) | D | D | D | D | Also D on creatures — minions have no chain |
| Spell Interaction (F-A) | D | D | D | D | Also D on creatures — minions cast nothing |
| Fuel Transmutation (E-F) | D | D | D | D | Self-targeting; §2.5 |
| Tile Modification (E-W) | A | A | A | A | Matching type repairs to full, differing type paves (§3.2, §3.4) |
| Range Modification (E-A) | D | D | D | D | On a creature: Earth/Air **A**; Fire (penetrating) / Water (turbulent) D |
| Clouds (W-F) | A | A | A | A | §2.7 |
| Artifacts Interaction (W-E) | D | D | D | D | Also D on creatures — minions hold no artifacts |
| Illusions (W-A) | D | **A** | D | **A** | Earth copies the terrain to neighbors at 1 HP; Air converts it to a 1 HP illusion. On a creature: Fire **A** (copy the minion), Air **A**, Earth/Water D |
| Multiplier Cycles (A-F) | D | D | D | D | Self-targeting |
| Haymaker Interaction (A-E) | D | D | D | D | Also D on creatures — minions don't haymaker |
| Divination (A-W) | D | D | D | D | Also D on creatures — needs an enemy avatar |

18 of 64 flavors apply to terrain; the rest fall back. The creature column is far wider,
as expected — a `Big` creature is a real entity.

Two flavors need no new code to work on terrain once retargeting lands, because they
already read the target tile's terrain: Earthen Illusions (`_applyIllusionTerrainCopy`
reads `tileEffects[targetTile]`) and Airy Illusions (`convertToIllusion`, which needs only
the `illusionTerrainTiles` marking path that already exists at 1 HP).

---

## 7. Determinism and the state hash

Both peers step this independently and exchange a signed hash of
`BattleState.toCanonicalBytes()`. **Every new field must be serialized there or the two
clients can agree on a hash while holding different terrain state.**

- New: `terrainHp` and `terrainBarriers` (§5.0). Follow the `expiringTiles` precedent — a
  `BattleState` side-map sorted by (q, r) before writing, **not** a field on `TileEffect`
  (that class is deliberately immutable; expiry already lives outside it for this reason).
- `terrainBarriers` is a nested map: sort the outer by (q, r) and the inner by
  `SpellAffinity.index`. An unsorted inner map is the easy way to produce a hash mismatch
  that only shows up on a two-device run.
- `_tileEffectIndex` tags are wire-critical: **never renumber an existing tag**, append
  only. This change adds no variants, so nothing moves.
- The LOS predicate must not consult anything non-deterministic (no RNG, no wall-clock,
  no iteration over an unsorted `Map`).
- Terrain destruction removes the tile from `state.tileEffects`; make sure that also clears
  both side-map entries, or later terrain on the same tile inherits ghosts (§5.0).
- Terrain HP changes mid-turn, so it lands in the hash at the exchange point — the same
  hazard `WILD_MAGIC_PLAN.md` A6 called out for pending latching state. Verify the
  destruction ordering is identical on both peers, not merely eventually consistent.

---

## 8. Build order

Each step is independently testable and leaves the tree green.

1. **`line_of_sight.dart`** — lift `_hexLinePath`, add `losBlockerTile`. Pure function,
   unit-testable with no battle state. No behaviour change yet.
2. **Terrain HP** — the §5.0 side-maps, `toCanonicalBytes` coverage, the affinity/max-HP
   lookups, damage routed through `applyResistance`, and the destruction path that clears
   all three maps. **Ships as its own step and is independently playable**: terrain becomes
   destructible by ordinary damage before any LOS work exists. This is the half that
   answers terrain spam (§1), so if the plan stalls, stalling here still leaves the game
   better than it started.
3. **Retargeting in `_applySpell`** — blocked spells resolve on the blocker. At this point
   the traversal-damage bug (§5.2) gets fixed as part of the same change.
4. **The per-effect table** — the applies/fallback dispatch from §6.
5. **Barrier-on-terrain** — §2.6.
6. **Creature blocking** — `_creatureTurn` and `_nearestEnemyEntity`.
7. **`penetrating`** — the exemption flag plus the en-route damage tick.
8. **UI** — `_maxCastRange` mirror, terrain HP/damage feedback on the battlefield, and a
   visual for where a blocked spell will land.

---

## 9. Tests

The existing test for `penetrating` (`test/battle/engine/target_tile_effects_test.dart`)
asserts only that the status chip lands on the avatar, never that it changes an outcome.
That is exactly why this shipped broken. **Every test below must assert a behavioural
difference, not a status or field value.**

- `losBlockerTile`: clear line, wall mid-line, wall on the target tile itself (targetable —
  it is the blocker), wall behind the target (irrelevant), Big creature mid-line, Big
  creature *as* the target, caster's own Big summon adjacent, chasm mid-line (does **not**
  block).
- Terrain damage: each of the four affinities against a 4 HP wall reproducing §2.2's table
  exactly. Earthen Blast four times to destroy.
- The resistance wheel on **every** terrain type, not just walls — at minimum Water-onto-
  lava (double) and Fire-onto-lava (half), which is the pairing most likely to be
  transcribed backwards.
- The traversal-damage regression: an Earthen Blast at a target behind a wall damages the
  wall and **not** the target. This is the bug fix — it needs a test that fails today.
- Fallback accounting: Soren's worked example — a spell carrying reduce-move-speed and
  mana-reflection deals exactly 2 damage to a wall (or 2/4 typed, per §3.1).
- Fallback exclusivity (§3.6): a Reflections spell aimed at a wizard standing **on** a lava
  tile links the wizard and leaves the lava at full HP. The double-dip is the likely bug.
- Illusory terrain stays 1 HP (§3.7): an Earthen Illusions copy of a wall dies to a single
  point of damage, not four.
- Terrain replacement drops old barriers (§3.4): barrier a wall, pave it with lava, confirm
  the lava has its own full HP and no inherited barrier.
- Barrier-on-terrain: each flavor; Airy collapse knocks back adjacent entities; Firey aura
  ticks on adjacent tiles; Watery regen pays a wizard standing on a barriered lava tile
  (the case that motivated the whole scope expansion — §4).
- Determinism: two `BattleState`s that diverge only in terrain HP produce different
  `toCanonicalBytes()`, and likewise for a barrier on one tile. This is the test that
  catches a missed serialization field.
- Ranged summon: cannot shoot through a wall; still advances rather than freezing.
- `penetrating`: the same blocked cast that lands on the wall without it reaches the real
  target with it, **and** deals `penetrationDamage` to entities en route.

---

## 10. Doc updates

- `docs/runewright_design_v3_0.md` §Effect Table — the Earth-Water row already promises
  "blocks spells from passing through for line of sight"; add the resolves-on-the-blocker
  rule and the terrain HP model near it.
- `lib/battle/models/terrain.dart` — two comments become wrong or aspirational:
  the file header says tile effects "are permanent (no turn limit); they persist until
  removed by another effect or match end", which this change ends; and `ImpassableTile`'s
  comment already claims it "blocks spell targeting through this tile (line-of-sight
  check)", which was aspirational and becomes true. Fix the first, keep the second, and add
  the HP/affinity model.
- `lib/battle/models/status_effect_ids.dart` — `penetrating` gains a real consumer; note
  where.
- `docs/M4_findings.md` (or a new milestone findings doc) — record the traversal-damage
  bug and how it hid: a `break` that stopped the incidental damage while the primary hit
  ran on regardless, with a test that only ever checked the status chip.
