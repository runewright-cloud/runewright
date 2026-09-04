# Runewright — Wild Magic Plan vNext

**Status:** Revised design plan  
**Supersedes:** the Wild Magic seed/keying portions of `docs/WILD_MAGIC_PLAN.md`, including the 2026-08-10 amendment  
**Companion:** `LEYLINE_SEED_PLAN.md`

---

## 1. Design purpose

Wild Magic is a second, parallel spell-effect system intended to make Runewright's magical world partially discoverable rather than completely engineered.

Wild Magic should create:

- local magical traditions;
- valuable personal discoveries;
- asymmetric knowledge between players;
- strange interactions worth telling stories about;
- incentives to experiment with otherwise-unusual runes;
- shared battlefield events that reward adaptation rather than simple targeting.

Wild Magic is **deterministic**, not per-cast random.

Given the same:

- wizard identity,
- certified spell trajectory,
- certified mana cost,
- leyline configuration,

the spell always has the same Wild Magic.

Randomness is used only to resolve an already-triggered effect's internal details, such as teleport destinations or a selected hand position.

---

## 2. Core fiction

Ordinary recipe magic belongs primarily to the rune.

Wild Magic emerges from the interaction of:

> **wizard × spell behavior × leyline**

This is a game rule rather than merely an anti-cheating device.

Consequences:

- the same borrowed spell may possess different Wild Magic for different wizards;
- changing leylines may change the spell's Wild Magic;
- a spell that appears ordinary for one wizard may become remarkable for another;
- discoveries are harder to reduce to universally published spell tables.

---

## 3. Privacy decision: Wild Magic must not expose a grid fingerprint

Wild Magic must not hash the private grid or a public deterministic grid commitment.

Although the complete grid space is enormous, practical human-designed runes occupy a much smaller structured subset of sparse lines, dots, symmetry, and recognizable constructions.

A public deterministic grid commitment therefore risks becoming an offline dictionary/rainbow-table oracle:

1. an attacker observes a spell commitment;
2. the attacker generates plausible rune grids offline;
3. the attacker computes their commitments;
4. a matching commitment reveals the private rune.

Wild Magic should not require exposing or retaining such a fingerprint.

Once all other dependencies on the grid commitment are removed, the commitment should be deleted from the circuit/public spell identity rather than retained solely for Wild Magic.

---

## 4. Proof bytes remain unsuitable

UltraHonk proof bytes must not determine Wild Magic.

ZK UltraHonk deliberately uses fresh masking randomness. Re-proving the same witness therefore produces different valid proofs.

Hashing proof bytes would allow a player to repeatedly generate proofs for an already-good rune until the desired Wild Magic appeared.

Attempts to make UltraHonk's prover randomness deterministic were investigated and rejected.

Reasons:

- doing so gives up UltraHonk's existing statistical-ZK guarantee unless a new proof is established;
- deterministic proofs create stable private-witness fingerprints;
- most importantly, ordinary verification cannot prove that a malicious prover used prescribed deterministic randomness.

A modified client could simply choose fresh prover randomness and reroll indefinitely.

Wild Magic must therefore depend on **proof-certified game semantics**, not proof serialization.

---

## 5. Canonical Wild Magic key

For Wild Magic version 2, construct a canonical preimage from:

- domain tag: `Runewright/WildMagic/v2`;
- ruleset / Wild Magic version;
- current caster's public identity key;
- certified elemental trajectory;
- certified mana cost;
- canonical leyline configuration hash.

Conceptually:

`WildHash = SHA256(domain || ruleset || casterPubkey || certifiedTrajectory || certifiedManaCost || leylineConfigHash)`

Serialization must be canonical, length-delimited where necessary, and consensus-critical.

Do **not** include:

- proof bytes;
- private grid cells;
- grid commitment;
- supreme flags as an independent input;
- border activations as an independent input;
- segment count as an independent input;
- dot count as an independent input;
- authored/cached spell metadata;
- device-specific information;
- timestamps;
- per-cast entropy.

If any lower-level certified value contributes to the canonical mana-cost calculation, it may matter **through the certified mana cost**, but it should not independently affect the Wild Magic hash.

### Equivalence rule

Two different secret grids that produce the same:

- certified trajectory, and
- certified mana cost

are intentionally Wild-Magic-equivalent for the same caster and leyline.

This is desirable.

Wild Magic keys off the spell's certified behavior and cost, not a fingerprint of how the player drew the rune.

---

## 6. Why caster keying is acceptable

Changing identity can reroll Wild Magic cheaply, but identity grinding is **book-wide**, not independently available per spell.

If a player generates a new identity to optimize spell A:

- spell A rerolls;
- spell B rerolls;
- spell C rerolls;
- every other wizard-keyed magical relationship rerolls.

Optimizing several desired Wild Magic outcomes therefore becomes a multi-objective search.

A player's persistent identity may also acquire social value through:

- sightings;
- trades;
- spell loans;
- apprenticeships;
- battle history;
- reputation;
- community recognition.

Abandoning an established identity therefore need not be free socially even if key generation itself is computationally cheap.

This does not make identity grinding impossible. It makes it an acceptable property of the world rather than a cheap independent optimization knob attached to every rune.

---

## 7. Eligibility

Wild Magic eligibility is based only on **completed, meaningful incantation formulas**.

Under ordinary magic:

- formulas use the standard three-element grammar.

Under numbered/rekeyed leylines:

- formulas use that leyline's formula length and codebook;
- formula-sized chunks that decode to noise are not completed meaningful formulas and do not contribute to Wild Magic affinity.

Among meaningful completed formulas:

- tally formula affinities;
- the most frequent affinity is eligible;
- ties make every tied affinity eligible;
- ~~no meaningful formulas means no Wild Magic eligibility~~ — **amended
  2026-09-04, see below.** Under a Mutable leyline a spell with no meaningful
  formula can still be eligible, through its trailing incomplete group. Under an
  ordinary leyline this bullet stands unchanged.

Void Wild Magic remains absent.

> ### ⚠️ Superseding amendment — 2026-09-04, partial-formula affinity (engine 14)
>
> **An incomplete trailing Mutable group has no formula meaning, effect,
> `effectCount`, or suppression slot, but its first element contributes affinity
> for Wild Magic eligibility. This exception does not apply to ordinary leylines
> and does not participate in chain purity.**
>
> The statements above remain true as written for *formulas*: an incomplete
> trailing group still does not form one, is never interpreted, and is never
> padded or looked up. What changed is that eligibility is no longer read off
> the completed-formula list alone. A formula's **start** establishes its
> affinity; only its **completion** establishes its meaning.
>
> | group | affinity | meaning | effect | effectCount | suppression slot | chain purity |
> |---|---|---|---|---|---|---|
> | complete + meaningful | ✅ | codebook | ✅ | +1 | consumes | ✅ |
> | complete + **Noise** | ❌ | inert | ❌ | +1 | consumes | ❌ |
> | **incomplete residual** | ✅ | none | ❌ | +0 | does not consume | ❌ |
>
> Scope, ratified with the rule:
>
> * **R-10 — chain purity is NOT affected.** `pureAffinityOf`, the chain
>   discount, certified cost and chain advancement stay on completed
>   *meaningful* formulas. A residual-only Fire spell may be Wild-Magic-eligible
>   for Fire without establishing or advancing a Fire chain; `completed Fire +
>   Water residual` stays **pure Fire** for chain pricing. No certified price
>   moves.
> * **R-11 — ordinary leylines are NOT affected.**
>   `IncantationLexicon.ordinary.residualBearsAffinity` is `false`. Ordinary
>   1–2-element residuals lend nothing, exactly as before. This is a
>   Mutable-grammar rule, not a retroactive change to ordinary magic.
>
> Canonical implementation: `IncantationLexicon.eligibleAffinitiesOf`. See
> `docs/MUTABLE_LEYLINES_IMPLEMENTATION_AUDIT.md` §7.5.

---

## 8. Trigger patterns

The current trigger families remain provisionally unchanged.

### Row 1

Longest maximal run of `0`, minimum length 3.

Base trigger:

`000`

Bracket steps:

`runLength - 3`

Approximate base frequency remains around 1.4%.

### Row 2

Longest maximal run of `1`, minimum length 3.

Base trigger:

`111`

Bracket steps:

`runLength - 3`

Approximate base frequency remains around 1.4%.

### Row 3

Longest maximal ascending hexadecimal run beginning at zero, minimum:

`0123`

Row 3 remains deliberately rare, around 1-in-1,150 per eligible hash.

Trigger rarity should **not automatically scale downward in N-player games**.

More players naturally make Wild Magic more likely to appear during a battle, which is desirable:

- duels remain comparatively grounded;
- large wizard battles more reliably contain one or two magical spectacles;
- Row 3 remains genuinely exceptional.

---

## 9. Balanced-affinity specialist

Current behavior allows a tied multi-affinity spell to fire every eligible elemental effect from a triggered row.

This remains a **playtest decision**, not yet frozen for vNext.

Two candidate semantics:

### A. Shared trigger, multiple effects

One row hit activates every tied elemental column.

Advantages:

- spectacular;
- strongly rewards perfect balance;
- preserves existing behavior.

Risk:

- in larger battles, one trigger can seize control of the match with 2–4 simultaneous global effects.

### B. Independent elemental trigger domains

Each eligible affinity receives a separate domain-separated trigger roll derived from the same Wild Hash.

Advantages:

- balanced spells have greater Wild Magic probability;
- usually produce one event rather than an automatic four-effect bomb;
- scales better to N-player battles.

Until playtesting resolves this, implementation should avoid architecture that makes either interpretation difficult.

---

## 10. Global symmetry

Wild Magic remains global and double-edged.

The caster is never exempt merely because their spell caused the event.

The general principle is:

> **Wild Magic may violently change the tactical problem, but should rarely remove the players' ability to make meaningful choices about that problem.**

Skill comes from:

- recognizing what your own spell may cause;
- positioning;
- timing;
- preparation;
- adapting faster than opponents.

Wild Magic is not an extra targeted spell effect.

---

## 11. N-player world-event semantics

Wild Magic must be represented as **world events**, not N separate caster-owned effects.

### Common snapshot

For effects involving several players/entities:

1. capture the relevant pre-effect world state;
2. derive all selections/destinations from that common snapshot;
3. use deterministic shared entropy;
4. apply the resulting world transition canonically.

Do not allow iteration order, device order, or packet-arrival order to affect the outcome.

### Identical effects

If identical Wild Magic effects trigger in the same resolution phase:

- coalesce them into one world event;
- use the greatest `bracketSteps`;
- do not independently stack identical global transitions.

Example:

Two simultaneous Zephyrs do not teleport everyone twice.

### Different effects

Different effects all resolve in canonical row → element order unless later playtesting establishes a better universal ordering.

### Ratified and implemented (Slice 7, engine v12)

**The collection boundary is ONE simultaneous resolution batch** — a Quick,
Normal or Sluggish group — not a whole turn (R1). Existing temporally distinct
groups stay distinct: they merely share a turn number, and merging them would
let a Sluggish caster's Chasm open before a Quick caster's fireball landed.

**Within one batch the order is now:**

```
all admission  →  all coalesced wild magic  →  all ordinary formula effects
```

This is the **wider phase reading (R3)**, and it **supersedes design v4.0
§1250's per-spell interleaving** ("within a single player's spell: wild magic
first, then formula effects"). That reading cannot survive N-player play — it
makes the outcome a function of which caster resolution happened to reach
first. Caster B's Zephyr now moves people before caster A's fireball lands.
Formula effects keep their existing canonical order after the wild-magic phase.

**Liveness is decided at admission (R2).** Once a cast has passed admission, its
caster being killed later in the same batch cancels neither its wild magic nor
its ordinary spell resolution — the spell was cast, and whether the caster lived
to see it land is the one question whose answer would depend on resolution
order. A cast REJECTED during admission (mana fizzle, cloud violation,
out-of-range target, full counter) contributes neither. A caster killed by an
*earlier batch* is never admitted at all.

**Chasm is not an exception (R4).** Multiple Chasm triggers in one batch
coalesce into one Chasm event at `max(contributing brackets)`, which rolls
exactly ONE axis from the coalesced event's RNG and resolves once. Chasms in
separate batches remain separate events.

**Burning Hot coalesces by maximum, WITHIN A BATCH (R5).** Two Burning Hot
triggers in one simultaneous batch produce one event at the strongest bracket;
they do not add. Bracket scaling is the one power axis, so two casters who both
roll it have not between them rolled a longer run than the stronger of them did.

This is enforced entirely by `coalesceWildMagicTriggers`, which hands the
applicator one event and therefore arms the state exactly once.
`WildMagicState.armSpellDamageBonus` is deliberately left **additive**: it is a
persistent-state primitive and must not be the thing that decides which events
were simultaneous. A Quick Burning Hot and a Normal one on the same turn are two
genuinely separate world events under R1, so they stack on the round they both
arm, exactly as they did before Slice 7. A *stale* arming from a previous round
is still replaced, not combined — Slice 7 did not revisit that.

**Coalescing is architecture, not a special case.** The fixed 3x4 table has 12
distinct cells, so two triggers of ONE cast can never share an effect kind, and
every duplicate is cross-cast within a batch.

*(Corrected 2026-09-03.)* This paragraph previously said that property "stops
being true under Mutable Leylines, which can remap (row, element) to effect".
**It does not. `wildMagicEffectFor` is NOT rekeyed by any leyline** — ratified
with the Mutable Leylines audit. A mutable leyline rekeys Wild Magic exactly the
way LEYLINE_SEED_PLAN.md SS10 describes, through `leylineConfigHash` in the v2
semantic hash, which is already implemented. So the 12-distinct-cells property
is **permanent**, and same-cast duplicate effect kinds remain structurally
impossible.

Coalescing is still required, and for the reason it was built: **cross-cast
simultaneous duplicates and N-player world-event semantics**. Trigger
*production* stays separate from event *coalescing* (`wild_magic_phase.dart`)
on its own merits — that is where the unresolved balanced-affinity policy (SS9)
plugs in.

### The coalesced-event RNG

A coalesced event cannot be keyed on a caster (it may have several contributors,
or after a Phoenix save none) nor on the per-turn wild-magic nonce, which is
incremented in **encounter order** — either would let the order triggers were
met in change what the world does. The pinned preimage is:

```
seed = SHA-256( entropy[32]
              ‖ matchId[N]?
              ‖ uint32be(turnNumber)
              ‖ uint8(canonicalResolutionBatchCode)
              ‖ uint8(0x0C)                       // wild-magic EVENT domain
              ‖ uint8(canonicalEffectCode)
              ‖ uint8(effectiveBracketSteps) )
```

- `canonicalResolutionBatchCode` is `kResolutionBatchCode`
  (quick 0, normal 1, sluggish 2) — a **pinned map, never `ResolutionGroup.index`**.
- `canonicalEffectCode` is `kWildMagicEffectCode` (0..11, row-major) — likewise
  pinned, and it is also the phase's **resolution order**.
- `effectiveBracketSteps` is range-checked against `uint8`, never masked.
- No playerId, no nonce, no contributor list or hash, no proof bytes, no private
  data. Tag `0x09` survives as the per-player wild-magic tag used by the
  forced-cast drain and the bookmark burn.

Properties: the same semantic event in the same batch always gives the same RNG;
contributor encounter order cannot matter; an equal duplicate trigger does not
reroll the event; different batches of one turn never share a stream; and a
change in the strongest bracket *does* change the stream, because a stronger
event is a different event.

### Phase-scope bounds fixed as a consequence

Two bounds were ratified "per living wizard" and enforced only per *firing*.
Both are fixed by the boundary rather than by a special case:

- **Spontaneous Combustion** — `queueForcedCast` appends one request per call,
  so two triggers queued two forced casts per living wizard. One coalesced
  event queues one request; the drain runs once per batch, after every event.
- **Mountains** — `selectMountainTiles` re-ran the whole capped selection per
  firing, so two triggers could raise six walls around a wizard. It now runs
  once per batch.

---

## 12. Persistent effects begin next round

Immediate battlefield transformations may affect later actions in the current resolution phase.

Examples:

- Zephyr;
- Chasm;
- Glacier;
- Mana Flood.

However, persistent rules-changing effects should generally arm for the **next round**, so initiative/resolution position does not arbitrarily determine which players receive more turns under the new rules.

This includes:

- Burning Hot;
- Statuesque;
- Rippling Reflections;
- Scattered Gusts;
- similar future persistent Wild Magic.

---

## 13. Revised effect table

### Row 1 — `000`

#### Fire — Burning Hot

All spell effects during the next round deal +1 fire damage per damage-producing effect, +1 per bracket step.

**Status:** keep.

#### Earth — Mountains

For each living wizard, up to **3 eligible adjacent tiles** erupt into temporary Earth walls.

Eligible tiles must be:

- in bounds;
- unoccupied;
- not already carrying protected terrain.

Selection is deterministic from shared entropy.

Duration:

2 rounds + bracket scaling as finalized by implementation.

This replaces the current six-walls-around-every-wizard interpretation, which risks imprisoning players and consuming excessive board area in larger matches.

#### Water — Mana Flood

All living wizards immediately refill to maximum mana.

**Status:** keep.

#### Air — Zephyr

All living wizards and minions are simultaneously redistributed to legal random destinations.

Requirements:

- deterministic entity ordering;
- destination selection from a common pre-effect snapshot;
- collision-free assignment;
- no sequential teleport advantage.

**Status:** keep.

---

### Row 2 — `111`

#### Fire — Spontaneous Combustion

Each living wizard is forced to cast **exactly one** random spell from their hand at a deterministic random legal target.

Bracket steps do not increase the number of forced casts per wizard.

The effect uses a reusable multi-party forced-reveal primitive:

1. snapshot all affected hands/public positions;
2. determine every forced selection and target;
3. gather all required reveals/proofs;
4. only after selections are fixed, resolve forced casts in canonical resolution order.

Forced casts remain recursion-exempt:

- no Wild Magic;
- no Rippling Reflections;
- no Scattered Gusts;
- no chain mutation;
- no hand consumption unless explicitly changed later.

This primitive must be hardware-tested before becoming foundational to N-player mesh resolution.

#### Earth — Chasm

A deterministic random hex axis through the battlefield opens into a temporary impassable chasm.

Chasm:

- blocks movement;
- does not block targeting;
- is ignored by flying;
- is otherwise indestructible for its duration.

**Occupied-tile behavior — ratified and implemented (Slice 6, engine v11).**

The chasm is created regardless of who is standing there. Any living entity whose
position the new chasm *invalidates* is immediately and involuntarily displaced to
the nearest legal solid position; ties among equally-near destinations are broken
from the trigger's own RNG. This is emergency displacement caused by terrain
collapse, not voluntary movement: it ignores pathfinding, movement allowance, LOS
and route connectivity, does not break Statuesque, does not consume Scattered
Gusts, and does not spend movement.

*Invalidates* is load-bearing, and it is what preserves "is ignored by flying"
above: a chasm does not invalidate a flyer's position, so a flying wizard
(Updraft) or a flying creature is not displaced at all. Grounded bodies only.

A struck creature relocates as a **whole footprint**, never a single tile. All
evacuations are planned from one common pre-effect snapshot, and destinations are
reserved as they are assigned, so a later evacuee may legitimately be pushed to a
farther distance tier. Canonical processing order is avatars by `playerId`, then
creatures by id.

See `WildMagicApplicator.planChasmEvacuation`.

#### Water — Glacier

Eligible terrain-free tiles become temporary ice.

Entering ice continues movement in the same direction until:

- blocked;
- leaving ice;
- reaching the board edge.

**Status:** keep.

#### Air — Updraft

All living wizards gain flying temporarily.

**Status:** keep.

---

### Row 3 — `0123`

#### Fire — Phoenix

All living wizards gain one Phoenix save:

> the next lethal event instead leaves/returns the wizard at 1 HP.

Phoenix should not persist indefinitely.

Default playtest duration:

**2 rounds**, after which unused saves expire.

#### Earth — Statuesque

At the beginning of each affected wizard's turn:

- restore full health;
- restore full mana.

The enchantment ends when that wizard takes **any voluntary battle action other than Pass**, including:

- movement;
- spellcasting;
- melee;
- artifact activation;
- other future voluntary action categories.

The effect also has a bounded duration.

Default playtest duration:

**2 rounds.**

#### Water — Rippling Reflections

During the affected round, ordinary spell resolutions begin at:

- 50% fizzle;
- 50% double resolution.

After each outcome:

- fizzle shifts probability 10 percentage points toward doubling;
- double shifts probability 10 percentage points toward fizzling;
- clamp to legal bounds.

The process remains mean-reverting around 50%.

Rippling Reflections no longer permanently modifies the remainder of the battle.

Default duration:

**one full round beginning after the triggering round.**

Doubled spells repeat normal recipe/formula effects only and do not recursively duplicate Wild Magic.

#### Air — Scattered Gusts

Each affected wizard's **next voluntary spell cast** scatters their bookmarks once, after which that wizard is no longer affected.

This replaces the permanent "re-deal after every cast for the rest of the match" interpretation.

Free/forced casts remain exempt.

---

## 14. Leyline agreement

The complete leyline configuration is match consensus state.

For ordinary community play:

1. host proposes leyline configuration;
2. every player sees it;
3. every player accepts it;
4. configuration becomes immutable;
5. only then are chapters/loadouts locked.

This preserves intentional home-territory knowledge while preventing the host from changing the leyline after seeing opponents' locked battle configurations.

Neutral/tournament modes may derive or publish leylines under separate rules defined in `LEYLINE_SEED_PLAN.md`.

---

## 15. Information model

The caster may know in advance what Wild Magic their own spell possesses under the current leyline.

Opponents do not learn it merely from seeing the spell card or commitment exchange.

Wild Magic becomes public when it resolves.

This preserves the useful asymmetry:

- remembering your own fixed effects is not busywork;
- opponents still face genuine surprise;
- scouting and sightings may acquire strategic value.

---

## 16. Versioning

Wild Magic hashing is consensus-critical.

Any change to:

- preimage fields;
- field ordering;
- serialization;
- normalization;
- trigger scanning;
- eligibility semantics;
- leyline configuration encoding;

requires a Wild Magic version change and, where appropriate, an engine/protocol compatibility change.

Slice 7 changed none of those — it changed *when* triggers are resolved and
*how* the applicator is seeded, not what a spell hashes to. So the Wild Magic
version stays **2**, `kRulesetVersion` stays **3** and `kBattleProtocolVersion`
stays **7**; only `kBattleEngineVersion` moves, **11 -> 12**.

Player-discovered Wild Magic combinations may become culturally significant. Accidental rerolling through serialization drift is unacceptable.

---

## 16b. Follow-up debt — generalized forced relocation / position validity

Two related gaps were surfaced by Slice 6 and deliberately **not** fixed there.
Both belong to one future pass — a general "is this body's position still legal,
and what do we do when it isn't" mechanism — rather than to any single effect.

**(a) Flying expiry can leave a body on terrain it may not stand on.**
Flying (Updraft, and `SummonAbility.flying`) lets a body come to rest on an
`ImpassableTile` or a `ChasmTile`. When the status later expires, nothing
re-examines the position: the body is simply standing somewhere a grounded body
could never have reached. This **predates Slice 6** — it is reachable today via
ordinary Updraft movement onto a wall — and Slice 6 neither introduces nor widens
it, since a flyer over a chasm was already legal and stays put by design.

The shape of the fix is not "special-case Updraft expiry". It is a position-validity
check that runs whenever the *reason* a position was legal goes away, with one
shared forced-relocation primitive behind it. Chasm evacuation is the first real
instance of that primitive; a second instance is what would justify extracting it.

**(b) Chasm evacuation with no legal destination.**
`ChasmEvacuation.stranded` records bodies for which the board offered nowhere legal
at any distance. The current fallback is deliberately the pre-slice status quo —
displacement fails, the body stays where it is, the id is recorded — because every
alternative (killing it, deleting the chasm, an off-board or illegal destination)
would be inventing a rule. It is constructible but not reachable in ordinary play:
every one of the 3r(r+1)+1-(2r+1) tiles left standing would have to be a wall, a
pre-existing chasm, or a body that is not itself leaving.

This is an **exceptional fallback, not intended Chasm behavior**, and choosing real
semantics for it is part of the same generalized pass — the answer should be the
same one (a) gets, not a Chasm-specific rule.

---

## 17. Final invariant

Ordinary recipe magic answers:

> **What has this rune learned to do?**

Wild Magic answers:

> **What happens when this wizard channels this spell through this leyline?**

That relationship should remain deterministic enough to discover, secret enough to matter, and unstable across communities enough to generate folklore.
