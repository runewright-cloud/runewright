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
- no meaningful formulas means no Wild Magic eligibility.

Void Wild Magic remains absent.

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
