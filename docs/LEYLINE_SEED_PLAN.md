# Runewright — Leyline Seed and Mutable Magic Plan

**Status:** New design plan  
**Purpose:** Extend community leylines beyond Wild Magic into an optional ruleset that can rekey incantations, summons, and Aetherial Armor.

---

## 1. Two kinds of leyline play

Runewright supports two related but deliberately different magical environments.

### Ordinary Leyline

Example:

`rivendell`

The ordinary magical grammar remains unchanged.

The leyline affects:

- Wild Magic;
- any future explicitly leyline-local systems.

Existing spellcraft remains mechanically meaningful.

This is the normal persistent-world mode where players accumulate discoveries, trade spells, develop local traditions, and build long-lived spellbooks.

### Numbered / Mutable Leyline

Example fiction:

`rivendell 5`

The leyline does more than alter Wild Magic.

It changes the **grammar by which elemental trajectories are interpreted**.

The number specifies formula length.

The leyline deterministically rekeys:

- incantation effect formulas;
- summon ability patterns;
- Aetherial Armor ability patterns;
- Wild Magic.

Some syntactically complete formulas deliberately decode to **nothing**.

This mode is intended primarily for:

- sealed-start tournaments;
- workshops;
- experimental events;
- temporary challenge formats;
- communities that deliberately want to invalidate accumulated recipe knowledge.

---

## 2. Internal representation

Do not parse gameplay configuration from a human-readable seed string.

The UI may display:

> `Rivendell 5`

but consensus state should store separate fields such as:

- `communitySeed = "rivendell"`
- `mutableMagic = true`
- `formulaLength = 5`
- `lexiconVersion = 1`

Ordinary `rivendell` is represented explicitly as the standard grammar rather than inferred by the absence/presence of digits.

This avoids ambiguity with legitimate seed names containing numbers and provides room for future configuration.

---

## 3. Formula grammar

### Ordinary grammar

Current rules remain unchanged:

`Affinity | EffectKey1 | EffectKey2`

Formula length = 3.

There are four possible elements for each effect-key position:

`4² = 16`

Therefore the sixteen possible tails map perfectly onto Runewright's sixteen base effect types.

There is no noise.

### Mutable grammar

For formula length `L`:

- first element remains the formula's **affinity**;
- the remaining `L - 1` elements form the **effect key**.

Number of possible effect-key tails:

`4^(L - 1)`

Examples:

| Formula length | Tail combinations |
|---:|---:|
| 3 | 16 |
| 4 | 64 |
| 5 | 256 |
| 6 | 1,024 |

The first element retaining affinity is a protected invariant.

The leyline changes magical grammar, not the fundamental meaning of elemental affinity.

---

## 4. Rekeyed incantation codebook

For a Mutable Leyline, derive a deterministic codebook from:

- domain tag;
- lexicon version;
- normalized community seed;
- formula length.

Domain:

`Runewright/Leyline/v1/Incantation`

Generate the complete tail space in canonical lexicographic elemental order.

Use deterministic hash expansion / PRNG to construct a canonical permutation.

The codebook then assigns:

- a fixed proportion of tails to the sixteen base effects;
- the remaining tails to **noise / no effect**.

The mapping is seed-specific.

Therefore:

`fire-fire-fire-fire`

may mean Damage under one leyline, Barrier under another, and nothing under a third.

---

## 5. Noise density

Do **not** allow the meaningful-formula rate to fall exponentially merely because formula length increases.

The naive scheme—one key per effect—would produce:

| Length | Meaningful |
|---:|---:|
| 4 | 25% |
| 5 | 6.25% |
| 6 | 1.56% |

This would become frustrating rapidly.

### Initial playtest rule

For numbered leylines, begin with approximately:

> **50% meaningful / 50% noise**

with meaningful entries distributed evenly across all sixteen effects.

This yields:

| Length | Total tails | Meaningful | Keys per effect |
|---:|---:|---:|---:|
| 4 | 64 | 32 | 2 |
| 5 | 256 | 128 | 8 |
| 6 | 1,024 | 512 | 32 |

Thus:

- complexity rises because formulas become longer;
- half of syntactically complete formulas still fail;
- every effect remains equally available;
- higher lengths do not make useful spell discovery exponentially hopeless.

Noise density should remain an independently tunable ruleset parameter internally even if initial UI exposes only the formula-length number.

This prevents formula complexity and magical hostility from becoming permanently coupled.

---

## 6. Meaning of noise

A noise formula is syntactically complete but semantically inert.

It:

- produces no recipe effect;
- does not count toward completed meaningful formulas;
- does not contribute to spell affinity;
- does not contribute to Wild Magic affinity eligibility;
- still represents trajectory consumed by the formula parser.

*(Noise is unchanged by the 2026-09-04 amendment below: it is affinity-inert in
every respect. The amendment concerns the INCOMPLETE trailing group, which is
noise's mirror image — affinity without meaning, where noise is meaning without
affinity.)*

This is intentional magical gibberish:

> the rune produced a pronounceable structure, but under this leyline the structure means nothing.

---

## 7. Formula chunking

Trajectory entries are consumed in sequential non-overlapping groups of the configured formula length.

At length 5:

`[F,E,W,A,F,  W,W,E,F,A, ...]`

becomes:

- `F-E-W-A-F`
- `W-W-E-F-A`

Each chunk is independently decoded through the current leyline codebook.

Incomplete trailing entries do not form a formula.

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

## 8. Summon rekeying

Mutable leylines also rekey the discrete pattern language used to derive summon abilities.

Domain:

`Runewright/Leyline/v1/Summon`

The leyline should **not** erase the underlying elemental/CA identity of the creature.

Preserve where practical:

- elemental affinity;
- basic creature statistics derived directly from certified elemental behavior;
- core CA-derived creature identity.

Rekey only the pattern-to-special-ability interpretation.

Thus a familiar elemental creature may exhibit different supernatural abilities under a different mutable leyline.

Exact summon pattern-space mapping should be specified against the current summon implementation before coding, but must use:

- canonical pattern enumeration;
- deterministic seed-derived permutation;
- explicit noise semantics where applicable;
- domain separation from incantations and Armor.

Knowledge of the incantation dictionary must reveal nothing about the summon dictionary.

---

## 9. Aetherial Armor rekeying

Mutable leylines likewise rekey Aetherial Armor's discrete ability-pattern language.

Domain:

`Runewright/Leyline/v1/Armor`

Preserve:

- certified rune behavior;
- T;
- slot cost;
- underlying curved elemental stat bonuses unless separately changed by future design.

Rekey:

- pattern-derived Armor abilities.

A rune that grants one Armor ability in ordinary magic may therefore grant another—or no keyed ability—under a numbered leyline.

Incantation, Summon, and Armor dictionaries must be independently derived despite sharing the same human-readable leyline seed.

---

## 10. Wild Magic integration

Wild Magic derives from the **complete canonical leyline configuration**, not merely the seed word.

Therefore:

- `rivendell`
- `rivendell 4`
- `rivendell 5`

are three different Wild Magic environments.

Changing formula length or mutable-magic configuration rerolls caster-keyed Wild Magic.

The Wild Magic key defined in `WILD_MAGIC_PLAN_VNEXT.md` consumes a canonical `leylineConfigHash`.

---

## 11. Tournament purpose

Mutable Leylines create a distinct format:

> **players must discover the current magical language rather than arrive with memorized recipes.**

A tournament might announce:

> **Leyline: Glass Mountain — Complexity 5**

Players know:

- formulas require five trajectory entries;
- the first determines affinity;
- approximately half of formula keys are meaningful;
- the exact effect codebook is newly derived;
- summon abilities are rekeyed;
- Armor abilities are rekeyed;
- Wild Magic is different.

Players must experimentally determine useful relationships between:

- rune construction;
- CA trajectory;
- formula boundaries;
- local codebook;
- mana efficiency;
- summons;
- Armor;
- Wild Magic.

The competitive skill being tested becomes:

> **How quickly can you conduct magical research and build a functioning doctrine from an unfamiliar leyline?**

---

## 12. What Mutable Leylines prevent—and what they do not

Mutable Leylines make **pre-memorized recipe knowledge** largely useless.

They do not cryptographically prove that a grid was invented after an event began.

A sophisticated foundry may maintain a large private database:

`grid → certified trajectory`

Once the tournament leyline is announced, it can reinterpret those stored trajectories under the new codebook and search for promising candidates.

This is not considered cheating at the protocol layer and cannot realistically be prevented on ordinary personal devices.

The correct claim is:

> **Mutable Leylines force fresh semantic discovery and optimization.**

Not:

> **Mutable Leylines prove every contestant designed every grid from scratch.**

---

## 13. Clean-room tournament option

Tournament organizers who want a genuinely fresh workshop can add an operational rule:

> **All inscription work is performed on organizer-controlled locked-down devices after the leyline is revealed.**

Such devices could contain:

- the tournament Runewright build;
- no network access beyond required local tournament functions;
- no imported spell library;
- no filesystem/database access for external foundry corpora;
- no preloaded candidate grids;
- fresh tournament identity if desired;
- controlled export only after the event.

This is an event-security rule, not a cryptographic property of Runewright.

Runewright should not contort its normal decentralized design in an attempt to enforce something a tournament organizer can enforce much more effectively through physical device control.

---

## 14. Leyline publication timing

Different formats may intentionally use different timing.

### Community Tradition

Leyline is longstanding and known before chapter construction.

Purpose:

- local knowledge;
- home-territory advantage;
- long-term discovery.

### Open Tournament Leyline

New leyline is announced at event start.

Purpose:

- fresh optimization;
- experimental workshop.

### Sealed Clean-Room Leyline

New leyline is revealed only after contestants receive locked tournament devices.

Purpose:

- strongest practical approximation of building magical knowledge from zero.

### Future Unbound Leyline

Participants commit to chapters/rules first, then joint entropy derives an unpredictable leyline.

Purpose:

- prevent any participant, including host, from choosing a favorable environment.

This remains a future mode and does not replace named community traditions.

---

## 15. Consensus and determinism

Every peer must derive byte-identical codebooks from the same configuration.

Therefore the following are consensus-critical:

- seed normalization;
- domain tags;
- formula length;
- noise density;
- effect ordering;
- element encoding;
- tail enumeration order;
- deterministic shuffle/hash-expansion algorithm;
- summon pattern enumeration;
- Armor pattern enumeration;
- lexicon version.

Never use:

- language/runtime `hashCode`;
- platform RNG;
- unordered Map/Set iteration;
- locale-sensitive string handling.

A canonical test-vector suite must be created before release.

Example vectors should pin complete dictionaries for several seeds and complexities so an implementation change cannot silently rewrite established magical traditions.

---

## 16. Suggested initial bounds

For the first implementation, support:

- ordinary grammar: length 3;
- Mutable Leylines: lengths **4, 5, and 6**;
- Mutable noise density: **50%**.

Do not initially expose arbitrary formula lengths.

Reasons:

- length 4 is approachable;
- length 5 should substantially frustrate memorization while remaining experimentally tractable;
- length 6 provides a deliberately difficult research format;
- larger lengths sharply reduce the number of complete formulas obtainable from ordinary trajectories and may interact badly with T limits.

Expand only after real workshop testing.

---

## 17. Design principle

The cellular automaton remains the underlying physics of Runewright.

A leyline does not change what the elements **are**.

It changes how structured elemental behavior is **interpreted**.

Therefore:

> **The rune creates a pattern in nature.  
> The leyline determines which patterns nature recognizes as words.**

Ordinary Runewright rewards accumulated magical scholarship.

Mutable Leyline Runewright rewards the ability to become a magical scholar again from scratch.
