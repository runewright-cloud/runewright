# Spell-Draw Entropy Plan — making next draws unknowable in advance

*Proposed 2026-07-22. Folds `OUTSTANDING_ITEMS.md §5` (peek-ahead gap) into the
`SpellDraw`-wiring task rather than treating it as a later retrofit. Not yet ratified —
§9 lists the calls that need Soren before implementation starts.*

*2026-07-28 update: `bookmarkCount` below was a static `MatchConfig` value at proposal
time. It's since become per-avatar and dynamic — hand size is
`WizardAvatar.bookmarkCount + 1`, resized mid-battle when a bookmark accoutrement is
created/destroyed (`TurnLoop._reconcileHandSize`, reusing this doc's `opening`/`useSpell`
entropy machinery via new `addSlot`/`removeSlot` methods). The entropy-separation
argument in this document is unaffected — every reference to `bookmarkCount` below
should be read as "this avatar's current hand size."

---

## 1. The problem

`SpellDraw` (`lib/battle/engine/spell_draw.dart`) shuffles a player's **entire** chapter
once, at construction, from a single 32-byte `jointEntropy`, then hands out the first
`bookmarkCount` spells and keeps the rest as a fixed-order deck. Refilling a used hand
slot just walks forward through that pre-computed order — it consumes no new randomness.

A player always knows their own chapter. So the instant the battle-start `jointEntropy`
is revealed, their client can compute the **whole remaining deck order** immediately. The
turn-by-turn "what will I draw next?" uncertainty that a real shuffled deck has is gone:
the sequence is knowable in advance, and a modified client could plan its entire match
around a known future draw stream. That is the unfairness we are closing.

`SpellDraw`'s own header comment states this as an intended *auditability* property
("given the entropy and the initial chapter list, any observer can replay the full draw
sequence"). The fix keeps full post-hoc auditability while removing the *in-advance*
predictability — see §6.

**This is not a standalone later pass — it is part of the wiring itself.** `SpellDraw`
*is* the battle hand/deck mechanic (the Air-affinity "Bookmarks" system), and it has no
consumer today: every non-test reference to it is a comment noting it is unwired
(`battle_state.dart:131`, `effect_applicator.dart:392/411`, `chapter.dart:6`,
`wizard_avatar.dart:8`). Live "available spells" is still a player's whole chapter with no
hand/deck split (`turn_loop.dart:2817`), which is why the peek-ahead gap has no live
effect *yet*. So "wire `SpellDraw` into `BattleState`" and "give `SpellDraw` its first
real use" are the same event — and this per-turn-entropy draw model should be baked in as
part of that event. Landing the fixed-order shuffle first and retrofitting later would
mean shipping the exact predictability bug into live play and then re-auditing the
determinism/replay story to remove it. Do it right the first time.

---

## 2. Design principle (one sentence)

**A draw is resolved by the entropy of the turn (or tick) that reveals it, and never
exists before that entropy does.** You know your hand; you do not know the next card
until the moment you draw it — exactly like a physical shuffled deck.

This is already how every other RNG-driven outcome in the engine behaves (movement
tiebreaks, burn targeting, summon collision all seed from `_resolveEntropy()`'s per-turn
joint entropy). We are bringing `SpellDraw` into line with the rest of the engine, not
inventing a new randomness model.

Why this is safe against look-ahead: per-turn entropy is revealed **after** all decisions
for the turn are committed (B-5 protection, `turn_loop.dart:855`). A refill draw seeded by
turn-N entropy therefore couldn't be predicted when the player committed turn-N's action,
and turn-(N+1)'s entropy does not exist yet — so peek-ahead is bounded to zero future
draws.

---

## 3. New `SpellDraw` model: draw-on-demand

Replace "pre-shuffle everything once" with "hold an unordered remaining pool; draw an
index from injected entropy at the moment of each draw."

State:
- `hand` — the current hand (≤ `bookmarkCount`), same as today.
- `remaining` — the undrawn pool, held in **canonical order** (sorted by `spellId`), *not*
  pre-shuffled. Canonical order is what makes both clients agree on which index a given
  draw-value selects.

The constructor no longer takes a single seed and no longer shuffles. Instead, each draw
takes an entropy source:

```dart
// Deal the opening hand from a seed (battle-start joint entropy). The opening
// hand is dealt at t=0 and is legitimately known to its owner — only *future*
// draws must be unpredictable.
factory SpellDraw.opening(List<SpellAsset> chapter, int bookmarkCount, HashRng rng);

// Use a spell and refill the vacated slot with a fresh draw seeded by the
// caller-supplied RNG (that turn's / that tick's entropy). Pure; returns a new
// SpellDraw. If the pool is empty the hand shrinks by one, as today.
SpellDraw useSpell(int handIndex, HashRng drawRng);
```

A single draw is: `final j = drawRng.nextInt(remaining.length); pick = remaining.removeAt(j)`.
Multiple draws in one resolution step consume the *same* `drawRng` stream sequentially, so
their order is fully determined by the (already-defined) resolution order — no ambiguity.

Key property: **`SpellDraw` becomes entropy-source-agnostic.** It never owns a seed; the
caller injects the RNG for each draw. That single change is what lets the identical core
serve both the turn-based engine (§4) and real-time sorcerer mode (§5).

---

## 4. Turn-based wiring

When `SpellDraw` is wired into `BattleState` (per player), refills happen during turn
resolution, after `_resolveEntropy()`:

- Allocate a new phase-seed domain tag for draws — **`0x05`** (0x01–0x04 are taken; see
  `_phaseSeed` call sites in `turn_loop.dart`). Bind it per player so two players drawing
  the same turn don't share a stream:
  `HashRng(_phaseSeed(entropy, matchId, turnNumber, 0x05) ‖ playerIndex)`, or fold
  `playerIndex` into the tag byte. (Pick one; §9.)
- The refill for a spell cast in turn N runs in turn N's resolution using turn-N entropy,
  so the player sees the replacement before committing turn N+1. That is the natural
  "draw a replacement card" timing and introduces no look-ahead.

Opening hand: dealt once at battle start from the existing initial joint entropy (the same
exchange that seeds turn-0 today). No protocol message changes — the per-turn
commit-reveal already runs every turn.

---

## 5. Real-time (sorcerer) wiring

`SORCERER_REALTIME_PLAN.md §4` already defines pipelined, piggybacked per-tick entropy:
an entropy-consuming event declared at tick *t* resolves from
`HashRng(joint_entropy_{t+1}, context = eventKind ‖ authorIndex ‖ tick)`, one tick after
declaration. A spell cast is exactly such an event.

Because §3 made `SpellDraw` entropy-source-agnostic, the real-time refill is the *same*
`useSpell(handIndex, drawRng)` call — the only difference is the `drawRng` seed comes from
the tick pipeline instead of `_phaseSeed`. Add a `castSpell` (draw-a-replacement) event to
the §5 event list of that plan; no new `SpellDraw` code path.

---

## 6. Auditability & replay — what changes, what doesn't

Today: one seed replays the entire draw sequence.

After: the draw sequence is replayed from **the ordered list of per-turn (per-tick) joint
entropies plus the action log** — both of which the lockstep/state-hash machinery already
requires both clients to agree on every turn. So the game stays fully auditable *after the
fact* (every entropy value is revealed and recorded), while becoming unpredictable *in
advance* (turn N+1's entropy does not exist at turn N). This is the same audit story
movement and targeting already have.

Action item: confirm the replay/record path persists per-turn joint entropy (or can
re-derive it from the recorded nonces). If match records don't yet retain the nonce
stream, note it — it's a prerequisite for post-match draw audit. **Update `SpellDraw`'s
header comment** to describe the new model; the current comment documents the exact
property we're removing.

---

## 7. Divination interaction (no regression)

`DivinationLink.spellList` (Watery Scrying Pool) reveals a target's spell list. Under the
new model the *remaining pool* is still a well-defined set that can be revealed; only its
*future order* is no longer predetermined. That is arguably more correct — scrying should
show what an opponent holds, not hand them a deterministic future. The Air-flavor
`targetTile` reveal is unaffected (it reveals a committed target tile, not draws). No
Divination code changes are required, but add a test asserting the reveal still matches
the peer's `peerBookRoot`-verified list.

---

## 8. Tests (golden-vector discipline)

Per CLAUDE.md, a randomness rule change needs vectors, not just unit tests:

1. **Determinism vector:** fixed chapter + fixed per-turn entropy sequence → both clients
   produce byte-identical hand/deck evolution over N turns. (Cross-client agreement.)
2. **Unpredictability / negative vector:** given only battle-start entropy and the chapter,
   the turn-N draw (N ≥ 2) is *not* computable — assert that changing only turn-N entropy
   changes the turn-N draw while leaving turns < N identical. This is the peek-ahead
   backstop; it is the vector that would fail under today's code.
3. **Boundary vector:** draws spanning a `remaining`-empty transition (hand shrinks) and
   multiple draws within one resolution step (stream ordering).
4. **Bias check:** `nextInt(remaining.length)` for non-power-of-2 pool sizes stays
   rejection-sampled (already true in `HashRng`; assert at pool sizes like 3, 5, 7).

---

## 9. Open calls for Soren (before coding)

1. **Per-player stream separation:** fold `playerIndex` into the `0x05` tag byte, or append
   it to the seed preimage? Both work; pick one convention and use it for the real-time
   `authorIndex` too so the two modes stay parallel. *(Recommend: append to preimage, so
   the tag byte stays a pure phase id.)*
2. **Scope/timing:** this is the draw model for the `SpellDraw`-into-`BattleState` wiring
   task (`battle_state.dart:131`), not a separate milestone — build hand/deck with
   per-turn-entropy draws from the start rather than shipping fixed-order and retrofitting.
   Confirm that's the sequencing you want, and whether the wiring itself is next up or
   still queued behind other battle work.

No `RULESET_VERSION` bump is needed unless `SpellDraw` output becomes consensus-visible in
the circuit — it is Dart-side battle state, not CA rules. Confirm that assumption holds
when wiring in.

---

## 10. Summary

The machinery already exists — per-turn commit-reveal entropy, `_phaseSeed`
domain-separation, and the real-time per-tick entropy pipeline. The whole fix is: stop
baking the draw order into one construction seed, and instead draw each card from the
entropy of the turn/tick that reveals it. One refactor to `SpellDraw` (make it
entropy-source-agnostic), one new domain tag, one event in the real-time plan, and a
vector pair. Auditability is preserved; in-advance predictability is removed.
