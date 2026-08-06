# Wild Magic — Implementation Plan

*Target implementer: Sonnet. Written 2026-07-29 on `feature/practice-mode`. Source of
design truth: `docs/runewright_design_v3_0.md` §Wild Magic System (L582–617), §Spell Effect
Hash (L405–425), §Formula Structure / Spell Affinity (L195–219), and the resolution-order
rule at L746. Seven decisions were ratified by Soren — see §2. No design questions remain
open; the only unbuilt dependency is the forced-reveal protocol message (§9.5). The seed-hash
formula (§4.1) is simplified from the design doc's literal text — see §13 item 3.*

*Read `CLAUDE.md` first. Nothing here touches the CA, the circuit, or `stepper.dart`, so
**no `RULESET_VERSION` bump is required** (see §11 for why, and what it does change).*

---

## 1. What this builds

Wild magic is the second, parallel effect system: a spell's public proof outputs are hashed
with a community seed word, the resulting hex string is scanned for trigger patterns, and a
match fires a **global, symmetric, double-edged** effect that ignores tile targeting
entirely. Twelve effects (3 trigger rows × 4 elemental flavors) plus the engine that
derives, scans, and resolves them.

Two properties make this system what it is, and everything below is in service of them:

- **It is a fixed property of the rune.** The hash has no per-cast entropy in it (§2.3), so
  a spell either always fires its wild magic or never does. That is what makes hash-divining
  at inscribe time real, and what makes a community's seed word into "home-turf advantage."
- **It is symmetric.** Wild-magic effects hit the caster too. The skill is being *positioned*
  to benefit from a shared effect, not aiming it. Every effect in §8–§10 must be implemented
  to affect **all** players, not just the opponent — resist any instinct to add a
  "except the caster" clause.

### Explicitly out of scope

- **Void wild magic.** Design §Eligibility: *"Void effects entirely removed for now."* The
  existing `EffectResolver.tryResolveWildMagic` stub is built on the opposite premise
  (zero-formula = void eligibility); that stub's contract is **wrong** and gets replaced,
  not extended. See §4.3 — under the ratified eligibility rule a zero-formula spell has no
  eligible element and therefore no wild magic, which lands on the design's intent for free.
- The void mana-cost formula (`10 × 1.25^(tiles−1)`) and the tile-gated power cap. Both
  exist in the design doc but are void-specific, and void is out.
- Expanding the effects table. It is a `[TODO — playtest]` stub by design; ship the 12.
- Any change to the circuit, `CIRCUIT_IO.md`, or the golden corpus.

---

## 2. Ratified decisions (do not re-litigate)

### 2.1 Trigger patterns are **literal**, and the element picks the column

The design doc contains two incompatible readings. §Trigger Patterns says repeat digits are
*"assigned per element, no overlap"* and an ascending run's *"first numeral must be the
element's designated trigger"* — which implies each element owns its own digits. But the
effects table's row labels (`000`, `111`, `012345`) are literal digits shared across all
four element columns.

**Ratified: the table is literal.** The hash is scanned for the same three patterns
regardless of element; **eligibility selects which column(s) of the table you read.** The
"no overlap" and "designated trigger" sentences in §Trigger Patterns are dead text from an
earlier revision and should be struck when the doc is next edited (§13).

Consequence worth understanding before you build: a perfectly balanced four-element spell
whose hash contains `000` fires **all four** Row-1 effects at once — Burning Hot *and*
Mountains *and* Mana Flood *and* Zephyr. That is intended; the design explicitly says a
balanced spell firing "up to four element wild-magic effects at once" is the reward for
perfect balance (§RESOLVED — Chaos column deleted). Your resolution loop must handle
1–4 effects per row cleanly and in a deterministic element order.

### 2.2 Eligibility = tally of **completed formula affinities**

Count the first-entry element of each completed formula. The most frequent element wins; on
a tie **every** tied element is eligible (this is the "wild magic specialist" archetype).
Not `border_activations`, not generations-dominant. Rationale: §Eligibility says "cumulative
across all **formulas**", and this reading reuses the certified `ParsedFormula` list
`TrajectoryParser.parse` already produces — no new certified surface.

### 2.3 The hash is deterministic per (spell, community seed)

Confirmed as designed. No per-cast randomness gates whether wild magic fires. Per-cast
entropy is used **only** to resolve an effect's internal randomness (which tiles, which
direction, which bookmark) — see §5.

### 2.4 Build all 12 effects, in three dependency-ordered phases

Phase 1 = engine + the four effects needing no new primitives. Phase 2 = new
terrain/movement primitives. Phase 3 = persistent global modifiers. Each phase is
independently shippable and testable. See §6.

### 2.5 Spontaneous Combustion gets its protocol message — built as a reusable primitive

The private-hand problem in §3.1 is real, and Soren ratified paying for the new mid-turn
reveal rather than cutting or redefining the cell: *"I think the cost is worth the effect."*

**Build it as a general primitive, not a Spontaneous-Combustion special case.** Soren's
stated intent is to reuse it — *"I might reuse it in other areas if other effects prove
unpopular in play testing; I might add a 'cast something at random from your hand' effect."*
So the deliverable is a named, reusable **forced-reveal-and-cast** mechanism (§9.5) that any
future effect can invoke with a count and a targeting rule, with Spontaneous Combustion as
its first caller. Do not bury the logic inside the wild-magic applicator's `switch`.

### 2.6 The seed hash stays over the proof's **public inputs** — proof-hashing evaluated and rejected

The question raised and closed on 2026-07-30: could the seed hash be taken over the **proof
bytes** instead of the public inputs, so that a grinder searching for trigger patterns would
have to generate a real proof (seconds + ~700 MB) per candidate instead of just running the
stepper (microseconds)?

**Measured, and rejected.** Full write-up in `docs/M4_findings.md`
(*"bb's UltraHonk prover is NOT byte-deterministic"*, 2026-07-30). Three findings:

1. **The prover is randomized.** Three proofs of one witness on the real `ca_v2_4_tier12`
   give three different byte strings. **Public inputs are byte-identical across all runs** —
   only the proof body varies.
2. **It is the ZK blinding, and we cannot opt out.** `noir-recursive-no-zk` proves
   byte-identically; `noir-recursive` (poseidon2, ZK) does not. `noir_rs`'s
   `settings_ultra_honk_poseidon2()` hardcodes `disable_zk: false` and the poseidon2 entry
   point exposes no override. Disabling ZK would leak the grid, which is the entire secret.
3. **So proof-hashing would decouple wild magic from grid design.** Re-inscribing one grid
   ~1,150 times (~4 s each on desktop, ~75 min total) would put any Row-3 effect on any
   already-perfect spell — undetectably, since `spellHashHex = Poseidon2(commitment, T)` is
   identical across re-rolls and a peer sees only a proof plus a Merkle root.

**Why public-input hashing is the stronger design, and the anti-grinder answer.** Hashing the
statement welds the wild magic to the *grid*. A grinder can find a trigger quickly, but the
grid they find is essentially random — its formulas, mana cost, and effects are whatever that
CA happens to produce. Getting a **good spell that also carries a trigger** means searching
the intersection, which is vastly rarer than either alone. That coupling is the real defense,
and proof-hashing is precisely what would remove it.

**The ratified mitigation is the community seed word, not a costlier hash.** Soren: *players
can use their local leyline seed word if they're worried about grinders showing up and
warping their meta.* Rotating the seed invalidates every previously ground trigger at zero
cost, and a grinder cannot start until the seed is announced. This makes §7.5 load-bearing
rather than decorative — see the note there.

Also rejected on the way: swapping SHA-256 for a memory-hard KDF (Argon2id) to tax the
search. It is ~60× weaker than proof-hashing was, and the seed-rotation lever is free.
**Keep SHA-256.**

### 2.7 The preimage is simplified to `commitment ‖ T ‖ seed` — border activations and trajectory dropped

Ratified 2026-07-30. Soren: *"I'm not sure why we're including trajectory... I'm happy so
long as the same grid with the same community seed run for the same number of turns will
always produce the same spell with both the same normal effects and wild magic effects."*

`border_activations` and the full `dominance_trajectory` are both pure, deterministic
functions of `(grid, T)` — no different from `commitment` itself in that respect — so
including them added preimage bytes without adding any distinguishing power. Dropping them
still satisfies the stated invariant exactly (same grid + T + seed ⇒ same hash, always) and
removes an array whose tier-padding/off-by-one handling was the fiddliest part of §4.1.
**`T` stays an explicit field regardless** — it is what actually guarantees kin-spell
disambiguation, not incidental variation in the CA's border output. See §4.1's ratified note
for the full reasoning and the updated preimage layout.

---

## 3. Assumptions I made — review these before building on them

These are calls I made to keep the plan unblocked. They are *not* ratified. Each is
individually cheap to reverse; flag any you disagree with rather than discovering it in
playtest.

| # | Assumption | Why |
|---|---|---|
| A1 | A countered or fizzled cast fires **no** wild magic. | Both paths already `return` before `_applySpell`; nothing was created, so nothing hash-derived should fire either. Free of charge — just don't add a hook upstream of the counter check. |
| A2 | Wild magic **does** fire on summon-mode casts. | It is hash-derived and parallel to the recipe path; a summon spell still has a certified trajectory and formulas. Requires firing it *before* `_applySpell`'s `if (spell.isSummon)` early return. |
| A3 | A row fires **at most once** per cast, using the **longest** qualifying occurrence in the hash. Multiple occurrences do not stack. | Otherwise a hash with `000` twice doubles a global effect for free, and bracket scaling stops being the only power axis. |
| A4 | Bracket steps = `runLength − minimumLength` (3 for rows 1–2, 4 for row 3). | Direct reading of "sequences continuing past the minimum 3 scale per the brackets." Row-3 effects have no bracketed values, so `bracketSteps` is computed but unused there — which is also why lowering row 3's minimum costs nothing. |
| A5 | **Mountains** walls the tiles adjacent to **every living wizard avatar** (not minions), skipping tiles that already carry a `TileEffect` and skipping occupied tiles. | "All adjacent cells" has no antecedent in the doc. Adjacent-to-everyone is the symmetric, board-wide reading consistent with §Design intent. Skipping existing terrain avoids a hidden destroy-terrain side effect. |
| A6 | **Statuesque**'s latch begins at the **end of the turn it fires**, so the triggering cast does not immediately break it. | The literal reading ("lost if they move or cast") would have the wild-magic caster break their own effect in the same instant, which is almost certainly not the intent. |
| A7 | **Rippling Reflections**' doubling re-applies **formula effects only** — a doubled spell does not fire its wild magic a second time. Its drift is clamped to `[0, 100]`. | Cascade containment. An unclamped drift also runs off the end of the scale after ~5 same-direction outcomes. |
| A8 | **Spontaneous Combustion**'s free cast is exempt from *every* on-cast global hook: it fires no wild magic, is not subject to Rippling Reflections, does not trigger Scattered Gusts, does not build or break the chain, and does not consume the spell from hand. | This is the load-bearing recursion guard. Without it, one Spontaneous Combustion can fan out into an unbounded cast cascade. |
| A9 | **Chasm** is a new `ChasmTile` that blocks movement but **not** targeting, and is not removable by other effects. | The doc explicitly says "no bearing on targeting" and "indestructible" — `ImpassableTile` blocks line-of-sight and is destructible, so overloading it is wrong on both counts. |
| A10 | **Chasm**'s line is one of the three hex axes through the origin, chosen uniformly from per-cast entropy (`q == 0`, `r == 0`, or `q + r == 0`). | "Bisects" means through the center; "randomly drawn" then only leaves the axis free. Gives a genuine bisection every time on a radius-4 board. |
| A11 | **Flying** (Updraft) ignores `ChasmTile`, `ImpassableTile`, `FloorIsLava`, `SlowTile`'s extra cost, `IceTile` sliding, and `ConveyorTile` pushes. | Mirrors the existing `SummonAbility.flying` / `ignoresTerrain` semantics already used for spirit minions, and `resolveTileEntry(flying: true)`. |
| A12 | **Ice sliding** continues in the entry direction, free of movement budget, until the next tile is out of bounds, occupied, or not an `IceTile`. | Mirrors `ConveyorTile`'s free cascading push, which is the closest existing precedent. |

### 3.1 The one thing that needs a new protocol message — approved, see §2.5

**Spontaneous Combustion cannot be implemented without a new protocol message.** The effect
resolves a random spell out of *each player's* hand. A player's hand contents are private:
`SPELL_DRAW_WIRING_PLAN.md` deliberately gives each client only a **position-only** mirror of
the peer's hand (`DrawSchedule`), never the grids, formulas, or proofs. So the local client
cannot resolve the peer's randomly-selected bookmarked spell — it does not have it, and
cannot fabricate it without desyncing.

The fix is a mid-Phase-5 reveal: the affected player transmits the selected spell with its
proof, verified through the same `_verifyPeerSpellCast` path as a normal cast. **Soren ratified
paying for this (§2.5).** Build it as a reusable primitive, not a one-off — see §9.5.

---

## 4. The contract

This is the consensus-critical part. Both clients must derive byte-identical results or the
per-turn state hash diverges and the match aborts. Specify it once, test it against fixed
vectors, and never let a second derivation path exist.

### 4.1 The seed hash

> **Naming trap:** `SpellAsset.spellHashHex` already exists and is `Poseidon2(commitment, T)`
> — a completely different value used for duplicate detection at save time. Do **not** reuse
> that name, that field, or that value. The new one is `wildMagicSeedHex`.

```
preimage =
    commitment                 // 32 bytes, big-endian — the raw Field bytes,
                               //   i.e. proof public-input field index 3
  ‖ uint8(T)                   // 1 byte, 1..48
  ‖ utf8(normalizedCommunitySeed)       // variable length, last field

wildMagicSeedHex = lowercase hex of SHA-256(preimage)    // 64 chars, no "0x" prefix
```

> **`[SIMPLIFIED — 2026-07-30]` `border_activations` and `trajectory` were in the design
> doc's literal formula and dropped here.** Both are pure, deterministic functions of
> `(grid, T)` — exactly like `commitment` already is — so hashing them adds preimage bytes,
> not entropy: they cannot distinguish two things `commitment` and `T` don't already
> distinguish. Confirmed with Soren: this preserves the invariant that matters —
> **same grid + same T + same community seed ⇒ same `wildMagicSeedHex`, always** — with a
> smaller, fixed-size preimage and one less array to get an off-by-one in. It does **not**
> reopen §2.6: the anti-grind coupling ("a grinder is stuck with whatever grid the trigger
> came on") is entirely `commitment`'s doing, not trajectory's.

Two encoding decisions you must not quietly change:

1. **`T` stays an explicit field — it must never be inferred from trajectory length or
   from `border_activations`.** This is what guarantees kin-spell disambiguation (two
   inscriptions of the same grid at different T get independent rolls) even in the edge
   case where the CA's border activity has saturated and produces identical
   `border_activations` — or an identical trailing trajectory — for two different T values.
   Pin it directly; don't rely on the CA output happening to vary.
2. **The community seed is last**, so it needs no length prefix.
3. This preimage is trivially tier-independent — nothing in it (`commitment`, `T`, the
   seed) is a function of `tierMax`, so the tier-independence invariant (§10.11) now holds
   by construction rather than by a padding rule to get right.

Community seed normalization (design: *"case-insensitive, stripped of whitespace and
punctuation"*):

```dart
String normalizeCommunitySeed(String raw) {
  final s = raw.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  return s.isEmpty ? 'universal' : s;
}
```

The empty-result fallback matters: a seed of `"日本"` or `"---"` normalizes to the empty
string, and an empty seed must not silently become a *different* magical tradition from
`universal`. Default seed is `'universal'`.

### 4.2 The scan

Scan the 64-char hex string. Three rows, each firing at most once (A3), each taking the
longest qualifying occurrence (A3):

| Row | Pattern | Fires when | Bracket steps |
|---|---|---|---|
| 1 | `000` | longest run of `'0'` has length ≥ 3 | `len − 3` |
| 2 | `111` | longest run of `'1'` has length ≥ 3 | `len − 3` |
| 3 | `0123` | longest ascending run **starting at `'0'`** has length ≥ 4 | `len − 4` (unused) |

An ascending run is a **maximal** sequence where each character equals the previous plus one
**mod 16** — so `F` wraps to `0`, and `0123456789abcdef0` is a valid run of length 17. The run
must *begin* at `'0'`, and "maximal" is load-bearing here: in `def012` the maximal ascending
run starts at `d`, not at `0`, so it does **not** qualify even though `012` appears inside it.
Find maximal runs first, then filter on the start character — not the other way round.

Row 1 and Row 2 are runs of a single repeated character and are unaffected by this subtlety
beyond the same maximality rule (`0000` is one run of 4, not two overlapping runs of 3).

> **`[RATIFIED]` Row 3's trigger is `0123` (≥4, pinned to `'0'`)** — down from `012345`.
> Soren: *"I intended those effects to be rare, but probably not that rare."* Odds per
> inscribed spell over a 64-char hash (corrected for the maximal-run condition — a run only
> counts where it *starts*):
>
> | Row-3 pattern | ≈ odds per spell | 1 in |
> |---|---|---|
> | `000` / `111` (Rows 1–2, reference) | 1.4% | 70 |
> | any ascending run ≥4, start unpinned | 1.4% | 72 |
> | **`0123` — ≥4, pinned to `0`** ← **ratified** | **0.087%** | **1,150** |
> | any ascending run ≥5, start unpinned | 0.086% | 1,160 |
> | `01234` — ≥5, pinned | 0.0054% | 18,600 |
> | `012345` — ≥6, pinned *(the design doc's original)* | 0.00033% | 300,000 |
>
> **Pinning the start digit is worth exactly one length step** — both are a factor of 16,
> which is why `0123`-pinned and unpinned-≥5 coincide. So this is one knob, not two, and
> dropping the pin at length 4 would make Row 3 *exactly as common as Rows 1–2* — too much
> for effects like Rippling Reflections.
>
> **The knob barely moves the grinder**; a foundry searches any of these thresholds in
> seconds-to-minutes (§2.6). What it actually controls is whether a **hand-crafter** ever
> sees one. At 1-in-1,150 a 20-spell chapter has a ~1.7% chance of holding a Row 3, so
> someone in a dozen-player community has one — "legendary but real." At 1-in-300,000 it is
> 0.007%: nobody, ever, without tooling.
>
> Amplifier to keep in mind: **kin spells each get an independent roll.** `T` is its own
> explicit preimage field (§4.1), so the same grid inscribed at T=8 and T=14 is two separate
> wild-magic rolls. A player who inscribes a favorite grid at several lengths is buying
> extra tickets.
>
> Lowering the minimum to 4 costs nothing elsewhere: Row-3 effects have no bracketed values
> in the table, so `bracketSteps` there is unused (A4) and reachability is a non-issue.
>
> Rows 1 and 2 are unchanged — 1-in-70 each is the intended everyday rate.

### 4.3 Eligibility

```
counts = tally over certified formulas of spellAffinityFromZone(formula.affinity)
if counts.isEmpty            → no wild magic         // zero-formula (void) spells
maxCount = max(counts.values)
eligible = { e in SpellAffinity.values : counts[e] == maxCount }
```

Iterate `SpellAffinity.values` order (`fire, earth, water, air`) when building `eligible`
and when resolving — **not** map iteration order, which is insertion-ordered in Dart and
therefore depends on formula order. This is a lockstep landmine: both clients see the same
formulas in the same order today, but the moment they don't, unordered iteration turns a
cosmetic difference into a state-hash divergence.

Note how §4.3 disposes of void for free: a zero-formula spell yields an empty tally and no
eligible element, so it fires nothing. That is the design's "void effects entirely removed
for now", with no special case.

### 4.4 The effects table

Row order 1 → 2 → 3; within a row, element order `fire, earth, water, air`.

| | Fire | Earth | Water | Air |
|---|---|---|---|---|
| **`000`** | Burning Hot | Mountains | Mana Flood | Zephyr |
| **`111`** | Spontaneous Combustion | Chasm | Glacier | Updraft |
| **`0123`** | Phoenix | Statuesque | Rippling Reflections | Scattered Gusts |

### 4.5 Where it resolves

Design doc L746: *"Within a single player's spell: **wild magic first**, then formula effects
in the order the CA created them."*

So: inside `_applySpell`, **before** the `if (spell.isSummon)` early return (A2) and before
the formula loop. Between players, the existing resolution order (group, then `T` ascending,
then `commitmentHex`, then `playerId`) is untouched — wild magic rides along with its spell.

### 4.6 Trust boundary

Same B-1/B-8 pattern the rest of this engine already follows: **derive the seed hash from
certified proof public outputs, never from the wire `SpellAsset`.**

- **Peer casts:** `_verifyPeerSpellCast` already holds a verified `VerifiedSpellOutputs`.
  Compute the trigger set there and stash it in a new
  `Map<String, List<WildMagicTrigger>> certifiedPeerWildMagic`, keyed by `commitmentHex`,
  alongside `certifiedPeerFormulas` — same lifecycle, same clearing.
- **Local casts:** we have our own `proofBytes` but no `VerifiedSpellOutputs`. Add
  `ProofIntake.parseOwn(Uint8List proofBytes, int tier)` — the existing private `_parse`,
  exposed, verification skipped. Document it as **only** valid for locally-authored proofs;
  a peer proof must always go through `verifyAndParse`. This gives both sides one code path:
  `VerifiedSpellOutputs` → `WildMagicSeed.compute` → identical hash.
- **Delayed fires / the `kAllowProoflessSpells` dev flag:** these already fall through with
  `certFormulas == null`. Follow the existing convention exactly — fall back to parsing the
  wire proof bytes. That is desync-*safe* (both devices parse the same bytes) even though it
  is not trust-safe, which is precisely the pre-existing `TODO(B-1)` hole. Do not widen it,
  do not invent a second policy for it, and add your fallback under the same TODO.

---

## 5. Randomness

Wild magic's *firing* is deterministic (§2.3). Its *internal* choices are not, and must come
from per-turn joint entropy through the existing `_playerPhaseSeed` machinery so both clients
agree.

Add two phase tags (existing tags in use: `0x02` action, `0x05` refill draw, `0x06` wither,
`0x07` opening deal, `0x08` hand slot):

- **`0x09` — wild magic resolution.** `_playerPhaseSeed(entropy, matchId, turnNumber, 0x09,
  actor.playerId, nonce)`, where `nonce` is a per-turn counter incremented on every
  wild-magic firing so two casts in the same turn never share a stream. Reuse the
  `_consumeDrawNonce` pattern.
- **`0x0A` — Rippling Reflections coin.** Same shape, per-cast nonce.

Never seed either from `Random.secure()` or `DateTime` — see `hash_rng.dart`'s header. Where
an effect needs a shuffled tile list (Zephyr), shuffle a **deterministically sorted** list;
never shuffle the output of a `Set` or `Map` iteration.

---

## 6. Build order

| Phase | Content | Gate |
|---|---|---|
| 1 | Seed hash, scan, eligibility, resolution seam, `MatchConfig.communitySeed`, `WildMagicState` + canonical bytes, and the 4 effects needing no new primitives | Fixed-vector tests for hash + scan; `flutter test` green |
| 2 | New terrain/movement primitives: `IceTile` + sliding, `ChasmTile`, flying, Zephyr teleport | Movement tests; `flutter run -d linux` visual pass |
| 3 | Persistent global modifiers: Phoenix, Statuesque, Rippling Reflections, Scattered Gusts, then Spontaneous Combustion | Two-device LAN pass (§12) |

Phase 1's four cheap effects are **Burning Hot, Mountains, Mana Flood, Updraft** — chosen so
each exercises a different shape of the applicator (turn-scoped global modifier, terrain
placement, immediate stat change, status effect) without needing new primitives. Note this
takes Updraft out of Row 2 and leaves Zephyr for Phase 2, because Zephyr needs the flying
and chasm-awareness that Phase 2 introduces.

---

## 7. Phase 1 — the engine

### 7.1 `lib/battle/models/wild_magic_effect.dart` (new)

```dart
enum WildMagicRow { repeatZero, repeatOne, ascendingRun }

enum WildMagicEffectKind {
  burningHot, mountains, manaFlood, zephyr,                          // row 1
  spontaneousCombustion, chasm, glacier, updraft,                    // row 2
  phoenix, statuesque, ripplingReflections, scatteredGusts,          // row 3
}

/// One fired trigger: which row, which elemental column, how far past minimum.
class WildMagicTrigger {
  const WildMagicTrigger({
    required this.row,
    required this.element,      // SpellAffinity
    required this.bracketSteps, // 0 = base value
  });
}

WildMagicEffectKind wildMagicEffectFor(WildMagicRow row, SpellAffinity element);
```

Include a `kWildMagicEffectLabel` / `kWildMagicEffectDescription` map — the battle screen
needs in-world names to show the player *why* the board just rearranged itself, and the
design doc supplies them ("Burning Hot", "Mana Flood", "Zephyr", …).

### 7.2 `lib/battle/engine/wild_magic.dart` (new)

Pure functions, no `BattleState` dependency, fully unit-testable:

```dart
class WildMagic {
  static String normalizeCommunitySeed(String raw);

  /// §4.1. Derives the 64-char lowercase seed hash.
  static String seedHex(VerifiedSpellOutputs outputs, String communitySeed);

  /// §4.2 + §4.3. Full derivation: hash → scan → eligibility → triggers,
  /// in deterministic row-then-element order. Empty list = no wild magic.
  static List<WildMagicTrigger> triggersFor(
    VerifiedSpellOutputs outputs,
    List<ParsedFormula> certifiedFormulas,
    String communitySeed,
  );

  // Exposed for testing against fixed strings, not just fixed proofs:
  static Set<SpellAffinity> eligibleElements(List<ParsedFormula> formulas);
  static List<(WildMagicRow, int)> scan(String seedHex);
}
```

### 7.3 `lib/battle/models/wild_magic_state.dart` (new)

The persistent, match-scoped globals. Lives on `BattleState` as `wildMagic`.

```dart
class WildMagicState {
  /// Burning Hot: +N damage to all spell effects, on one specific turn.
  /// Active iff state.turnNumber == spellDamageBonusTurn. Stacks by summing
  /// amount when two Burning Hots target the same turn.
  int spellDamageBonusAmount = 0;
  int spellDamageBonusTurn = -1;

  /// Phoenix: playerIds that will respawn at 1 HP instead of dying. One-shot,
  /// consumed on death.
  final Set<String> phoenixPlayerIds = {};

  /// Statuesque: playerIds refilled to full HP+mana each turn end, removed
  /// from the set the moment they move or cast.
  final Set<String> statuesquePlayerIds = {};

  /// Rippling Reflections: null = inactive. Otherwise the current fizzle
  /// probability in percent, clamped [0, 100], drifting ±10 per outcome.
  int? ripplingFizzlePct;

  /// Scattered Gusts: once true, stays true for the match.
  bool scatteredGusts = false;
}
```

Also add to `BattleState`:

```dart
/// Temporary tile effects: coord → the last turn number the effect is active.
/// Swept in Phase 6. The mechanism for Mountains (2[3] turns), Chasm, and
/// Glacier — every existing TileEffect is permanent and needed no such thing.
final Map<HexCoord, int> expiringTiles;
```

### 7.4 `BattleState.toCanonicalBytes` — **mandatory, and the top desync risk**

Every field above is consensus state. Append, after the illusion-terrain block:

```
writeInt32 (wildMagic.spellDamageBonusAmount)
writeInt32 (wildMagic.spellDamageBonusTurn)
writeUint16(phoenixPlayerIds.length);    each, sorted:  writeUtf8(id)
writeUint16(statuesquePlayerIds.length); each, sorted:  writeUtf8(id)
writeUint8 (ripplingFizzlePct == null ? 0 : 1); if set: writeInt32(pct)
writeUint8 (wildMagic.scatteredGusts ? 1 : 0)
writeUint16(expiringTiles.length); each, sorted by (q, r):
    writeInt16(q); writeInt16(r); writeInt32(expiryTurn)
```

Sort every collection. `Set<String>` iteration order is insertion order in Dart — two
clients that add the same players in different orders would produce different bytes from
identical game state.

The good news on the new tile variants: `_tileEffectIndex` is an exhaustive switch over a
sealed `TileEffect`, so adding `IceTile` and `ChasmTile` in Phase 2 is a **compile error**
until you extend it. Append new tags (`IceTile => 4`, `ChasmTile => 5`); never renumber the
existing four.

### 7.5 `MatchConfig.communitySeed`

Add `final String communitySeed;`, default `'universal'`. Add it to `matches()`,
`toJson()`, and `fromJson()`. Both sides must agree or the session aborts — which is exactly
right: two players from different traditions must explicitly settle on one seed before
dueling, and a pre-wild-magic client will fail agreement rather than silently desync (§11).

Persist the device's own choice next to the wizard name (`lib/identity/identity.dart` has the
`loadWizardName`/save pattern): `Identity.loadCommunitySeed()` / `saveCommunitySeed()`. Store
the **raw** string the player typed and normalize at hash time, so the settings UI can echo
back what they wrote.

UI: a text field in the same settings surface as the wizard name, with helper text along the
lines of *"Your community's word. Spells find different wild magic under different
traditions; both duelists must use the same word."* Show the normalized form beneath it so
`"Rivendell!"` visibly becoming `rivendell` is not a surprise.

> **This field is the ratified anti-grinder lever (§2.6) — build it as a first-class control,
> not a buried setting.** Public-input hashing is cheap to grind; the design's answer is that
> a community which sees ground-out triggers warping its meta simply **changes its word**,
> which invalidates every previously ground trigger at zero cost and forces any grinder to
> start over *after* the new word is announced. That only works if changing it is easy and
> obvious, so:
>
> - Make it changeable at any time, not just at first launch.
> - Warn on change that **every spell in the library gets different wild magic** — this is a
>   meta reset, not a preference. Existing recipe effects are untouched (design §Community
>   Seed Word: recipe effects stay universal so travelling players keep a valid spellbook).
> - Surface it in the pre-duel handshake UI, since both sides must match; a mismatch should
>   read as *"you follow different traditions"*, not as a protocol error.
>
> **Naming:** Soren refers to this in-world as the **leyline seed word**. The design doc calls
> it "Community Seed Word". Worth settling one diegetic name and using it in all UI copy —
> the §Incantation Effect Naming Worksheet suggests the in-world register is preferred. The
> *code* identifier (`communitySeed`) can stay as-is either way; this is a copy decision.

### 7.6 Resolution seam in `turn_loop.dart`

1. **Thread the triggers in.** Add `List<WildMagicTrigger>? certWildMagic` to `_applySpell`'s
   parameters, populated from `certifiedPeerWildMagic[spell.commitmentHex]` for peer casts
   and from `WildMagic.triggersFor(ProofIntake.parseOwn(...), …)` for local ones (§4.6).
2. **Fire before anything else.** At the top of `_applySpell`, before the `isSummon` branch:
   resolve each trigger through `WildMagicApplicator.apply(...)` in row-then-element order,
   with a `0x09`-tagged `HashRng`.
3. **Add `bool fireWildMagic = true`.** Set it `false` for Spontaneous Combustion's free
   casts (A8) and for Rippling Reflections' doubled application (A7). This flag is the
   recursion guard for the whole system; it is worth a comment saying so.
4. **Emit events.** Add `final List<WildMagicEvent> lastWildMagicEvents = [];` mirroring the
   existing `lastCastEvents` / `lastResolvedSpells` / `lastConveyorChainEvents` pattern —
   cleared per turn, read by `battle_screen.dart`. Carry the effect kind, the bracket steps,
   the caster, and enough detail to animate (affected tiles, affected players). **A global
   effect the player cannot see happen is a bug**, not a UI nicety: wild magic is
   untelegraphed by design, so the resolution reveal is the *only* place either player learns
   it fired.

### 7.7 `lib/battle/engine/wild_magic_applicator.dart` (new)

One `switch` on `WildMagicEffectKind`, shaped like `EffectApplicator.apply` — a context
object carrying `state`, `caster`, `rng`, `bracketSteps`, plus the `drawSchedules` map and a
`TurnLoop` callback seam for the few effects that need to re-enter spell resolution. Keep it
out of `turn_loop.dart`; that file is already ~5,000 lines.

### 7.8 The four Phase-1 effects

**Mana Flood** (Row 1, Water) — *"All mana bars immediately fill."* For every living avatar,
`_applyManaGain(av, av.maxMana - av.mana)`. Use the existing helper rather than assigning
`av.mana` directly — it also fires Reflections' `manaMirror` trigger, and a wild-magic mana
gain should behave like every other mana gain.

**Burning Hot** (Row 1, Fire) — *"All spell effects next turn deal +1 fire damage [+1 damage
per effect]."* Set `spellDamageBonusAmount += 1 + bracketSteps` and
`spellDamageBonusTurn = state.turnNumber + 1`. Then, in `EffectApplicator`'s damage path,
add the bonus when `state.turnNumber == state.wildMagic.spellDamageBonusTurn`. Two
constraints: it must apply to **every** player's spells (symmetry), and it must apply
per-effect, so a three-formula spell gets it three times.

**Mountains** (Row 1, Earth) — *"All adjacent cells become earth walls 2 turns [+1 turn]."*
Per A5: for each living avatar, for each in-bounds neighbor tile that is unoccupied and has
no existing `TileEffect`, place `ImpassableTile()` and set
`expiringTiles[tile] = state.turnNumber + 1 + bracketSteps`. Collect the tile set
deterministically (iterate avatars sorted by `playerId`, neighbors in `hexNeighbors` order).

**Updraft** (Row 2, Air) — *"All players gain flying for 2 [+1] turns."* Add
`StatusEffectId.flying` and `WizardAvatar.isFlying`. Apply via `_addStatus(av,
StatusEffectId.flying, const {}, 2 + bracketSteps)` to every living avatar. The movement
half of flying lands in Phase 2 (§8.3) — in Phase 1 the status exists, ticks, and shows in
the UI, but does not yet change movement. Say so in the commit message; a status effect that
silently does nothing is worse than one documented as half-built.

---

## 8. Phase 2 — terrain and movement primitives

### 8.1 `IceTile` + sliding — Glacier (Row 2, Water)

*"Tiles without existing terrain all become Ice tiles for 2 [+1] turns; when moving onto ice
a player continues moving that direction."*

- New `class IceTile extends TileEffect` in `terrain.dart`. Expiry lives in
  `expiringTiles`, not on the tile — keep `TileEffect` variants immutable like the existing
  four.
- Placement: every in-bounds tile with no existing `TileEffect` entry. This is a
  board-covering effect (~55 tiles on radius 4) — check the canonical-bytes size and the
  render path don't choke.
- Sliding in `_walkAvatar`: after entering an `IceTile`, compute `delta = step - previous`
  and keep stepping in that direction, **free of movement budget** (A12), stopping when the
  next tile is out of bounds, occupied, or not an `IceTile`. Bound the loop at
  `radius * 4` iterations as a belt-and-braces guard against a coordinate-math slip
  becoming an infinite loop mid-turn. If the slide ends on a `ConveyorTile`, hand off to
  `resolveTileEntry` exactly as the existing conveyor path does. Flying avatars do not
  slide (A11). Emit the slide path into the walked-path result so knockback's
  bounce-along-your-path reference stays correct.
- `Battlefield.resolveMovement`'s collision preview must know about ice too, or the preview
  and the real walk will disagree about where players end up — and the preview is what
  arbitrates contested tiles.

### 8.2 `ChasmTile` — Chasm (Row 2, Earth)

*"A randomly drawn line bisects the battlefield. It is impassible (without flying), and
indestructible for 2[+1] turns, but has no bearing on targeting."*

New `class ChasmTile extends TileEffect` (A9). Per A10, pick an axis uniformly from the
`0x09` RNG and mark every in-bounds tile on it:

```
0 → q == 0        1 → r == 0        2 → q + r == 0
```

Set `expiringTiles[tile] = state.turnNumber + 1 + bracketSteps`. Then audit every consumer
of `ImpassableTile` and decide for each whether `ChasmTile` belongs:

- **movement** (`_walkAvatar`, `Battlefield.resolveMovement`, `resolveTileEntry`, minion
  placement/pathing) — yes, blocks, unless flying.
- **targeting / line-of-sight** — **no.** This is the whole point of a distinct class.
- **terrain-destruction effects** — no; the chasm is indestructible. It also must not be
  overwritten by another tile effect landing on it while it lives.

Grep `ImpassableTile` and touch every site deliberately. A missed movement site is a
one-device-only illegal move, which is a desync, not a rules bug.

### 8.3 Flying (movement half)

`WizardAvatar.isFlying` short-circuits terrain in `_walkAvatar` and
`Battlefield.resolveMovement` per A11 — the same `flying:` parameter `resolveTileEntry`
already takes for spirit minions, so much of this is threading an existing flag rather than
new logic.

### 8.4 Zephyr (Row 1, Air)

*"All players and minions teleported to random locations."*

Deterministic procedure — order matters more than cleverness here:

1. Build the eligible-tile list: all in-bounds tiles, **sorted by (q, r)**, excluding tiles
   carrying `ImpassableTile` or `ChasmTile`.
2. Shuffle it with the `0x09` `HashRng`.
3. Assign in a fixed entity order: living avatars sorted by `playerId`, then living minions
   sorted by `id`. One entity per tile.
4. A flying entity may land on a blocked tile; simplest correct call is to exclude blocked
   tiles for everyone and note it.
5. Update `av.position` **and** `state.battlefield.occupancy` together — they are two
   mirrors of the same fact and drifting them apart is a subtle, long-lived desync.
6. Landing on a tile with `FloorIsLava` / `SlowTile` / `ConveyorTile`: route through
   `resolveTileEntry` so a teleport-onto-conveyor behaves like any other entry. If you
   choose not to, say so in a comment — silence here reads as an oversight.

---

## 9. Phase 3 — persistent global modifiers

These four are Row 3 — the rarest row, at whichever rate §4.2 settles on. They are
match-warping by design, and
all four need state in `WildMagicState` and `toCanonicalBytes`.

### 9.1 Phoenix (Row 3, Fire)

*"All players gain: the next time they would die, they respawn with 1 hitpoint instead."*

Add every living `playerId` to `phoenixPlayerIds`. Intercept in `_reapDead`: if a dying
avatar's id is in the set, remove it (one-shot) and set `hp = 1` instead of reaping. Emit an
event so the UI can show the save.

Coordinate with `docs/MASTER_APPRENTICE_PLAN.md` Phase A, which is building match-end and
the signed `MatchOutcome` — the death path is about to change under you. Check `git log` and
`lib/battle/models/match_outcome.dart` (currently untracked) before writing this one, and if
Phase A has landed, hook Phoenix ahead of the win check rather than beside it.

### 9.2 Statuesque (Row 3, Earth)

*"All players return to full health and mana each turn; the effect is lost if they move or
cast a spell."*

Add every living `playerId` to `statuesquePlayerIds`, effective from the end of the current
turn (A6). Then:

- **Break on move:** in `_resolveAvatarMovement`, remove the player if their walked path has
  length > 1. Involuntary movement (knockback, conveyor, ice slide, Zephyr) should **not**
  break it — "if they move" reads as a choice. Note the call in a comment.
- **Break on cast:** remove the player when they resolve a `SpellCastAction`. A Pass, Dash,
  Meditate, or melee attack does not break it. (Dash is arguable; it is only a move.)
- **Refill:** in Phase 6, for each player still in the set, `hp = config.playerHp` and
  `_applyManaGain(av, maxMana - mana)`.

This effect can deadlock a match into a stalemate between two players who both just stand
there. That is a legitimate and rather funny outcome of a symmetric double-edged effect, and
`MatchConfig` has no turn limit today — worth a line in the PR description rather than a fix.

### 9.3 Rippling Reflections (Row 3, Water)

*"Going forward, upon spell resolution, every spell has a 50% chance to fizzle and a 50%
chance to resolve twice. Every time a spell fizzles the odds shift 10% towards doubling, and
vice versa."*

Set `ripplingFizzlePct = 50`. Then at every subsequent spell resolution (in `_applySpell`,
after wild magic, before the formula loop), when `ripplingFizzlePct != null`:

- Roll with a `0x0A`-tagged `HashRng`. Note there is no third outcome — every spell either
  fizzles or doubles.
- **Fizzle:** skip all formula effects; `ripplingFizzlePct = (pct - 10).clamp(0, 100)`.
  Treat as a fizzle for chain purposes, matching the existing
  `enhancements.fizzle` branch.
- **Double:** apply the formula effects twice; `ripplingFizzlePct = (pct + 10).clamp(0, 100)`.
  The second application does **not** re-fire wild magic (A7) — pass `fireWildMagic: false`,
  or better, structure the doubling inside the formula loop so it cannot reach the wild-magic
  seam at all.

One shared counter for the whole match, per "every spell". Because the doubling interacts
with `pendingEffectMultipliers` (the Air-Fire Bellows multiplier already in `_applySpell`),
write a test for the two stacking.

### 9.4 Scattered Gusts (Row 3, Air)

*"Going forward, every time a player casts a spell all their bookmarks are blown out of
place and they randomly find a new set of spells to mark."*

Set `scatteredGusts = true`. Thereafter, after each player's cast resolves, re-deal their
entire hand:

- Add `SpellDraw.redrawHand(int handSize, HashRng rng)`: return every hand card to
  `remaining` **in canonical `commitmentHex` order** (reuse `removeSlot`'s insertion logic —
  `remaining`'s sortedness is a load-bearing invariant, see `spell_draw.dart`'s header), then
  draw `handSize` fresh.
- Add the exact mirror to `DrawSchedule`, driven from an independently-constructed `HashRng`
  with the same seed bytes — the established pattern for keeping contents and positions in
  agreement without sharing RNG state.
- Seed from a fresh `0x05`-tagged (refill) per-player seed with a new nonce.
- Free casts do not trigger this (A8), or Spontaneous Combustion becomes a hand-shredder.

### 9.5 Forced reveal-and-cast — the reusable primitive, and Spontaneous Combustion

Build this **last** in Phase 3 (it is the most expensive cell), and build it as a **named
general primitive with Spontaneous Combustion as its first caller**, per §2.5. Soren intends
to reuse it for a plain "cast something at random from your hand" effect if other table cells
disappoint in playtest, so the seam is the deliverable, not just the one effect.

Put it in its own file — `lib/battle/engine/forced_cast.dart` — not inside the wild-magic
applicator's `switch`, and not inside `turn_loop.dart`.

**Do not attempt to fake the peer's hand.** Resolving a spell one device doesn't have is an
instant desync and the state-hash exchange will abort the match. §3.1 explains why.

#### Proposed interface

```dart
/// Forces one or more players to reveal and immediately resolve spells from
/// their own hand at no mana cost. Reusable: wild magic's Spontaneous
/// Combustion is the first caller, but nothing here is wild-magic-specific.
class ForcedCastRequest {
  final Set<String> affectedPlayerIds;   // deterministic: iterate sorted
  final int countPerPlayer;              // 1 + bracketSteps for Spont. Comb.
  final ForcedCastTargeting targeting;   // randomInRange is the only mode today
  final String reasonTag;                // for the UI + the event log
}
```

#### Sequence

1. **Select slots publicly.** For each affected player (sorted by `playerId`), pick
   `countPerPlayer` **hand positions** using a `0x09`-tagged per-player RNG over that
   player's existing `DrawSchedule.hand`. Positions are already public on both clients —
   this is the whole structural point of `DrawSchedule` — so **both sides agree on which
   slots were chosen before anybody reveals anything.** That ordering matters: it means the
   revealer cannot shop for a favourable spell, and the receiver can verify the reveal
   corresponds to the slot that was actually selected.
2. **Reveal.** Each player transmits the `SpellAsset`s (with proofs) for their selected
   slots.
3. **Verify.** Each side runs the incoming spells through `_verifyPeerSpellCast` — the
   existing path, unchanged, including the commitment-vs-wire check and the Merkle
   membership proof binding the spell to the peer's chapter root. **A revealed spell that
   fails verification forfeits the match**, same as any other bad cast; do not add a lenient
   path here.
   - The duplicate-grid guard (`_seenPeerCommitments`) needs a decision: a forced cast is not
     the player's choice, so it should almost certainly **not** consume a player's
     once-per-match right to cast that grid, nor trip the duplicate forfeit. Recommend
     exempting forced casts from `_seenPeerCommitments` entirely, and say so in a comment.
4. **Resolve.** Target tile: a random tile within `av.effectiveSpellRange` of that player,
   drawn from a **sorted** candidate list. Then `_applySpell` with `CastingEnhancements()`,
   zero mana, and A8's full exemption set — `fireWildMagic: false`, no Rippling Reflections
   roll, no Scattered Gusts re-draw, no chain update, and the spell is **not** consumed from
   hand.

#### Protocol and failure modes

- Add the message to `BATTLE_PROTOCOL.md` and to `battle_wire.dart` with a new tag. Note
  that `lib/battle/networking/battle_wire.dart` and `battle_session.dart` are **already
  modified** on this branch — rebase awareness, not a blocker.
- **A player with an empty hand reveals nothing** and is skipped. Handle it explicitly; an
  empty-hand player is reachable (deck exhausted) and a null-deref here happens mid-turn,
  mid-match.
- **Withheld reveal** = the same treatment as a withheld nonce: `sendForfeit`. Reuse the
  existing pattern in `_resolveEntropy` rather than inventing a second failure convention.
- This round trip sits **inside** Phase 5, after wild magic fires and before the triggering
  spell's own formula effects resolve. That makes Phase 5 `async` at a point where it may not
  be today — check, and if the call chain needs threading, do that first as its own commit so
  the diff for this effect stays readable.
- Solo/practice mode has no peer: resolve the local player's forced cast directly, no
  message. Make sure the no-session path doesn't await a reveal that will never arrive.

---

## 10. Invariant checklist — must all hold at PR time

1. `flutter test` green, including the pre-existing suite. No new pre-existing failures.
2. **Exactly one** wild-magic derivation path. Grep for a second call site computing a seed
   hash and delete it.
3. Every new consensus field is in `toCanonicalBytes`, every collection sorted.
4. Both new `TileEffect` variants have `_tileEffectIndex` tags; existing tags 0–3 unchanged.
5. No use of `Random`, `Random.secure()`, `DateTime`, `hashCode`, or unordered `Set`/`Map`
   iteration anywhere in the wild-magic path.
6. Wild magic fires from **certified** outputs on the peer path; the wire `SpellAsset` is
   never the hash source except under the pre-existing `TODO(B-1)` fallback.
7. Free casts (Spontaneous Combustion) and doubled casts (Rippling Reflections) cannot
   re-enter the wild-magic seam. Prove it with a test, not by inspection.
8. Countered and fizzled casts fire no wild magic (A1).
9. Zero-formula (void) spells fire no wild magic (§4.3).
10. Every effect is symmetric — grep the applicator for any `playerId != caster.playerId`
    guard and justify or delete it.
11. The seed hash is tier-independent: the same spell in a tier-24 and a tier-48 match
    produces the same `wildMagicSeedHex`. Test it directly.
12. `MatchConfig.communitySeed` is in `matches()`, `toJson()`, and `fromJson()`.
13. `RULESET_VERSION` **not** bumped (§11).

---

## 11. Versioning

**No `RULESET_VERSION` bump.** That constant guards consensus-visible *CA rule* changes
because it is a deliberate VK-breaking mechanism. Wild magic reads existing public proof
outputs and changes nothing about the simulation, the grid, the commitment, or the circuit.
A spell inscribed before this change has the same wild magic after it.

What *does* change is the battle protocol: `MatchConfig` gains a field and
`toCanonicalBytes` gains a suffix, so a patched client and an unpatched one cannot play
together. `MatchConfig.matches()` catches this at handshake and aborts cleanly — which is the
correct outcome, and better than a mid-match state-hash divergence. If `BATTLE_PROTOCOL.md`
carries a version number, bump it and note the incompatibility there.

---

## 12. Tests

### Fixed vectors — the load-bearing ones

`test/battle/wild_magic_test.dart`:

- **Seed hash vectors.** Hand-construct 3–4 `VerifiedSpellOutputs` and pin the exact
  expected `wildMagicSeedHex` as a literal. These are the cross-client contract; a
  refactor that changes them is a breaking change and the test failure should say so in a
  comment.
- **Preimage independence.** Same `commitment`/`T`/seed, but different `borderActivations`,
  `dominanceTrajectory`, `supremeDominanceFlags`, `segmentCount`, `dotCount` on the
  `VerifiedSpellOutputs` → identical `wildMagicSeedHex`. This is the regression test for
  §4.1's simplification: it should be structurally impossible for a future edit to
  accidentally start reading those fields back into the hash.
- **Tier independence.** Same spell, `tierMax` 24 vs 48, identical hash — holds by
  construction now (§4.1 note 3), but keep the test as cheap insurance (invariant 11).
- **Seed normalization.** `"Rivendell!"`, `"rivendell"`, `" RIVENDELL "` → same hash;
  `""`, `"---"`, `"日本"` → the `universal` hash; `"rivendell"` ≠ `"universal"`.
- **Scan**, against fixed 64-char strings, not proofs: `000` at the start, at the end, and
  spanning a boundary; `0000` → bracketSteps 1; `00` → no fire; overlapping `0001111`
  firing both rows 1 and 2; `0123` → fires row 3; `def012` → does **not** (the maximal run
  starts at `d`, §4.2); `4567` → does not; `0123456789abcdef0` → fires; a hash with two
  separate `000` runs of different lengths → one trigger, the longer bracket (A3).
  **Add a case that would pass under a naive substring search but must fail under maximal-run
  semantics** — `def012` is that case, and it is the single easiest way to get row 3 wrong.
- **Eligibility.** Single-formula; 2 fire + 1 earth → fire only; 1 fire + 1 water → both;
  four-way tie → all four; zero formulas → empty.
- **Determinism.** Same inputs, 100 calls, identical output.

### Engine tests

`test/battle/wild_magic_resolution_test.dart`:

- Wild magic resolves before formula effects (assert on ordering, via a spy applicator).
- Fires on a summon cast (A2); does not fire on countered, fizzled, or void casts (A1, §4.3).
- A four-way-balanced spell with `000` fires all four Row-1 effects, in
  `fire, earth, water, air` order.
- Free casts and doubled casts do not re-fire wild magic (invariant 7).
- Peer path and local path produce identical triggers from the same proof bytes.

### Per-effect tests

One file per phase (`wild_magic_effects_phase1_test.dart`, …). Each effect: base value and
one bracketed value; symmetry (caster affected too); and the state-hash round trip — mutate
via the effect, `toCanonicalBytes()`, assert it differs from before and that two
independently-built identical states produce identical bytes.

Movement-heavy ones need real cases: ice slide into the board edge, into another player,
into a conveyor, and a flyer crossing ice and chasm without effect.

### Hardware gate

Per `CLAUDE.md`'s verification hierarchy, a two-device LAN pass is required before Phase 3
is called done — a whole-match run where at least one wild-magic effect fires on each side
and the per-turn state hashes agree throughout. Force a trigger with a dev-only community
seed chosen to make a test spell's hash contain `000`; that is also the cheapest way to
exercise the rare rows at all. `flutter run -d linux` is the cheap loop for Phases 1–2.

---

## 13. Design-doc corrections to fold in

Once the implementation is settled, update `docs/runewright_design_v3_0.md`:

1. **Strike the per-element digit language in §Trigger Patterns** — "assigned per element,
   no overlap" and "first numeral must be the element's designated trigger" contradict the
   ratified literal-pattern model (§2.1). Replace with §4.2's table.
2. **Change the Row-3 trigger from `012345` to `0123`** (§4.2, ratified) and record the
   rarity number (~1 in 1,150) next to the effects table, so the next reader knows what rate
   those four cells were tuned to and can see the knob.
3. **Replace the seed-hash formula with the simplified one** (§4.1, ratified 2026-07-30):
   `SHA256(commitment || T || community_seed)`, not
   `SHA256(commitment || border_activations || trajectory || community_seed)` as currently
   written. Border activations and the trajectory are deterministic functions of `(grid, T)`
   and add no distinguishing power beyond `commitment` (itself a grid hash) plus `T`; the
   doc's version was carried over from an earlier draft, not a technical requirement. Add
   the exact byte layout too — this is a cross-client contract, not prose.
4. **Note that `T` is an explicit preimage field, not inferred from trajectory length**, and
   why (kin-spell disambiguation must not depend on the CA's border activity happening to
   differ between two T values on the same grid — see §4.1's note 1).
5. **Fix the stray `T` on its own line** after the effects table (L607) — looks like a typo.
6. **Record whichever of §3's A1–A12 assumptions Soren ratifies**, and the §2.5 decision on
   Spontaneous Combustion.
7. **Promote the community seed word from a paragraph to the stated anti-grinder mechanism**
   (§2.6). The doc currently presents it as flavour ("local magical traditions", "home-turf
   advantage"); it is also the *only* lever against a foundry warping a local meta, and that
   load-bearing role should be written down.
8. **Settle the in-world name** — "leyline seed word" (Soren's usage) vs "Community Seed
   Word" (current doc) — and use one consistently in UI copy.

---

## 14. Explicitly deferred (name in the PR, don't build)

- Expanding the effects table beyond 12 cells.
- Void wild magic, the void mana-cost formula, the tile-gated power cap.
- ~~Any inscribe-time "divine your wild magic" UI~~ — **un-deferred and built 2026-08-05
  at Soren's request; see §15.**
- Tournament seed announcement / seed-switching mid-session.
- Sorcerer-mode interactions with any wild-magic effect.

---

## 15. Wild magic on the spell card (built 2026-08-05)

§14 deferred this on the grounds that *"it changes what a player knows before a duel"*.
Soren asked for it anyway, so here is what changed and what that consequence actually is.

**What a card now shows.** A spell that fires wild magic gets two treatments, and only such
a spell gets them:

- a **WILD MAGIC panel** below the rules box on the fullscreen card, naming each effect it
  fires with the effect's own symmetric description verbatim from
  `kWildMagicEffectDescription`, and
- a **foil luster** (`lib/ui/foil_sheen.dart`) over the whole card at every size — the
  thumbnail in the library and the hand tray as well as the fullscreen card — so the wild
  ones are findable by eye without reading a word.

The panel is deliberately its own rubric-red band rather than another line in the rules
box: a wild-magic effect is global, symmetric and ignores tile targeting, and listing it
next to *"3 damage to the target tile"* would invite exactly the misreading the
descriptions' "every wizard" voice exists to prevent.

**The consequence §14 warned about, now that it's real.** Wild magic stays untelegraphed
*during* a duel — the resolution banner is still the only place an opponent learns it fired
— but its own caster now knows in advance, which they previously had to learn by playing
the spell. That is a deliberate trade: wild magic is a fixed property of the rune (§2.1),
so the old behaviour taxed memory rather than creating suspense. Nothing about an
opponent's information changed.

**Where the derivation lives.** `lib/spells/wild_magic_preview.dart`. It is **not** a second
derivation path (§10 invariant 2): `WildMagic.seedHex`/`triggersFor` were split into
`…FromParts` kernels that both the certified engine path and the card call, so the two can
only ever disagree about where their inputs came from — the engine from certified proof
outputs, the card from a stored `SpellAsset`. §4.6 / §10 invariant 6 is unchanged: nothing
that can move battle state may read the preview. `test/spells/wild_magic_preview_test.dart`
pins the agreement between them.

**Which seed a card previews under.** `activeLeylineSeed`, a `ValueNotifier` the library
primes from `Identity.loadCommunitySeed()` and `BattleScreen` overrides with
`MatchConfig.communitySeed` for the duration of a duel (restored on dispose). This matters
because the guest adopts the host's word (§7.5) — during a duel a player's own setting is
simply not what their spells hash under, and a card that previewed under it would lie at
exactly the moment it mattered. Rotating the seed in Settings pushes the new value through
the notifier, so the whole library visibly re-rolls, which is the anti-grinder lever (§2.6)
made legible.

**One rendering trap, paid for once.** `Color.lerp` interpolates un-premultiplied, so a
gradient stop of `0x00000000` drags the ramp through grey on its way to transparent. The
first foil attempt used transparent-black stops between hues and laid a dirty grey cast
over the parchment. Fading between low-alpha *hues* instead keeps the wash in-hue the whole
way round.
