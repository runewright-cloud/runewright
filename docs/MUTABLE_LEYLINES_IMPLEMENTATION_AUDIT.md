# Mutable Leylines — implementation-boundary audit

*Written 2026-09-03. **Read-only audit. No implementation code was written; no
version was bumped; no golden was regenerated.** The only file added is this
one, and it is deliberately uncommitted.*

Sources of truth: `docs/LEYLINE_SEED_PLAN.md`, `docs/WILD_MAGIC_PLAN_VNEXT.md`.
Implementation baseline: engine 12, protocol 7, ruleset 3, `LeylineConfig` +
`leylineConfigHash` shipped and behaviourally inert, Wild Magic v2 keyed on
caster × certified trajectory × certified base cost × leyline hash, wild magic
resolved as a coalesced phase per simultaneous resolution batch.

---

## 0. The headline finding

**The three domains the plan asks to rekey are not three instances of one
mechanism. Only one of them is a chunked-formula dictionary at all.**

| Domain | Structure today | Vocabulary | Segmentation | Affinity source |
|---|---|---|---|---|
| **Incantation** | disjoint chunks of 3 over `FormulaTracker.committed`; `(t1,t2)` → effect | **16** `EffectKind` | disjoint, non-overlapping, residual dropped | chunk[0] |
| **Summon** | **substring search** for 4-char patterns anywhere in the flat committed sequence | **8** `SummonAbility` | none — overlapping matches, each ability at most once | most-frequent element over the whole sequence |
| **Armor** | **substring search** for 4-element runs in `certifiedPerGenerationDominantSequence` (a *different* reading of the trajectory) | **7** `ArmorKeyword` | none — overlapping matches, each keyword at most once | n/a (element-count ladders) |

`LEYLINE_SEED_PLAN.md` §7's chunking rule ("sequential non-overlapping groups of
the configured formula length") describes **incantations only**. §8 and §9 say
"pattern language" and explicitly defer: *"Exact summon pattern-space mapping
should be specified against the current summon implementation before coding."*
That deferral is load-bearing — the summon and armor systems have no formulas,
no chunks, no tails, and no 16-entry vocabulary to permute.

**Consequence for the proposed `lookupFormula(domain, leylineConfig,
trajectoryChunk)` API: it fits Incantation and does not fit Summon or Armor.**
See §3. Building one abstraction over all three would be premature — it would
have to invent pattern-space semantics the plan explicitly says to specify
first, and it would put a chunk-shaped parameter in front of two systems that
do not chunk.

The narrowest honest shape is: **a leyline codebook abstraction for
Incantation now**, with domain separation designed in from the start
(`Runewright/Leyline/v1/{Incantation,Summon,Armor}`), and Summon/Armor rekeying
as separate later slices once their pattern spaces are ruled on.

---

## 1. Trace of the current fixed formula system

### 1.1 Segmentation — five independent implementations of "chunk by 3"

| # | Site | Consensus? | Input | Assumes 3 | Notes |
|---|---|---|---|---|---|
| 1 | `lib/engine/formula.dart:59` `FormulaTracker.formulas` | **YES** | live CA / certified replay | **hardcoded** `i + 3 <= len`, `i += 3` | The canonical one. `residuals` at :67 uses `(len ~/ 3) * 3`. |
| 2 | `deterministic_resolution.dart:4330` `parsedFormulas(SpellAsset)` | **YES** (fallback) | **authored** `spell.formula` | `i + 2 < len`, `i += 3` | Used when `certFormulas == null` (solo / proofless dev flag). |
| 3 | `effect_kind.dart:245` `formulaEffects(List<String>)` | no (display) | **authored** `spell.formula` | `i + 2 < len`, `i += 3` | Card, library, sighting, battle-screen labels. |
| 4 | `wild_magic_preview.dart:358` `completedFormulasFromZones` | no (display) | zones from authored names | `i + 3 <= len`, `i += 3` | Card geometry only; the WM preview itself does **not** use it. |
| 5 | `spell_card_painter.dart:112` | no (display) | authored formula | `i + 3 <= len`, `i += 3` | Elemental symbol ring. |

Plus four `~/ 3` count derivations: `deterministic_resolution.dart:4164`
(`expectedRecitalSlots`), `practice/formula_generator.dart:59`,
`ui/spell_view_screen.dart:154`, `ui/battle_screen.dart:1312`,
`ui/spell_test_lab_screen.dart:167`.

`kElementsPerFormula = 3` (`lib/spells/counter_charm.dart:22`) is the only
*named* constant, and it is used **only** by counter charms and their attune
dialog — never by the formula parser. The parser's 3s are literals.

### 1.2 Formula → effect mapping

* `effect_kind.dart:340` `effectKindFromPair(BorderZone, BorderZone)` — a 16-arm
  exhaustive `switch`, **not a table**. Consensus-critical. Consumes the chunk's
  elements 1 and 2. Total: **every pair means something; there is no "no
  effect" outcome.** This is the structural blocker for noise (§5.2).
* `effect_kind.dart:286` `formulaTripletKind(List<BorderZone>)` — asserts
  `length == 3`.
* `effect_resolver.dart:33` `EffectResolver.resolve(ParsedFormula, …)` — maps
  `(affinity, kind)` → `SpellEffect`. Consensus-critical, consumes a
  `ParsedFormula`, total over all 64 `(affinity, kind)` pairs.

### 1.3 Summon ability lookup

* `creature_spec.dart:87` `kSummonAbilityPattern` — 8 abilities → 4-character
  initial strings (`AAAA`, `FFFF`, `EEEE`, `WWWW`, `FAFA`, `AWAW`, `WEWE`,
  `EFEF`). Consensus-critical.
* `creature_spec.dart:172` `_abilitiesOf` — `initials.contains(pattern)`.
  **Substring match over the whole flat sequence.** No chunking. No formula
  length. Matches may overlap. Each ability at most once.
* `_affinityOf` (:130) — most-frequent element, first-appearance tiebreak, over
  the whole sequence. `_statsOf` (:148) — raw element counts. **Both are the
  "CA-derived identity" §8 says to preserve.**
* Consumes the **certified element sequence** at battle time
  (`certElementSequence`), the authored `spell.formula` in the fallback path.

### 1.4 Armor ability lookup

* `certified_armor.dart:76` `armorKeywordPatterns` — 7 keywords → 4-element
  runs. Consensus-critical. (Morphic/`WWWW` deliberately absent.)
* `certified_armor.dart:214` + `_containsRun` (:280) — contiguous-run search
  over `TrajectoryParser.certifiedPerGenerationDominantSequence`, **which is not
  the formula sequence**: it emits one element per non-neutral generation,
  where the formula reading commits only on lead change / supreme / pulse.
* `armorElementLadder` / `armorEarthLadder` — element-count stat bonuses. §9
  says preserve.

### 1.5 Affinity determination

Three distinct rules, all consensus-critical:

1. **Incantation**: `spellAffinityFromZone(chunk[0])` — per formula.
2. **Summon**: most-frequent element over the whole sequence.
3. **Wild Magic eligibility**: `WildMagic.eligibleElements(List<ParsedFormula>)`
   — tallies `f.affinity` across **completed formulas**, most frequent wins,
   **every tied element stays eligible**. Iterates `SpellAffinity.values` for
   order stability.

### 1.6 Certification path (the consensus spine)

`PeerCastVerifier.semanticsOf` (`peer_cast_verifier.dart:277`) runs three steps
in a load-bearing order:

```
1. formulas         = TrajectoryParser.parse(outputs).formulas      // chunk-by-3
   elementSequence  = TrajectoryParser.certifiedElementSequence()    // flat, chunk-free
2. baseManaCost     = certifiedBaseManaCost(outputs, formulas)       // reads formulas.length
3. wildMagic        = WildMagic.triggersFor(…, baseManaCost, leylineConfigHash, formulas)
```

**`certifiedBaseManaCost` = `(5·seg + dot) · 1.05^T · 1.5^max(0, formulas.length−1)`.**
It is a function of the formula **count**, which under Mutable Leylines becomes
a function of the leyline (both because `L` changes how many chunks fit and
because noise formulas may or may not count). See §7.3 — this is the sharpest
consensus coupling in the whole feature.

**No circularity:** `leylineConfigHash` is independent of any spell, so
`cost → wildMagic` and `leyline → cost` compose cleanly.

### 1.7 Cached / authored formula metadata

* `SpellAsset.formula` — the flat committed element sequence (`FormulaTracker
  .committed`), written at inscribe time. **Chunk-independent**, so it survives
  a leyline change intact. Every *reader* that chunks it (§1.1 rows 2–5) does
  not.
* `SpellAsset.manaCost` — **persisted**, derived at inscribe time from
  `formulas.length` (`spell_asset_integrity.dart:184-193`, `main.dart:626`).
  Under mutable this stored number no longer matches what the duel charges.
* `SpellAsset.behaviouralKinKey` — `behaviouralKinKey(trajectory: formula,
  baseManaCost: manaCost)`. Kin-stacking forfeits and heraldic arms key off it,
  so a leyline-dependent `manaCost` moves kinship too.
* `RecipeBook` (`lib/spells/recipe_book.dart`) — persisted discovered-recipe set
  keyed `'${affinity.name}:${kind.name}'`. **Not leyline-scoped.** Discoveries
  from one leyline would appear as discovered under another.
* `SpellAsset` records **no leyline at all** — there is no field saying which
  grammar a spell was authored under.

### 1.8 Tests / goldens pinning current behaviour

`test/engine/formula_test.dart`, `test/battle/engine/formula_certified_test.dart`,
`test/battle/models/creature_spec_test.dart`,
`test/battle/models/certified_armor_test.dart`,
`test/battle/models/armor_avatar_stats_test.dart`,
`test/battle/models/armor_canonical_bytes_test.dart`,
`test/battle/models/leyline_config_test.dart` (pins the config-hash vectors),
`test/battle/engine/mana_cost_lockstep_test.dart`,
`test/battle/engine/chain_discount_test.dart`,
`test/battle/engine/summon_cast_test.dart`,
`test/battle/engine/wild_magic_test.dart` (eligibility),
`test/spells/wild_magic_preview_test.dart`,
`test/spells/spell_asset_integrity_test.dart`,
`test/practice/formula_generator_test.dart`,
`test/ui/game_screen_formula_test.dart`, `test/ui/game_screen_summon_mode_test.dart`,
plus the replay corpus (`test/battle/replay/`), which uses **ordinary leylines
only** and should therefore see zero deltas from any correctly-gated slice.

---

## 2. Current code vs. the ratified model

| Ratified requirement | State today | Gap |
|---|---|---|
| Ordinary: `mutableMagic=false`, `L=3`, noise 0‰, lexicon 1, `Affinity\|key\|key` | ✅ exactly, and `_checkCanonical` enforces it | none |
| Ordinary behaviour unchanged | ✅ nothing reads `mutableMagic` | must stay true — every slice needs the ordinary-invariance test |
| Mutable lengths 4/5/6 | ✅ **representable and hashed**; `kMin/kMaxMutableFormulaLength` = 4/6 | nothing *reads* it |
| `Affinity \| L−1 keys` | ❌ `ParsedFormula` is a fixed 3-field record (`affinity`, `effectType1`, `effectType2`) | needs a variable-length tail |
| ~50 % noise per `noiseDensityPermille` | ❌ absent | `effectKindFromPair` is **total** — there is no representation of "this formula means nothing" anywhere in the pipeline |
| Noise consumes the chunk | ❌ | chunking and meaning are currently the same step |
| Noise contributes no affinity / no WM eligibility | ❌ | `eligibleElements` tallies every `ParsedFormula.affinity` |
| Noise must not fall back to another formula | ✅ trivially (no fallback exists) | keep it that way |
| Noise deterministic from canonical config | ❌ | no codebook derivation exists |
| Domain separation Incantation/Summon/Armor | ❌ | domains named in the plan, unimplemented |
| CA-derived elemental/stat semantics unchanged | ✅ `_statsOf`, `_affinityOf`, armor ladders are count-based and already leyline-free | preserve |

---

## 3. The dictionary-generation boundary

### 3.1 What exists to wrap

* **Incantation** — `effectKindFromPair(BorderZone, BorderZone)`, a `switch`.
  Not data. To make it leyline-dependent it must first become a **table** keyed
  by a tail, and the tail must become variable-length.
* **Summon** — `kSummonAbilityPattern`, a `const Map<SummonAbility, String>`.
  Already data, but the *matching rule* (substring, overlapping, at-most-once)
  is what would need rekeying, not a chunk lookup.
* **Armor** — `armorKeywordPatterns`, a `const Map<ArmorKeyword,
  List<BorderZone>>`. Same shape as Summon.

**The narrowest place** for an Incantation abstraction is a single seam:
`ParsedFormula → (SpellAffinity, EffectKind)?`. Today that is
`formulaTripletKind` / the `effectKindFromPair` call inside
`EffectResolver.resolve` and inside `formulaEffects`. One nullable-returning
lookup behind one interface, with the ordinary path returning exactly today's
`switch` result and never null.

### 3.2 Would one API serve all three?

**No — not the proposed shape.** `lookupFormula(domain, leylineConfig,
trajectoryChunk)` presumes a chunk. Summon and Armor have no chunks: they scan
for patterns across the whole sequence, allow overlap, and grant each outcome
at most once regardless of how many times it matches. Forcing them through a
chunk-shaped call would require inventing chunked summon/armor semantics, which
§8 explicitly defers.

What the three genuinely share is only: *a canonical enumeration of a key
space, permuted deterministically from `(domainTag, lexiconVersion,
normalizedSeed, formulaLength)`, with some keys designated inert.* That is a
**codebook-derivation utility**, not a lookup API — and it is worth sharing.

**RATIFIED (2026-09-03): no generic `lookupFormula(domain, leyline, chunk)`
abstraction is adopted.** Only Incantation has chunked formulas. Future work
may share deterministic *codebook-construction machinery*, but Incantation,
Summon and Armor each keep their own key space, matching rule, segmentation
(or absence of it) and output vocabulary. Summon and Armor mutable mappings
remain a later design ruling (**R-8**, open).

Recommended split:

* **Shared (justified):** `LeylineCodebook` — canonical key enumeration,
  domain-separated deterministic permutation, exact meaningful/noise
  allocation. One implementation, three domain tags.
* **Domain-specific (do not unify):** what a "key" *is* (a length-`L−1` tail
  vs. a 4-element pattern), how keys are matched against a trajectory
  (disjoint chunking vs. overlapping substring search), and what the outputs
  are (16 `EffectKind` vs. 8 `SummonAbility` vs. 7 `ArmorKeyword`).

### 3.3 If an Incantation-only lookup is built, it needs

* **Inputs:** the domain tag, the `LeylineConfig` (or a pre-derived codebook
  handle so the permutation is computed once per match, not per formula), and
  the chunk's **tail** (`L−1` elements). The affinity element is *not* an input
  — §3 makes "first element = affinity" a protected invariant, so it must not
  participate in the codebook lookup or the leyline could change what an
  element *is*.
* **Output:** conceptually `EffectKind?` — `null` = noise. Affinity should
  **not** be in the output; it comes from `chunk[0]` on the caller's side,
  under both grammars.
* **Noise representation:** the cleanest is a nullable effect on a
  `ParsedFormula`-successor that still carries its affinity and its consumed
  elements (so "consumes the trajectory chunk" is structurally true), with
  every downstream consumer — effects, affinity tally, mana `effectCount`, WM
  eligibility — filtering on it. A sentinel `EffectKind.noise` enum member is
  **not** recommended: it would silently acquire a row in
  `kEffectDescription`, `EffectResolver._build`'s exhaustive switch, and
  `recipeKey`.

---

## 4. Formula segmentation

* **Where `formulaLength` enters:** exactly one consensus site —
  `FormulaTracker.formulas` / `.residuals` (§1.1 row 1) — plus the authored
  fallback `parsedFormulas` (row 2) which must agree with it. The other three
  are presentation and must be repointed for consistency, not for consensus.
* **Is the affinity element part of every chunk?** Yes. §3: *"first element
  remains the formula's affinity; the remaining `L−1` elements form the effect
  key."* Each chunk is `L` elements, one of which is the affinity.
* **Overlap:** §7 is explicit — *"sequential non-overlapping groups"*. Disjoint.
* **Incomplete trailing chunks:** §7 is explicit — *"Incomplete trailing entries
  do not form a formula."* This matches today's residual behaviour exactly, so
  **no new semantics need inventing.** ✅ Not a ruling.
* **More than one implementation?** Yes — five (§1.1). Two of them are
  consensus-reachable (`FormulaTracker`, `parsedFormulas`).
* **Do previews and battle certification chunk independently?** **Yes, and they
  read different data.** Battle certification chunks the *certified* sequence
  via `FormulaTracker`; the spell card, library, sighting list and battle-screen
  labels chunk the *authored* `spell.formula` via `formulaEffects`. They agree
  today only because both chunk by 3 and an honest asset's authored formula
  equals its certified sequence. The Wild Magic preview is the exception and is
  already correct — it delegates to `PeerCastVerifier.certifyOwnProof`, the same
  call the engine makes.

---

## 5. Noise generation

### 5.1 What the plans pin, exactly

`LEYLINE_SEED_PLAN.md` §4 pins the **inputs and the shape**:

> derive a deterministic codebook from: domain tag; lexicon version; normalized
> community seed; formula length. […] Generate the complete tail space in
> canonical lexicographic elemental order. Use deterministic hash expansion /
> PRNG to construct a canonical permutation. The codebook then assigns a fixed
> proportion of tails to the sixteen base effects; the remaining tails to noise.

§5 pins the **counts**, and they are exact, not statistical:

| L | tails | meaningful | keys/effect |
|---|---|---|---|
| 4 | 64 | 32 | 2 |
| 5 | 256 | 128 | 8 |
| 6 | 1024 | 512 | 32 |

**So the answer to the audit's own question is already pinned in outline: it is
an exact-count permutation/allocation, NOT independent per-formula hashing.**
Independent hashing would give ~50 % and *uneven* per-effect counts, which
contradicts §5's "every effect remains equally available" and its integer
keys-per-effect table.

### 5.2 What is NOT pinned — rulings required

1. **The permutation algorithm.** "deterministic hash expansion / PRNG" names no
   function. `HashRng` exists and is already the codebase's canonical
   deterministic stream (`SHA-256(seed ‖ uint32be(counter))`), and
   `List.shuffle(HashRng)` is used for Zephyr. Candidate A: seed a `HashRng`
   from a domain-separated config hash and Fisher-Yates the canonically-ordered
   tail list. Candidate B: assign each tail a 64-bit `SHA-256(domain ‖
   configHash ‖ tailBytes)` sort key and sort ascending (ties broken by
   canonical tail order) — order-independent by construction and trivially
   testable. **Recommend B**, because it has no dependence on iteration order
   at all and each tail's rank is independently verifiable, but this is a
   consensus choice and needs a ruling.
2. **The allocation rule.** Given a permuted tail list and a meaningful count
   `M`, how are the first `M` tails dealt to the 16 effects? Round-robin
   (`i mod 16`) and blocked (`i ÷ (M/16)`) give different codebooks.
3. **The remainder rule.** `M = round(tails · (1000 − noiseDensityPermille) /
   1000)` is not generally divisible by 16 — at 333‰ and `L=4`, `M = 43`.
   Which effects get the extra 11? §5 says "evenly" and gives only
   evenly-divisible examples.
4. **The rounding of `noiseDensityPermille` → `M`** (floor / round / ceil) is
   unstated and is consensus-critical.
5. **Whether the domain tag string is exactly** `Runewright/Leyline/v1/Incantation`
   and whether it is hashed with a length prefix like every other tag in the
   codebase (`WildMagic.kWildMagicDomain`, `LeylineConfig._domain`).

**Available canonical inputs, all already consensus-safe:** the domain tag,
`lexiconVersion`, `normalizedSeed`, `formulaLength`, `noiseDensityPermille` —
i.e. precisely the `leylineConfigHash` preimage plus a domain tag. Deriving
from `leylineConfigHash` itself (a 32-byte value already pinned by vectors) plus
a domain tag is the smallest construction that satisfies every stated property:
no player, no caster, no proof bytes, no private grid data, no map/set
iteration, stable across devices.

**STOP GATE.** Items 1–5 must be ruled before coding. They are exactly the
"deterministic dictionary/noise generation" stop condition.

---

## 6. Effect distribution — "16 effects"

| Domain | Vocabulary size | Uniform weighting today? |
|---|---|---|
| Incantation | **16** (`EffectKind`) | yes — a perfect 16→16 bijection from the 16 tails |
| Summon | **8** (`SummonAbility`) | yes, but only 8 patterns exist in a 4⁴ = 256 pattern space |
| Armor | **7** (`ArmorKeyword`) | 7, with `WWWW`/Morphic deliberately unimplemented |

**Mismatch to flag:** §5's "evenly over all sixteen effects" is true **only for
Incantation**. Summon has 8 outcomes and Armor 7. Applying the same 50 %/16
arithmetic to them is meaningless. §8/§9 never actually claim 16 — they say
"pattern language" and defer the mapping — but the audit brief's phrasing
("approximately 50 % noise evenly over 16 effects") reads as if it applied to
all three. It does not.

**Duplicate dictionary entries** are not merely permissible, they are
*required* by §5: at `L=6` each of the 16 effects owns 32 distinct tails. The
codebook is therefore many-to-one by design, and the reverse lookup ("which
tails mean Blast?") is a set, not a value — relevant to any future recipe/UI
surface.

No rebalancing proposed here.

---

## 7. Affinity and Wild Magic eligibility

### 7.1 How affinity flows today

```
certified trajectory
  → FormulaTracker.committed              (flat, chunk-free)
      → .formulas (chunks of 3)
          → ParsedFormula.affinity = chunk[0]
              ├─ EffectResolver.resolve      → the effect's flavour column
              ├─ pureAffinityOf(formulas)    → chain discount / advancement
              └─ WildMagic.eligibleElements  → tally → most frequent, ALL ties eligible
                    → WildMagic.triggersFor  → (row, element) → effect kind
```

### 7.2 Does the ratified rule fit without touching WM v2 hashing?

**Yes, cleanly.** The Wild Magic v2 preimage is
`domain ‖ version ‖ casterPubkey ‖ len ‖ trajectoryBytes ‖ baseManaCost ‖
leylineConfigHash`. Its trajectory field is
`TrajectoryParser.certifiedElementSequence` — the **flat, chunk-free** committed
sequence, which no leyline changes (§17: a leyline does not change what the
elements *are*). So:

* the **hash** needs no change;
* `formulas` is passed to `triggersFor` only for `eligibleElements`, so making
  noise formulas absent from (or filtered out of) that list gives exactly the
  ratified behaviour — no effect, no affinity, no eligibility — with **no change
  to `WildMagic` at all**;
* the unresolved balanced-affinity policy (§9 of the WM plan) is untouched, and
  no independent affinity roll is introduced.

One consequence to note: a spell whose every formula is noise yields an empty
eligible set and therefore **no wild magic**, which already has a correct code
path (`triggersFor` returns `const []` for empty eligibility).

### 7.3 The real coupling: mana cost

`certifiedBaseManaCost` reads `formulas.length`. If noise formulas are excluded
from that list (as §6's *"does not count toward completed meaningful formulas"*
requires), then **the certified base mana cost becomes leyline-dependent** — and
because it is field 6 of the Wild Magic preimage, wild magic reacts to it. That
composes correctly (leyline → cost → wild magic, no cycle), but it has three
downstream consequences that need a ruling:

1. `SpellAsset.manaCost` is **persisted at inscribe time** and would no longer
   describe the spell's cost in a mutable match.
2. `behaviouralKinKey(trajectory, baseManaCost)` would change, moving
   **kin-stacking forfeits** and **heraldic arms** under a mutable leyline.
3. The live inscription readout (`main.dart:_computeManaCost`) chunks by 3 and
   would misprice.

### 7.4 RATIFIED (2026-09-03) — noise does not move mana cost

**`effectCount` counts every syntactically complete chunk, noise included.**

A noise formula still consumes a structural trajectory chunk and therefore
counts toward base mana cost exactly as that chunk counts today. Mutable
interpretation decides whether a chunk **manifests an effect**, not whether the
certified trajectory **intrinsically costs mana**.

So Mutable Leylines must NOT make any of these leyline-dependent merely because
a formula decodes to noise:

* `certifiedBaseManaCost`;
* the persisted `SpellAsset.manaCost`;
* `behaviouralKinKey`;
* kin stacking;
* heraldic identity.

This closes **R-5 and R-6**, and it removes the entire coupling §7.3 warned
about: `formulas.length` stays a function of the trajectory and the formula
LENGTH alone, never of the codebook. `certifiedBaseManaCost` — and therefore
field 6 of the Wild Magic v2 preimage — moves only when `formulaLength` itself
changes, which is already a different `leylineConfigHash`.

**Ratified noise semantics, in full:**

| A noise formula… | |
|---|---|
| consumes its trajectory chunk | ✅ yes |
| counts structurally toward base mana cost | ✅ yes |
| produces an Incantation effect | ❌ no |
| contributes affinity / effect eligibility from that chunk | ❌ no |
| contributes Wild Magic eligibility from that chunk | ❌ no |
| falls back to another formula | ❌ never |

Implementation consequence for Slice C: the **count** of complete formulas and
the **list of meaningful formulas** become two different things. Pricing reads
the count; `EffectResolver`, `pureAffinityOf` and
`WildMagic.eligibleElements` read the meaningful list.

---

## 8. Interaction with Slice 7 coalescing

**The Slice 7 seam already supports everything Mutable Leylines could ask of
it. No additional architecture is needed.** Concretely:

| Requirement | Where it is already satisfied |
|---|---|
| duplicate same-effect triggers from **one cast** | `coalesceWildMagicTriggers` keys purely on `record.effect`. Nothing in it distinguishes contributors, so two triggers of one cast collapse identically to two triggers of two casts. |
| duplicate same-effect triggers from **multiple casts** | same, and pinned by the existing tests. |
| strongest-bracket selection | `brackets[effect] = max(...)`, commutative. |
| recipient union | Structurally trivial: every applicator effect targets `ctx.livingAvatars`, never a per-trigger recipient. There is no per-trigger recipient to union. |
| contributor-independent event RNG | `wildMagicEventSeed` takes only entropy, matchId, turn, batch code, effect code, effective bracket. `contributingCasterIds` is a `Set<String>` sorted for display and never hashed. A duplicate caster id already collapses (pinned by *"a duplicate caster id appears once in the attribution list"*). |
| ordering survives a remapped table | `kWildMagicEffectCode` is pinned per **effect kind**, not per `(row, element)` cell — explicitly so a remap cannot move consensus ordering. |

**However — a design finding that may make this moot.** The Slice 7 review
assumed Mutable Leylines "can remap (row, element) → effect". **`LEYLINE_SEED_PLAN.md`
§10 does not say that.** It says Wild Magic derives from the complete canonical
leyline configuration, so `rivendell`, `rivendell 4` and `rivendell 5` are three
different Wild Magic environments — which is **already implemented** (the config
hash is field 7 of the v2 preimage). §1's bullet list names "Wild Magic" among
what a mutable leyline rekeys, and §10 is the section that explains what that
means: a rerolled *hash*, not a rerolled *table*.

**RATIFIED (2026-09-03) — `wildMagicEffectFor` is NOT rekeyed.**

The fixed 3-row × 4-affinity mapping onto 12 unique `WildMagicEffectKind`s
remains canonical under every leyline. Mutable Leylines already rekey Wild Magic
the way §10 describes — through `leylineConfigHash` in the Wild Magic v2
semantic hash — and that is the whole of it. **Mutable Leylines require no
wild-magic work at all.**

Two consequences to record:

1. **Same-cast duplicate Wild Magic effect kinds remain structurally
   impossible.** The 12-distinct-cells property is permanent, not provisional.
   Wording in `WILD_MAGIC_SLICE7_REVIEW.md` §1/§10 and
   `WILD_MAGIC_PLAN_VNEXT.md` §11 that anticipated a Mutable-Leyline remap is
   corrected accordingly.
2. **Slice 7 coalescing is still required, and for the reason it always
   was** — cross-cast simultaneous duplicates and N-player world-event
   semantics. Nothing about that ruling is weakened; only the *second*,
   hypothetical customer for it is withdrawn.

---

## 9. Preview / UI implications

| Surface | Reads | Assumes L=3 | Assumes fixed dict | Assumes no noise | Class |
|---|---|---|---|---|---|
| `formula_bar.dart` (live inscription) | live `FormulaTracker.formulas` | yes (via tracker) | `formulaTripletKind` | yes | presentation, but **fed by the consensus tracker** |
| `main.dart:_recordNewFormulas` | live tracker | yes | `formulaTripletKind` → `RecipeBook` | yes | presentation + **persisted discovery state** |
| `main.dart:_computeManaCost` | live tracker | yes | — | yes | **advertises a consensus number** |
| `spell_card_painter.dart:1407` | authored `spell.formula` | yes (`formulaEffects`) | yes | yes | presentation |
| `spell_card_painter.dart:112` | authored formula | yes | — | — | presentation (symbol ring) |
| `library_screen.dart:1161, :3628` | authored formula / sighting | yes | yes | yes | presentation |
| `battle_screen.dart:204, :4774` | authored formula | yes | yes | yes | presentation |
| `recipes_screen.dart` | static `_Recipe` list of all 16 pairs + 8 summon patterns | yes | **hardcoded table** | yes | presentation — but it *teaches the codebook*, which under a mutable leyline is unknown by design |
| `spell_view_screen.dart:154` | live tracker | `~/ 3` | — | — | presentation |
| `practice/formula_generator.dart:59` | spell formula | `~/ 3` | — | — | presentation (vocal drill) |
| `wild_magic_preview.dart` | **the proof**, via `certifyOwnProof` | no | n/a | n/a | ✅ already correct |
| `duel_host_settings_screen.dart:93` | — | — | — | — | hardcodes `LeylineConfig.ordinary`; a mutable picker does not exist |
| `solo_practice_settings_screen.dart:76` | — | — | — | — | forces ordinary |
| `settings_screen.dart` | — | — | — | — | seed word only |

**Consensus/business vs. presentation.** Only three rows are more than
cosmetic: `_computeManaCost` (advertises the certified price),
`_recordNewFormulas` → `RecipeBook` (persists discoveries that are
leyline-specific under mutable), and `formula_bar` (reads the consensus
tracker's chunking).

**Preview-vs-certification divergence to flag:** the spell card, library,
sightings and battle screen resolve effects from the **authored**
`spell.formula` through `formulaEffects`, while the duel resolves from the
**certified** sequence through `TrajectoryParser.parse`. They agree today by
coincidence of both chunking by 3 over data that matches for an honest asset.
Under mutable, they would diverge for two independent reasons (chunk size and
noise) unless the display path is given the active `LeylineConfig` too. This is
the same class of bug M4.22 cost a duel, and it is worth fixing on its own
merits before any mutable behaviour lands.

Also: **no production path can construct a mutable config today.** `LeylineConfig
.mutable` has zero callers in `lib/` — only tests. That is what makes the
current wire exposure latent rather than live (§10).

---

## 10. Backward compatibility / wire audit — **the major stop gate**

### 10.1 What is emitted

`MatchConfig.toJson` emits **both**:

```json
"communitySeed": "rivendell",              // legacy flat — the seed only
"leyline": { "mutableMagic": true, "formulaLength": 5, ... }
```

For a mutable config the flat key carries **the seed with the number stripped**.
Any consumer reading only `communitySeed` sees `rivendell` — i.e. **a mutable
leyline silently downgrades to the ordinary tradition of the same name.** That
is exactly the "old client silently interprets a mutable match as an ordinary
seed-only match" scenario.

### 10.2 Where that is currently caught

| Path | Gate | Verdict |
|---|---|---|
| LAN handshake, step 2b | `duel_setup.dart:301` — symmetric `peerCaps.battleEngineVersion != kBattleEngineVersion` → forfeit `battle_engine_mismatch` | ✅ **airtight**, and deliberately placed on the only symmetric declaration in the handshake |
| LAN handshake, step 3b | `effectiveConfig.battleEngineVersion != kBattleEngineVersion` → forfeit | ✅ catches a stale/lying config even from a same-version peer |
| `exchangeMatchConfig` (symmetric) | `ours.matches(theirs)` includes `leyline == other.leyline`, which compares **every grammar field** | ✅ |
| `receiveHostMatchConfig` (host-authoritative, the LAN duel path) | **no `matches()` call at all** — the guest adopts verbatim | ⚠️ relies entirely on step 2b/3b |
| `LeylineConfig.fromMatchConfigJson` | throws if flat and structured seeds disagree; falls back to `ordinary(legacy)` when `leyline` is **absent** | ⚠️ the fallback is the downgrade path — safe only because a peer omitting `leyline` also omits `battleEngineVersion` and is refused at step 2b |
| Replay | `test/battle/replay/` scripts build states in-process; **no `MatchConfig` JSON round trip** | ✅ no exposure |
| QR / deep-link / import | **none exist** — `MatchConfig` is never serialized outside the two `battle_session.dart` frames | ✅ no exposure |
| Stored config | `duel_host_settings_screen` reconstructs `LeylineConfig.ordinary(...)` from a seed string every time | ⚠️ would silently drop mutability if a mutable picker is added without changing this |

### 10.3 Recommendation

**Enabling any mutable behaviour requires a `kBattleEngineVersion` bump, and
that bump is both necessary and — for the LAN path — sufficient.** The engine
gate is symmetric, runs before identity auth and before the config, and is
checked twice (peer capability and config pin). No protocol bump is needed:
nothing about the *framing* changes, only the meaning of fields that already
travel.

Two narrow hardenings are worth doing anyway, because they remove reliance on a
gate that lives in a different subsystem:

1. **Guard the legacy fallback — narrowly, and on the network path only.**
   **RATIFIED (2026-09-03):** do **not** globally remove the flat
   `communitySeed → ordinary` fallback in
   `LeylineConfig.fromMatchConfigJson`. Legacy flat-only data must keep
   decoding as an ordinary leyline for backward-compatible and local use
   (stored settings, older on-disk records, solo).

   What changes when mutable gameplay goes live is narrower: the **network
   consensus path** must *require* structured leyline data from a
   mutable-capable, same-engine peer, so a missing `leyline` object cannot
   silently degrade a mutable match to ordinary. A same-engine peer that omits
   it is refused, not defaulted.

   **That gate belongs to the behaviour-enabling slice (D), not to Slice A.**
   This closes **R-9**.
2. **Do not widen the flat key.** The flat `communitySeed` must keep carrying
   the *seed only*. Encoding "rivendell 5" into it would be worse: an old
   client would then adopt a seed word that no leyline hash agrees with.

**Do not add a mutable picker to any settings screen until the engine gate for
mutable behaviour is in place** — a config the local build can construct but
not honour is the same hazard pointed inward.

---

## 11. Versioning forecast

| Change | Engine | Protocol | Ruleset | Circuit/VK | Why |
|---|---|---|---|---|---|
| Consolidate the five chunkers behind one `formulaLength`-parameterised path, still called with 3 | **no** | no | no | no | Pure refactor. Byte-identical output for `L=3`; the replay corpus is the proof. |
| Add `LeylineCodebook` derivation (unused) | **no** | no | no | no | Nothing reads it. Same posture as `LeylineConfig` Slice 1. |
| Introduce noise-capable `ParsedFormula` (ordinary always meaningful) | **no** | no | no | no | Ordinary path produces an identical formula list; nothing observable changes. |
| **Wire mutable chunking + codebook into certification** | **YES** | no | no | no | Two builds compute different `formulas`, different `certifiedBaseManaCost`, different Wild Magic, different effects, from identical proofs. Textbook engine-epoch change; nothing on the wire and no proof semantics move. |
| Summon rekeying | **YES** | no | no | no | Same reasoning; `CreatureSpec` is derived state, not proof output. |
| Armor rekeying | **YES** | no | no | no | Same. Note `armor_canonical_bytes_test` pins hashed armor state. |
| Expose a mutable picker in the UI | no *(if it lands after the engine bump)* | no | no | no | Presentation, but it must not ship **before** the gate. |

**Ruleset and circuit/VK never move.** The CA is untouched: a leyline changes
how a certified trajectory is *interpreted*, never what the automaton does, what
a proof attests, or which VK accepts it (§17, and CLAUDE.md's separation of the
three version constants).

---

## 12. Tests and replay impact

### 12.1 The invariants worth naming

* **Ordinary invariance** (every slice): for `LeylineConfig.ordinaryDefault` and
  any `ordinary(seed)`, `formulas`, `certifiedBaseManaCost`, wild magic,
  summons, armor and `BattleState.toCanonicalBytes` are **unchanged**. The
  replay corpus is the strongest form of this and must stay green with **no
  golden regenerated**.
* **Codebook determinism**: the same `LeylineConfig` built twice, in either
  order, in two isolates, yields byte-identical codebooks.
* **Domain independence**: Incantation, Summon and Armor codebooks for one
  config are pairwise different, and knowing one reveals nothing about another
  (pin as: different domain tag ⇒ different permutation).
* **Order independence**: no `Map`/`Set` iteration reaches the codebook —
  assert by constructing the tail space in two different insertion orders.
* **Noise is inert**: a noise formula contributes no effect, no affinity, no
  `effectCount`, no Wild Magic eligibility, and **consumes its chunk** (the
  next formula starts `L` elements later, not at the next element).
* **Segmentation follows `formulaLength`**: the same trajectory yields
  `⌊n/L⌋` formulas.
* **Old-client refusal**: a peer declaring engine `N−1` is forfeited before any
  state exists (extend `battle_engine_version_test.dart`'s existing epoch group).
* **Exact allocation**: at 500‰, each of the 16 effects owns exactly
  `tails/32` keys for L = 4, 5, 6.

### 12.2 Existing tests to extend rather than duplicate

`leyline_config_test.dart` (already has mutable-hash vectors),
`formula_test.dart` + `formula_certified_test.dart` (segmentation),
`creature_spec_test.dart`, `certified_armor_test.dart`,
`wild_magic_test.dart` (eligibility), `mana_cost_lockstep_test.dart`
(the `effectCount` ruling lands here), `wild_magic_preview_test.dart`,
`battle_engine_version_test.dart` (the gate), `match_replay_test.dart`.

**A canonical codebook vector corpus is required before release** (§15:
*"Example vectors should pin complete dictionaries for several seeds and
complexities"*). That is the Mutable-Leyline analogue of `GOLDEN_VECTORS.md`,
and it should exist from the slice that first derives a codebook.

---

## 13. Proposed implementation sequence

### Slice A — consolidate segmentation ✅ **DONE 2026-09-03**

Implemented as specified, with one scope note recorded below (§13.1). All
segmentation now runs through `lib/engine/formula_segmentation.dart`; every
production caller passes `kIncantationFormulaLength` (3); nothing reads
`LeylineConfig.formulaLength` for behaviour. Full suite 2380/2380 green,
replay corpus unchanged with no golden regenerated, engine 12 / protocol 7 /
ruleset 3 / VK untouched.

#### 13.1 Scope note — three adjacent sites were included

The five chunkers were the mandate. Three further sites wrote
`(n ~/ 3) * 3` — the identical rule expressed as a count — and were routed
through the same primitive's `completeFormulaElementCount`, because leaving a
raw division behind would have left exactly the duplication this slice exists
to remove, and one of the three (`expectedRecitalSlots`) lives in the consensus
file and feeds recall pricing. They are one-line mechanical swaps:

* `deterministic_resolution.dart` — `expectedRecitalSlots` *(consensus)*
* `ui/battle_screen.dart` — `_expectedElementCount` *(UI twin of the above)*
* `practice/formula_generator.dart` — `PracticeFormula.fromSpellFormula`

`LeylineConfig.kOrdinaryFormulaLength` was also made an **alias** of the engine
constant rather than a second spelling of 3, so the config layer's canonicality
rule and the segmentation it describes cannot drift.

#### 13.2 A pre-existing bug found and deliberately NOT fixed

`lib/ui/spell_view_screen.dart:154` computes
`max(0, (_formulaTracker.committed.length - 1) ~/ 3)` for its mana readout.
That is the exact form `main.dart:620` documents as **wrong** — it over-counts
on any residual (4 committed activations give 1 where the correct
`formulas.length - 1` gives 0), which is how the live readout once advertised a
price ~1.5× what the duel deducted. `main.dart` was fixed; this screen was
missed. It is display-only and out of Slice A's mechanical scope, so it is
recorded here rather than changed.

#### Original plan

1. **Goal:** exactly one consensus chunking implementation, parameterised by a
   formula length that is always 3 for now; repoint the presentation chunkers
   at it.
2. **Files:** `lib/engine/formula.dart` (`FormulaTracker.formulas`/`.residuals`),
   `deterministic_resolution.dart` (`parsedFormulas`), `effect_kind.dart`
   (`formulaEffects`), `wild_magic_preview.dart`
   (`completedFormulasFromZones`), `spell_card_painter.dart`, plus the four
   `~/ 3` count sites.
3. **Consensus boundary:** touched but not crossed — output must be
   byte-identical at L=3.
4. **Settled:** §7's chunking rule; disjoint groups; trailing remainder dropped.
5. **Unresolved:** none.
6. **Versions:** none. Engine 12, protocol 7, ruleset 3, VK unchanged.
7. **Tests:** replay corpus green with zero golden regeneration;
   `formula_test` / `formula_certified_test` unchanged and passing; a new
   equivalence test asserting all five paths agree on a shared fixture.
8. **Gate:** full suite + replay, zero deltas.

### Slice B — `LeylineCodebook` derivation, unused

1. **Goal:** deterministic, domain-separated codebook derivation for the
   Incantation domain, plus the canonical vector corpus. Nothing reads it.
2. **Files:** new `lib/battle/models/leyline_codebook.dart`; new
   `test/battle/models/leyline_codebook_test.dart` + vectors.
3. **Consensus boundary:** the codebook bytes are consensus-critical the moment
   anything reads them, so they are pinned by vectors from day one — exactly the
   posture `LeylineConfig` Slice 1 took.
4. **Settled:** inputs (§4); exact-count allocation and the 4/5/6 count table
   (§5); domain tags; ordinary = no codebook.
5. **Unresolved:** **§5.2 items 1–5 — the permutation algorithm, the allocation
   rule, the remainder rule, the permille rounding, the exact tag bytes. This
   slice cannot start until those are ruled.**
6. **Versions:** none (nothing reads it).
7. **Tests:** determinism, domain independence, order independence, exact
   per-effect counts, the vector corpus.
8. **Gate:** vectors reviewed and ratified as the permanent record.

### Slice C — noise-capable formula representation, ordinary-only

1. **Goal:** let a formula *be* noise without any leyline reading it yet:
   `ParsedFormula` grows a nullable effect (or gains a sibling type), and every
   consumer — `EffectResolver`, `pureAffinityOf`, `eligibleElements`,
   `certifiedBaseManaCost`'s `effectCount` — filters correctly. Under ordinary
   magic nothing is ever noise, so nothing changes.
2. **Files:** `trajectory_parser.dart`, `effect_kind.dart`,
   `effect_resolver.dart`, `peer_cast_verifier.dart`, `wild_magic.dart`
   (eligibility filter), `deterministic_resolution.dart`.
3. **Consensus boundary:** crossed in shape, not in value.
4. **Settled:** §6's noise semantics (no effect, no affinity, no eligibility,
   consumes the chunk, never falls back).
5. **Unresolved:** **the `effectCount` ruling (§7.3)** — meaningful-only vs.
   all-complete-chunks, and what happens to persisted `SpellAsset.manaCost`
   and `behaviouralKinKey`.
6. **Versions:** none if ordinary output is bit-identical (assert it).
7. **Tests:** ordinary invariance; a hand-constructed noise formula proves
   inertness across all four consumers.
8. **Gate:** replay corpus, zero deltas.

### Slice D — wire mutable Incantation behaviour + the engine gate

1. **Goal:** `mutableMagic` finally *does* something: chunk at `formulaLength`,
   look the tail up in the codebook, resolve noise as inert.
2. **Files:** the Slice-A seam, the Slice-B codebook, `peer_cast_verifier.dart`,
   `duel_setup.dart`/`leyline_config.dart` compat hardening (§10.3).
3. **Consensus boundary:** **crossed.** This is the real change.
4. **Settled:** everything in §2's ratified column.
5. **Unresolved:** none if B and C's rulings landed.
6. **Versions:** **`kBattleEngineVersion` 12 → 13.** Protocol 7, ruleset 3, VK
   unchanged.
7. **Tests:** ordinary invariance (again, and this is the one that matters
   most); mutable segmentation; noise inertness end-to-end; the old-client
   refusal test; mana-cost lockstep under a mutable config.
8. **Gate:** two-device hardware pass — this is the first slice where two builds
   can disagree about what a spell means.

### Slice E — Summon and Armor rekeying *(specify first)*

1. **Goal:** rekey the pattern languages, preserving CA-derived stats/affinity.
2. **Unresolved, and blocking:** §8 says the summon pattern-space mapping *must*
   be specified against the current implementation before coding. Neither
   domain chunks; both do overlapping substring search over 4-element patterns
   in spaces of 4⁴ = 256, with 8 and 7 outcomes respectively. What "noise"
   even means for a pattern that simply never occurs is undefined.
3. **Versions:** engine bump when it lands.
4. **Gate:** a design ruling, before any code.

### Slice F — UI: mutable picker, leyline-aware previews, leyline-scoped RecipeBook

Presentation and persisted-discovery scope. Must land **after** Slice D's gate.
Also the right place to fix the pre-existing preview-vs-certification divergence
(§9).

---

## 14. Stop conditions reached

Per the audit's own stop rules, **implementation must not begin** until the
following are ruled. Each maps to a listed stop condition.

| # | Ruling | Stop condition |
|---|---|---|
| R-1 | The codebook permutation algorithm (candidates in §5.2) | deterministic dictionary/noise generation |
| R-2 | The meaningful-tail → effect allocation rule (round-robin vs. blocked) | same |
| R-3 | The remainder rule when `M` is not divisible by 16, and the permille→`M` rounding | same |
| R-4 | Exact domain-tag bytes and length-prefixing | same |
| R-5 | Does `effectCount` (and therefore certified base mana cost, and therefore Wild Magic's preimage, and therefore `behaviouralKinKey`) count noise formulas? | proof/certified semantics |
| R-6 | What happens to persisted `SpellAsset.manaCost` and kin keys under a mutable leyline | proof/certified semantics |
| R-7 | Is the Wild Magic 3×4 → effect table itself rekeyed, or is the config hash sufficient? (§8) | affinity semantics |
| R-8 | Summon and Armor pattern-space mapping (§8 of the plan defers this explicitly) | — |
| R-9 | Should the legacy flat-`communitySeed` fallback become an error once mutable is live? (§10.3) | old-client compatibility |

**Not** ambiguous, and therefore **not** rulings: formula chunking is fully
specified (§7 — disjoint, non-overlapping, trailing remainder discarded, affinity
is chunk[0]); noise semantics are fully specified (§6); the wire gate is
answerable from the code (engine bump, no protocol bump).
