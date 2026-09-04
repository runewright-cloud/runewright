# Mutable Leylines — implementation-boundary audit

*Written 2026-09-03 as a **read-only audit**, before any implementation. Slices
A–D shipped on 2026-09-03/04 and this document was amended in place; see the
status banner below for what is now as-built and what is still a proposal.*

Sources of truth: `docs/LEYLINE_SEED_PLAN.md`, `docs/WILD_MAGIC_PLAN_VNEXT.md`.
Audit baseline (the state this document was written *against*): engine 12,
protocol 7, ruleset 3, `LeylineConfig` + `leylineConfigHash` shipped and
behaviourally inert, Wild Magic v2 keyed on caster × certified trajectory ×
certified base cost × leyline hash, wild magic resolved as a coalesced phase per
simultaneous resolution batch.

---

## Status — as-built, 2026-09-04

**Mutable Incantations are live in the engine.** Slices A–D are committed;
Slices E and F are not started. **Current versions: engine 13, protocol 7,
ruleset 3, circuits/VK unchanged.**

| Slice | State | Commit |
|---|---|---|
| A — consolidate segmentation | ✅ shipped | `be9132c` |
| B — deterministic codebook + vectors | ✅ shipped | `4726649` |
| C — noise-capable semantics | ✅ shipped | `09a7f61` |
| D — live mutable interpretation | ✅ shipped | `3f4f08b` |
| E — Summon / Armor rekeying | ⛔ blocked on R-8 | — |
| F — player-facing surfaces | 🔜 next | — |

### How to read this document

Sections 1–12 are the **original audit**: a trace of the code as it stood on
2026-09-03, written to find the boundaries. They are preserved because the
reasoning is what the rulings rest on, but **they describe the pre-Slice-A code
and must not be read as current design.** Where a section has been overtaken,
it now says so inline.

§13's slice entries are the current record. Each shipped slice leads with an
**as-built** description and keeps its **Original plan** at the end, clearly
labelled — several plans were superseded by something better during
implementation, and the difference is usually the interesting part.

### The shipped architecture in one page

* **Structure and meaning are separate questions.** Segmentation
  (`formula_segmentation.dart`) cuts a certified trajectory into complete
  formulas at the active grammar length; interpretation happens *afterwards*,
  on an already-cut formula. Nothing interprets before it segments.
* **`IncantationLexicon.of(LeylineConfig)`
  (`lib/battle/engine/incantation_lexicon.dart`) is the sole live interpretation
  and config boundary.** It answers exactly two questions: `formulaLength`
  (structural) and `meaningOf(ParsedFormula) → IncantationMeaning` (semantic).
  It is the **only** production reader of `LeylineConfig.mutableMagic`, the only
  production importer of `leyline_codebook.dart`, and the only caller of
  `IncantationCodebook.derive`. All three are pinned by posture tests in
  `test/battle/models/incantation_meaning_test.dart`.
* **Ordinary interpretation remains canonical through `effectKindFromPair`**,
  reached via `ordinaryIncantationMeaning`. An ordinary lexicon derives no
  codebook and reads no seed, hash, ordering or noise density.
* **A mutable codebook is derived once per deterministic match-resolution
  context** — a `late final` on `DeterministicResolution`, itself a `late final`
  on `TurnLoop` — and passed down to the verifier paths rather than re-derived
  per cast. There is no cache.
* **`ParsedFormula` retains its structural tail.** `chunk[0]` is the affinity;
  `chunk[1..]` is the tail, which *is* the codebook key. Affinity is never part
  of a key. `effectType1`/`effectType2` are ordinary-only readings that throw on
  a mutable-length tail rather than silently truncating it.
* **Noise is a structurally complete formula with no meaning.** It produces no
  Incantation effect, contributes no affinity eligibility and no Wild Magic
  eligibility, and never falls back to the ordinary table — but it consumes its
  chunk, counts toward intrinsic mana, and is therefore visible to structural
  mechanics such as partial counter-charm suppression.
* **`certifiedBaseManaCost` is a function of the certified trajectory and the
  active `formulaLength` — never of codebook meaning.** Within a fixed grammar,
  flipping a key between meaningful and noise cannot move it (§7.4).
* **Persisted inscription identity is leyline-independent.** `SpellAsset
  .manaCost`, `behaviouralKinKey`, kin stacking and heraldry are all derived
  inscription-side under the ordinary structure and are not redefined by mutable
  interpretation.

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

> **As-built, 2026-09-04.** Half of that parenthetical was closed by §7.4 and is
> no longer an open question: **noise formulas always count.** The cost is a
> function of the certified trajectory and the active `formulaLength` alone —
> `L` moving the chunk count is the *only* way a leyline reaches it, and that is
> ratified because a different `L` is already a different `leylineConfigHash`.
> Slice D's `semanticsOf` prices the raw structural list on the line **before**
> any interpretation runs, so the coupling is closed structurally rather than by
> convention.

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
  **As-built (R-6):** that is the accepted outcome, not a bug to fix. Both sites
  deliberately keep the ordinary length — inscription has no leyline — so the
  persisted number, and `behaviouralKinKey` / kin stacking / heraldry derived
  from it, stay leyline-independent. A proof-backed cast has been priced from
  `CertifiedCast.baseManaCost` rather than this field since M4.22, so nothing
  reads it for money.
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

> **As-built amendment, 2026-09-04 (Slice D).** Two rows of the table above have
> moved. `wild_magic_preview.dart` now derives through `IncantationLexicon`, so
> it is leyline-correct rather than merely proof-correct — a preview must not
> promise a trigger the cast cannot fire. `expectedRecitalSlots` (and its UI
> twin `battle_screen.dart:_expectedElementCount`'s consensus counterpart)
> follows the active grammar in-match.
>
> **Every other row is unchanged and still assumes L=3, a fixed dictionary and
> no noise.** The divergence flagged above is therefore still open, and is now
> enumerated as Slice F's inherited scope (§13). The final paragraph still
> holds: `LeylineConfig.mutable` has zero callers in `lib/`, so mutable
> interpretation is reachable from the engine and from tests but not from the
> app — which is exactly what makes deferring the display work safe.

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

> **As-built, 2026-09-04.** The forecast held exactly. Rows 1–3 shipped with no
> version movement (Slices A/B/C). Row 4 shipped as Slice D and moved
> `kBattleEngineVersion` **12 → 13** and nothing else: protocol stayed 7 —
> `LeylineConfig` has carried `mutableMagic` and `formulaLength` on the wire
> since its own first slice, and no framing changed — and ruleset stayed 3 with
> circuits and VK untouched. Rows 5–7 (Summon, Armor, the picker) are not
> started.

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

### Slice B — `LeylineCodebook` derivation, unused ✅ **DONE + RATIFIED 2026-09-03**

Implemented as `lib/battle/models/leyline_codebook.dart` +
`test/battle/models/leyline_codebook_test.dart` (33 vectors) +
`scripts/gen_leyline_codebook_vectors.py` (the independent second spelling).
Full suite 2413/2413 green, replay corpus zero deltas, analyzer clean, engine 12
/ protocol 7 / ruleset 3 / VK untouched. **Nothing in `lib/` imports it** — the
only importer is its own test.

**R-1 … R-4 are RATIFIED as implemented (Soren, 2026-09-03).** The vectors in
`leyline_codebook_test.dart` are now the permanent record: changing any pinned
literal is a breaking consensus change requiring a `lexiconVersion` bump, not a
test update.

Ratified alongside them:

* the R-2 rounding rule stands exactly as written;
* **no `meaningfulCount >= 16` floor** — not now, not implicitly later;
* the 999‰ / zero-meaningful vector **stays**. An all-noise codebook is a valid
  result of the construction primitive. Whether a *live* Mutable Leyline may
  use a config that derives zero meaningful keys is a later
  configuration-validity / gameplay ruling, deliberately **not** part of Slice
  B's arithmetic — do not resolve it by editing this rounding rule;
* `IncantationCodebook.derive` rejecting ordinary configs;
* effect-order hashing **and** its deterministic tiebreak use the pinned
  `kIncantationEffectCode`, never `EffectKind.index` or declaration order (see
  below).

#### R-1 — permutation: sort-by-hash (audit §5.2 candidate B) ✅ ruled

`score(entry) = SHA-256(preimage)`, entries sorted ascending by
`(score, canonicalPayloadBytes)`. Preimage:

```
uint8(len(domainTag)) ‖ ascii(domainTag)
uint8(lexiconVersion)
leylineConfigHash[32]        // RAW bytes, not the 64-char hex text
uint8(streamTag)             // 0x01 key order, 0x02 effect order
uint8(len(payload)) ‖ payload
```

Chosen over a `HashRng` Fisher-Yates because `List.shuffle`'s algorithm is a
Dart SDK detail, not a specification — a Python/Rust/Noir re-implementation
would have to reproduce its draw order and rejection sampling exactly. A
per-entry score has no such coupling, is order-independent by construction, and
each entry's rank is independently verifiable (pinned by a test that recomputes
every rank from scratch as "how many entries sort before me").

Keyed on `leylineConfigHash` rather than a re-serialisation of the config
fields: that value is already vectored, already binds all five fields including
the normalized seed, and is already what Wild Magic v2 consumes — so a codebook
and the Wild Magic under it can never disagree about which leyline they are in.
`lexiconVersion` is emitted redundantly, mirroring `LeylineConfig`'s layout.

#### R-2 — permille → count: round-half-up on the NOISE count ✅ ruled

```
noiseCount      = (totalKeyCount * noiseDensityPermille + 500) ~/ 1000
meaningfulCount = totalKeyCount - noiseCount
```

Noise is the quantity rounded because noise density is the tunable ruleset
parameter (§5); meaningful is the remainder so it cannot drift from it.
Round-half-up rather than floor/ceil because it reproduces §5's ratified table
exactly at every supported length (64/32, 256/128, 1024/512) and because floor
and ceil each bias systematically. Integer arithmetic throughout, never
`(x / 1000).round()` — a double's rounding at an exact `.5` is a platform
property, and `.5` is what 500‰ produces at every odd total. Largest
intermediate is `1024 × 999 = 1_022_976`, exact on every platform including
web doubles.

**OPEN SUB-QUESTION, flagged not invented:** 999‰ at L=4 rounds to 64 noise / 0
meaningful — an all-noise leyline. `LeylineConfig` rejects 1000‰ for exactly
that reason, and rounding reaches the same place from 999‰ at the smallest key
space. A floor (e.g. `meaningfulCount >= 16`) would be a **new consensus rule
that no plan states**, so it was NOT added. The degenerate case is pinned by
vector and handled without crashing. If a floor is wanted, it is one line plus
a vector change.

#### R-3 — allocation: round-robin over the derived effect order ✅ ruled

Meaningful entry at derived rank `i` → `effectOrder[i % 16]`. Chosen over
contiguous blocks because it is self-balancing at *every* count (per-effect
counts differ by at most one by construction, with no remainder special case),
because it degrades correctly below 16 meaningful keys where blocked allocation
divides by zero, and because the adjacency it creates is adjacency in the
*permuted* key order — which is already pseudorandom, so it exposes no
structure a player can observe.

#### R-4 — remainder bias, and the domain tags ✅ ruled

The sixteen effects are themselves hash-sorted, by the same primitive under
`streamTag = 0x02`. The `meaningfulCount % 16` effects that receive an extra key
are therefore a prefix of a *per-leyline* order, not of the fixed effect codes.
Without this, Blast and Barrier would own an extra key under **every** leyline
at **every** non-divisible density — a permanent, discoverable,
leyline-independent bias in a system whose premise is that nothing carries over
between leylines. Hash-sorted rather than rotated by a derived offset: a
rotation preserves the fixed cyclic adjacency, so learning where one leyline's
order starts reveals the whole order.

Domain tags are §4/§8/§9's literal strings, uint8-length-prefixed like every
other tag in the codebase:

* `Runewright/Leyline/v1/Incantation`
* `Runewright/Leyline/v1/Summon` — **pinned, unused**
* `Runewright/Leyline/v1/Armor` — **pinned, unused**

#### Also settled in passing

* **Key alphabet:** the four elements in the circuit's rule-index order
  (1 Fire, 2 Air, 3 Water, 4 Earth), **neutral excluded**. Justification is not
  aesthetic: `FormulaTracker.step` guards all three of its commit rules with
  `zone != null`, so a neutral or tied generation commits nothing and a neutral
  can never appear in a trajectory chunk. §3's `4^(L-1)` tail space is therefore
  correct as written. Enumeration is base-4, most significant element first.
* **Effect codes:** `kIncantationEffectCode`, explicit 0..15 matching today's
  declaration order — pinned rather than `EffectKind.index` for the same reason
  `kWildMagicEffectCode` is, since these bytes enter a hash preimage and a
  cosmetic enum reorder must not reroll every dictionary.

  **Ratified requirement, both halves:** the pinned code is the effect's
  identity in the scoring **payload** *and* in the sort's **tiebreak**.
  `EffectKind.values` appears in `deriveEffectOrder` only as the enumeration
  source, and cannot reach the result — the tiebreak is total over sixteen
  distinct codes, so position depends solely on an entry's own score and own
  pinned code. `List.sort`'s instability is therefore harmless, and feeding the
  sixteen effects in any order yields the same permutation (pinned by a test
  that rebuilds the order from a reversed input).

  **This guard is currently invisible, which is why it is written down twice.**
  Today `incantationEffectCode(kind) == kind.index` for all sixteen, so a
  regression to `.index` would move no byte and fail no vector. A dedicated
  test asserts that coincidence explicitly so that reordering `EffectKind` —
  a legitimate cosmetic edit — fails there first and sends the reader to
  `deriveEffectOrder`'s header. Fixing that failure means deleting the
  assertion, never touching `kIncantationEffectCode` and never moving the
  vectors.
* **Noise representation:** a sealed `IncantationMeaning` with
  `IncantationEffect(kind)` and `IncantationNoise()`. Rejected: `EffectKind?`
  (a null that means something specific is a comment, not a type, and Slice C
  has four consumers to teach); a seventeenth `EffectKind` member (sixteen is
  load-bearing — §5's counts, the 4×16 table, the wire codec's totality); a
  `bool isNoise` beside a kind (two fields that can disagree). Sealed gives
  Slice C's consumers an exhaustive `switch` the analyzer enforces.
* **`derive` throws on an ordinary config.** Ordinary play's sixteen tails are
  the fixed `effectKindFromPair` table; a derivation would produce a
  *permutation* of it, so a caller that forgot to check `mutableMagic` would
  silently rekey every existing spellbook. There is no flag to force one.

#### Independent verification

`scripts/gen_leyline_codebook_vectors.py` is a from-scratch implementation
written against the documented byte layout, not transcribed from the Dart. It
recomputes `leylineConfigHash` from scratch too — and **reproduces
`leyline_config_test.dart`'s five pinned hashes exactly**, which is a free
second attestation of the Slice 1 layout. Every literal in the Dart test is that
script's output. It is a dev tool: nothing at runtime or in `flutter test`
shells out to Python.

#### Original plan

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

### Slice C — noise-capable formula representation, ordinary-only ✅ **DONE 2026-09-03** (`09a7f61`)

Shipped as `lib/battle/models/incantation_meaning.dart` +
`test/battle/models/incantation_meaning_test.dart`. Full suite 2442/2442 green,
replay corpus zero deltas, analyzer identical to baseline, engine 12 / protocol
7 / ruleset 3 / VK untouched. No production caller derived a codebook, imported
`leyline_codebook.dart`, or read `mutableMagic` at the end of this slice — all
three asserted by source-scanning posture tests.

#### As-built — what changed from the plan

**The plan's "`ParsedFormula` grows a nullable effect" was NOT built, and
should not be revived.** §13's Slice B entry had already rejected `EffectKind?`
on its own terms; Slice C took that further and made the *formula* and its
*meaning* separate values rather than one value with an optional field. The
distinction the slice actually established is:

```
complete structural formula   !=   meaningful incantation effect
```

Concretely:

* **`IncantationMeaning` / `IncantationEffect` / `IncantationNoise` were
  extracted** out of `leyline_codebook.dart` into
  `lib/battle/models/incantation_meaning.dart`, verbatim, and re-exported from
  the codebook so every existing importer and every Slice B vector saw exactly
  what it saw before. The move is a **dependency boundary**: ordinary
  production code must be able to *name* a meaning without importing the
  codebook and thereby coming within reach of `IncantationCodebook.derive`.
  That extraction is what made Slice D's posture guards expressible.
* **`ordinaryIncantationMeaning(effectType1, effectType2)`** wraps
  `effectKindFromPair` and nothing else, and returns `IncantationEffect` — not
  `IncantationMeaning`. The narrowed return type *is* the statement that
  ordinary interpretation is total: a caller holding the result needs no noise
  branch and the analyzer says so. It takes only the **tail**; affinity is not a
  parameter, because §3's protected invariant is that a leyline may change what
  a tail means and never what an affinity means.
* **Three eligibility predicates** over one exhaustive switch —
  `incantationManifestsEffect`, `incantationContributesAffinity`,
  `incantationContributesWildMagicEligibility` — one per row of §7.4's ratified
  table, named separately because three different consumers read three
  different rows.
* **`meaningfulIncantationCount`** exists precisely so the two counts have
  different names. It is documented as *not* the number anything prices from.

**No wrapper type was added.** Nothing consumes affinity + meaning as a pair,
and `chunk[0]` is in hand at every call site, so the predicates take a meaning
alone rather than a class whose only callers would be its own tests.

**Item 5 of the original plan below ("Unresolved: the `effectCount` ruling") was
already closed** by §7.4 before this slice started — see R-5/R-6 in §14. Nothing
in Slice C touched `certifiedBaseManaCost`.

#### Original plan *(superseded in part — see as-built above)*

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

### Slice D — wire mutable Incantation behaviour + the engine gate ✅ **DONE 2026-09-04** (`3f4f08b`)

The first slice that changes what a duel does. Shipped as
`lib/battle/engine/incantation_lexicon.dart` + two new test suites
(`incantation_lexicon_test.dart`, `mutable_incantation_resolution_test.dart`),
with seven production files threaded. Full suite 2488/2488 green, replay corpus
zero deltas with no golden regenerated, analyzer identical to baseline.
**Engine 12 → 13; protocol 7, ruleset 3, circuits/VK unchanged.**

#### As-built — the seam

The plan said "chunk at `formulaLength`, look the tail up in the codebook".
What that required, and what was built:

* **`IncantationLexicon.of(LeylineConfig)`** — one object, built once from the
  match's canonical config, answering the two leyline-dependent questions the
  engine has: `formulaLength` (structural) and `meaningOf` (semantic). Both live
  on one object deliberately: a build that chunked at one length while
  interpreting under another leyline's dictionary would resolve a spell no
  device agrees with, so there is one constructor, it takes the whole config,
  and it cannot be assembled from halves.
* **Derivation happens once per deterministic context** — `late final lexicon`
  on `DeterministicResolution`, which is itself `late final` on `TurnLoop`.
  `TurnLoop` passes `_resolution.lexicon` into `PeerCastVerifier` rather than
  letting it derive a second one, so a match cannot end up holding two codebooks.
  No cache: ~1040 SHA-256s once per match is not worth a consensus hazard, and a
  cache keyed on less than the full canonical config would be one.
* **`ParsedFormula` gained its structural `tail`** (`chunk.sublist(1)`), which is
  the codebook key under a mutable leyline and the `effectKindFromPair` argument
  pair under an ordinary one. `effectType1`/`effectType2` now **throw** on a
  non-ordinary tail instead of returning `tail[0..1]` in the wrong role — a
  mutable formula must reach the codebook or reach nothing.
* **`CertifiedCast.formulas` stays structural.** Certification certifies
  structural spell facts; interpretation is applied downstream by the lexicon.
  No codebook-dependent meaning is baked into a certificate.
* **Interpretation follows segmentation, at three consumers only.** The
  resolution loop keeps one iteration per *structural* formula and `continue`s
  past noise; `pureAffinityOf` and `WildMagic.eligibleElements` receive
  `lexicon.meaningfulOf(...)`. `EffectResolver.resolveKind` takes an
  already-interpreted kind and has **no noise case at all**, so there is no
  no-op descriptor for anyone to apply by accident.
* **`expectedRecitalSlots` follows the active grammar in-match**, and became an
  instance method to do so. Required by its own contract — never ask a caster to
  recite words the cast discards — since the residual is a different length
  under a mutable grammar. It is the *structural* prefix: a noise formula is
  still recited, because §7.4 says the chunk is consumed like any other.
* **`parsedFormulas` became an instance method** reading `lexicon.formulaLength`,
  so the certified path and the authored/local fallback cannot cut the same
  element sequence differently. `SpellAsset.formula` is a flat name list, so
  persisted metadata already represents mutable formulas faithfully — **no
  migration and no new persistence format were needed.**

#### As-built — the mana gate, investigated before any production edit

Activating lengths 4–6 **does** move `certifiedBaseManaCost` for an identical
certified trajectory: `effectCount` is `max(0, formulas.length - 1)` and the
chunk count is `committed.length ~/ L`. That is the case §7.4 ratifies — cost
moves with the **grammar**, which is already a different `leylineConfigHash`.
The forbidden case (meaning moving cost) is prevented *structurally*, not by
convention: `semanticsOf` prices the raw structural list on the line **before**
any interpretation happens. Within a fixed grammar, flipping a key between
meaningful and noise cannot change certified base mana.

Persisted identity is untouched because inscription has no leyline:
`main.dart:_computeManaCost` and `spell_asset_integrity` both keep the ordinary
length, so `SpellAsset.manaCost` → `behaviouralKinKey` → kin stacking →
heraldry remain leyline-independent. §7.3's three feared consequences all
resolved to "no change".

#### As-built — a ratified consequence, and an open balance concern

**A mutable grammar can make an existing spell structurally void.** A
three-element certified trajectory has *no complete formula* at lengths 4–6:
no effect, no affinity, no wild magic, and `effectCount` 0. This is correct
under the ratified rules — it falls straight out of §7's chunking and §16's
lengths — and it is pinned by test rather than smoothed over. It surfaced as a
real failure in `wild_magic_preview_test`, whose fixture spell is exactly three
elements.

**This is an engine consequence, not an implementation defect.** It is recorded
here as an **open balance question**: long grammars disproportionately punish
short spells, and every existing spellbook is full of them. Whether that is
desirable — and whether noise density or length bounds should compensate — is a
design call for playtest, not something to patch in the engine.

#### As-built — Wild Magic, untouched

No file under `wild_magic*` was edited. The v2 preimage's trajectory field is
the flat committed sequence, which is leyline-invariant because
`FormulaTracker`'s three commit rules are length-independent; its cost field is
the structural price. **Only *which formulas are eligible* changed**, and that
is a filter applied to `triggersFor`'s `formulas` argument — exactly what §7.2
predicted would suffice. The hash, the 3×4 table, `kWildMagicEffectCode`, the
event RNG and Slice 7 coalescing are all as they were (R-7).

#### As-built — what was deliberately NOT done

* **The two-device hardware pass in item 8 below has not been run.** It is still
  the right gate for this slice and remains outstanding. It is cheap to defer
  today only because no UI can construct a mutable config (below), so no
  hardware duel can currently *be* mutable.
* **`duel_setup.dart` / §10.3 compat hardening was not touched.** R-9 is still
  open, and the flat-`communitySeed` fallback is unchanged.
* **No mutable picker exists.** `LeylineConfig.mutable` still has zero callers
  in `lib/`, so mutable interpretation is reachable from the engine and from
  tests but not from the app. That is Slice F, and it is what keeps this slice's
  blast radius honest.
* **Player-facing display was left ordinary on purpose.** See Slice F.

#### Original plan *(shipped, with the seam elaborated above)*

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

> **Lettering note (2026-09-04).** The slice actually built and shipped as
> "Slice E" is the **player-facing activation** slice described under *Slice F*
> below, not this one. The build brief renumbered; this document keeps its
> original letters so the R-8/R-9 ledger and §13's cross-references stay valid.
> Read "Slice E" in commit messages and in `incantation_display.dart` as
> "the UI slice, §13 Slice F here". Summon/Armor rekeying — the entry below —
> **remains unbuilt and unruled (R-8)**.

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

#### Inherited from Slice D — the exact list

Slice D wired the engine and deliberately left every player-facing surface
interpreting ordinarily. Those surfaces are **currently unreachable under a
mutable leyline** — no production path constructs a mutable `LeylineConfig` —
which is what makes deferring them safe rather than merely convenient. Each
would mis-render the moment a picker exists:

* **`formulaEffects` / `formulaEffectLabels`** (`effect_kind.dart`) — one
  ordinary effect per complete triplet, read by the spell card, library,
  sightings and battle screen. It must **not** be globally redefined as
  "meaningful effects only": several consumers depend on structural
  correspondence, and what a noise position should *look like* is an unmade
  design decision.
* **`formulaTripletKind`** — live inscription (`formula_bar.dart`) and
  `RecipeBook` discovery (`main.dart:_recordNewFormulas`). Discovery is
  **persisted state**, so leyline-scoping it is a storage decision, not a
  rendering one.
* **`spell_card_painter.dart`'s affinity histogram** — counts `chunk[0]` of the
  raw stored list with no interpretation, so under a mutable leyline it would
  count noise-formula affinities as effect-eligible. Its Slice A input quirk
  (raw-string segmentation **before** invalid-name filtering) is deliberate and
  must be preserved; do not "clean it up" while fixing the interpretation.
* **Out-of-match practice teaching** — `PracticeFormula.fromSpellFormula` drills
  at length 3, while `expectedRecitalSlots` now follows the active grammar
  in-match. A mutable duel therefore expects a different word count than the
  drill taught.
* **Final noise presentation** — how a noise formula reads on a card, in the
  library, and in the recital. Undesigned, and deliberately so: Slice D kept the
  engine correct and left the visual language open.
* **`spell_view_screen.dart:154`** — the pre-existing `(committed.length - 1) ~/
  3` mana readout bug recorded in §13.2, still unfixed and still display-only.
* **`recipes_screen.dart`** — teaches the fixed 16-pair table, which under a
  mutable leyline is unknown by design.

`wild_magic_preview.dart` is **already done**: Slice D routed it through the
live lexicon, because a preview that ignored noise would promise triggers the
cast cannot fire.

#### As-built — 2026-09-04 (shipped as "Slice E"; see the lettering note above)

**Versions unchanged: engine 13, protocol 7, ruleset 3, circuits/VK untouched.**
Nothing here moves a deterministic output — it exposes an already-supported
config and corrects what the screen *says* about it. Per §11, that is not an
engine bump.

**The activation boundary is solo practice, and only solo practice.**
`LeylinePicker` (`lib/ui/widgets/leyline_picker.dart`) is the one production
caller of `LeylineConfig.mutable`, and it is mounted only on
`solo_practice_settings_screen.dart`.

**Why not the duel host screen — a fairness coupling, reported rather than
patched.** The guest chooses its chapter in `duel_join_chapter_screen.dart`,
*before* connecting, and first sees the host's leyline inside `runDuelSetup`
step 3. The mDNS advertisement carries `displayName` + `DeviceCapabilities` and
no `MatchConfig`, so there is nowhere earlier to surface it without a discovery
or protocol change — which this slice excludes. A host free to pick length 6
could therefore render a guest's entire chapter structurally void with no
warning and no way out. Solo has no guest and so has none of this. **Putting
the picker on the host screen requires the leyline to be visible before chapter
lock** (advertise it, or add a guest confirm step after config receipt) **and
should close R-9 in the same change.**

**Interpretation has exactly one UI-facing entry point.**
`lib/spells/incantation_display.dart` — `incantationViewsFor(formula, lexicon)`
→ one `IncantationFormulaView` per **complete structural formula, noise
included, in order**. Widgets consume it; no widget derives a codebook, and
three posture tests now say so (`no UI file can see the codebook`, `the
ordinary formula length is hardcoded only where ruled`, `the display model is
the only lexicon-aware UI helper`).

**Noise reads as the word `Noise`** — a muted, italicised rules line with its
own one-line description. Not a blank, not a seventeenth `EffectKind`, not an
ordinary label. `EffectKind` is untouched.

**Surfaces made lexicon-aware** (each takes a lexicon; all default to
`IncantationLexicon.ordinary`, so ordinary play is untouched):

* `spell_card_painter.dart` — the **rules box only**, via `_CardFrame.lexicon`,
  fed from the `activeWildMagicContext` builder that already wrapped the card.
  A mutable card also captions which grammar the reading was taken under.
* `battle_screen.dart` — `spellNeedsConveyorDirection` (effects-only, category
  A), the cast-tray summary (structural, category B), and
  `_expectedElementCount`, which **was a real bug**: it hardcoded 3 while
  `expectedRecitalSlots` cut at the active grammar, so a length-5 match would
  have asked the caster for more words than it scored.

**Deliberately left ordinary, each for a stated reason:**

* **The card's heraldry** — `frameColorShares` and `elementSymbolsFor`, both
  fed by `_formulaAffinityCounts`. **Ruling: identity is not leyline-dependent.**
  A library that re-skinned itself under every host's leyline would be a worse
  lie than the one this slice fixes. The noise-affinity correction the audit
  owed lands in the rules box instead, where an affinity is *claimed* rather
  than merely drawn. Pinned by test across all four leylines. The Slice A
  raw-string segmentation quirk is preserved untouched.
* **`formulaEffects` / `formulaEffectLabels`** — not mutated. Their in-match
  consumers moved to `incantationViewsFor`; they remain the ordinary
  out-of-match helper, and now serve as an independent oracle in the ordinary
  -invariance test.
* **`formulaTripletKind`** — still ordinary-only, still called only from
  `main.dart`'s `RecipeBook` discovery (inscription, no leyline) and
  `formula_bar.dart`. The bar now **fails closed**: a group of any length but 3
  is drawn structurally with no effect name, because `formulaTripletKind`'s
  `assert` is stripped in release. Not renamed — the name is accurate.
* **Practice** — `PracticeFormula.fromSpellFormula` stays at length 3. Practice
  is reachable only from the library and the vocabulary screen, neither of
  which has a match or a leyline, so ordinary drilling is general practice
  rather than a false claim. A dedicated mutable practice mode is deferred.
* **`recipes_screen.dart`** — reachable only from Rune Craft (`main.dart`),
  which has no leyline. Teaching the fixed table out of match is correct.
* **The library** — has no active leyline (the context is primed from the
  device's own seed as `LeylineConfig.ordinary`), so it reads ordinarily, and
  persisted `SpellAsset.formula` / `manaCost` / `behaviouralKinKey` / heraldry
  are untouched per R-6.
* **`spell_view_screen.dart:154`'s mana readout** — the pre-existing §13.2 bug,
  still unfixed. Out of scope, and unrelated to leylines.

**Structurally void spells stay selectable.** No filtering, no disabling, no
balance rule — the strong default. The card names the condition instead: *"No
complete formula under `rivendell 4` — this leyline reads 4 elements to a
formula, and this spell has too few. It will cast, and do nothing."* The cast
tray says the same in one line. There is no fallback to the ordinary reading,
and a test asserts the ordinary effect name appears nowhere on such a card.

**Counter-charm suppression** is unchanged and now *pinned*: `applySpell`
skips leading **structural** formulas, so a noise formula consumes a
suppression slot. Four regression tests, including the one that states it
directly — two casts with equally many meaningful formulas and the same
suppression count resolve differently purely because of where the noise sits.
**Consequence for UI copy: "1 formula countered" does not mean "1 effect
cancelled."**

**On-screen pass (Linux desktop, 2026-09-04).** Ran at 1332x819, 1100x850 and
390x800 (narrower than the S25's ~384dp, so the narrowest layout this ships to
is covered). The picker, a real in-battle void card, and the rules box at
ordinary/4/5/6 were all inspected. **Two visual defects were found and fixed:**

* **`IntStepperRow` wrapped the three-digit noise value** — 500 rendered as
  "50" over "0". Its value box is a fixed 48px, sized for the one- and
  two-digit values every previous caller had. Fixed by an opt-in `valueWidth`
  parameter defaulting to the old 48, so HP, grid radius and formula length are
  pixel-identical and only the noise row opts wider.
* **The two leyline option cards had ragged heights** on a narrow phone, where
  their captions wrap to different line counts. Wrapped the row in
  `IntrinsicHeight` so the pair reads as one either/or choice.

Both are pinned by test — the noise one by measuring the value's HEIGHT against
the single-digit formula-length value, so it keeps testing the wrap rather than
the width constant.

Deferred, acceptable: under a leyline where several formulas are noise the
rules box repeats the full noise sentence per line (two identical paragraphs at
`rivendell 4`). Honest — they are genuinely two separate inert formulas — but a
shorter repeat line is worth considering if playtest finds it noisy.

**Wild Magic** — no file touched. Slice D had already routed the preview
through the lexicon; the audit confirmed noise-derived affinities cannot appear
as eligible, and hash/table/RNG/coalescing are untouched (R-7).

---

## 14. Stop conditions reached

Per the audit's own stop rules, implementation was not to begin until the
following were ruled. Each maps to a listed stop condition.

**Update 2026-09-03:** R-1 … R-4 **RATIFIED** and pinned by vectors (§13,
Slice B).

**Update 2026-09-04 (as-built):** R-5, R-6 and R-7 are **RATIFIED and shipped**
— R-5/R-6 by §7.4's noise-does-not-move-mana ruling, R-7 by §8's
`wildMagicEffectFor`-is-not-rekeyed ruling. Slices C and D are complete on that
basis.

**Update 2026-09-04 (Slice E):** neither R-8 nor R-9 was required by Slice E,
and neither was closed. The earlier "R-8 blocks Slice E" wording assumed a
Slice E that activated *every* domain; the slice as scoped activates
Incantation only, and the posture test still forbids Summon and Armor from so
much as importing the lexicon. **R-8 stays open, and is no longer a blocker for
anything that has shipped.**

**R-9 is not reachable by the activation Slice E shipped, for a reason worth
recording.** §10.3's fear is a same-engine peer whose missing `leyline` object
silently degrades a mutable match to ordinary. That needs a peer with a leyline
opinion of its own. The duel path has none: the host authors the whole
`MatchConfig` and the guest adopts it verbatim (`runDuelSetup` step 3 —
`receiveHostMatchConfig`), so there is no guest-side intent to downgrade *from*,
and a host that omits its own leyline object has simply chosen ordinary. Slice
E's picker is on the **solo** screen, which crosses no wire at all. **R-9
becomes live the moment a mutable config can travel — i.e. the moment the host
screen gets the picker — and it should be closed as part of that change, not
before it.** See §13's Slice E entry for the fairness coupling that is the real
reason the host screen did not get it.

| # | Ruling | Stop condition |
|---|---|---|
| R-1 | The codebook permutation algorithm (candidates in §5.2) | ✅ **RATIFIED 2026-09-03** — sort-by-hash |
| R-2 | The meaningful-tail → effect allocation rule (round-robin vs. blocked) | ✅ **RATIFIED** — round-robin (numbering here follows §13's Slice B, which splits rounding from allocation) |
| R-3 | The remainder rule when `M` is not divisible by 16, and the permille→`M` rounding | ✅ **RATIFIED** — round-half-up on noise, no floor; remainder to a prefix of the derived effect order |
| R-4 | Exact domain-tag bytes and length-prefixing | ✅ **RATIFIED** — §4/§8/§9 literals, uint8 length prefix |
| R-5 | Does `effectCount` (and therefore certified base mana cost, and therefore Wild Magic's preimage, and therefore `behaviouralKinKey`) count noise formulas? | ✅ **RATIFIED 2026-09-03 (§7.4)** — **yes**, every syntactically complete chunk counts, noise included. Cost is a function of the certified trajectory and the active `formulaLength` alone, never of the codebook. Shipped in Slice D. |
| R-6 | What happens to persisted `SpellAsset.manaCost` and kin keys under a mutable leyline | ✅ **RATIFIED 2026-09-03 (§7.4)** — **nothing**. Inscription has no leyline, so persisted cost, `behaviouralKinKey`, kin stacking and heraldry stay inscription-side and leyline-independent. Shipped in Slice D. |
| R-7 | Is the Wild Magic 3×4 → effect table itself rekeyed, or is the config hash sufficient? (§8) | ✅ **RATIFIED 2026-09-03 (§8)** — the config hash is sufficient; the table is **not** rekeyed. Slice D edited no wild-magic file; only *which formulas are eligible* changed. |
| R-8 | Summon and Armor pattern-space mapping (§8 of the plan defers this explicitly) | ⛔ **OPEN — and no longer blocking.** Slice E activated Incantation only; Summon and Armor remain ordinary and the posture test forbids them the lexicon entirely. A ruling is still required before any mutable Summon/Armor code. |
| R-9 | Should the legacy flat-`communitySeed` fallback become an error once mutable is live? (§10.3) | ⛔ **OPEN — gated on the HOST picker, not on mutable being live.** Slice E's picker is solo-only, so no mutable config crosses a wire and there is no downgrade to guard: the guest adopts the host config verbatim and holds no leyline opinion of its own. Close this in the same change that puts a picker on `duel_host_settings_screen.dart`. |

**Not** ambiguous, and therefore **not** rulings: formula chunking is fully
specified (§7 — disjoint, non-overlapping, trailing remainder discarded, affinity
is chunk[0]); noise semantics are fully specified (§6); the wire gate is
answerable from the code (engine bump, no protocol bump).
