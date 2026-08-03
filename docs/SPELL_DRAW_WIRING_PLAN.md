# Spell-Draw Wiring Plan — making hand/deck live in battle

*Proposed 2026-07-23, revised same day. Sequel to `SPELL_DRAW_ENTROPY_PLAN.md`
(that pass fixed `SpellDraw`'s draw model; this one wires it into a running
match). Enforcement approach **decided**: the one-time chapter-creation
sortedness proof (§7) — full hand-membership enforcement, full deck privacy,
zero in-match proving. §11 lists what's still open (a proving spike +
sequencing). The structural insight in §2 is load-bearing; read it first.*

*2026-07-28 update: `bookmarkCount` below was a static `MatchConfig` value at
proposal time; it's since become per-avatar and dynamic (hand size ==
`WizardAvatar.bookmarkCount + 1`, resized mid-battle when a bookmark
accoutrement is created/destroyed — `TurnLoop._reconcileHandSize`). Every
`bookmarkCount` reference below should be read as "this avatar's current hand
size."*

---

## 1. Scope

Turn today's "available spells = your whole chapter" into a real hand/deck: a
player casts from a `bookmarkCount`-sized hand, and each use refills from the
deck via the per-turn-entropy draw already built in `SpellDraw`. Three live
call sites currently stubbed on "SpellDraw is unwired" get real behaviour:

- **A.** Cast validation (`turn_loop.dart` §3 book membership, `_verifyPeerSpellCast`).
- **B.** Divination Water flavor — "see target's available spells"
  (`_exchangeSpellRevealOpenings`, `spell_effect.dart:527`).
- **C.** FuelTransmutation wither/reactivate stubs (`effect_applicator.dart:392,411`).

Two-part delivery: the **Dart-side wiring** (all of the above, ship-able on its
own with soft enforcement as an interim) and the **one-time sortedness circuit**
(§7) that upgrades it to full enforcement. The circuit is a small, self-contained
Noir spike (§11) that can land second without reworking the wiring — the cast
already carries everything the enforcement check needs.

Out of scope: the pre-battle chapter-selection UI (still a fixture/stub —
`chapter.dart:60`).

---

## 2. The structural insight: contents are secret, positions are public

Only the chapter Merkle **root** (`peerBookRoot`) crosses the wire at handshake —
never the chapter's contents. So a client cannot see *which spell* another player
holds where. But it can see **where every draw lands**, and that split is what
makes the whole design work:

- **A draw is a permutation of *positions*, and positions are public.**
  `SpellDraw.useSpell` picks `drawRng.nextInt(remaining.length)` — an index into
  the pool. The pool is always "the sorted chapter minus already-drawn," so
  *which positions* are drawn each turn is a pure function of the (public,
  per-turn) entropy. Card **contents never enter the index arithmetic.**
- **Position ↔ card is pinned by the sorted Merkle tree.** `book_commitment.dart`
  builds the tree over the chapter's `commitmentHex` leaves **sorted**, and a
  cast's `MembershipProof.directions` authenticates the leaf's **index** in that
  sorted tree. So a revealed cast proves not just "this is a chapter spell" but
  "this is the spell at position *p*."
- **Therefore both clients can track the *position* bookkeeping of every hand —
  which positions are in-hand, drawn, or withered — from public data alone,
  while the *contents* at those positions stay secret** until a card is actually
  cast.

This yields four consequences that drive everything below:

1. **Two kinds of draw state, split by secrecy.**
   - *Contents* (which `SpellAsset` sits at each position): **local-only**, on
     `TurnLoop`, never in the state hash — the peer can't reproduce it.
   - *Positions* (the in-hand / drawn / withered index sets): **publicly
     computable by both clients** from the entropy stream + the public cast/effect
     log. This is the bookkeeping that enforcement runs against.

2. **Hand-membership *is* enforceable** — a cast's authenticated position must lie
   in the publicly-computed in-hand set. The one crack is that a malicious client
   could build its root over *un-sorted* leaves, mapping strong cards onto
   early-drawn positions. The one-time sortedness proof (§7) closes exactly that
   crack; with it, enforcement is complete and needs **no in-match proving**.

3. **The canonical order that `SpellDraw` uses MUST equal the Merkle leaf order.**
   Today they differ: `Chapter`/`SpellDraw` sort by `spellId` (`chapter.dart:53`),
   but `book_commitment.dart` sorts by `commitmentHex`. For a drawn *position* to
   equal a Merkle *leaf index*, both must sort by the **same key**. Reconcile to
   `commitmentHex` (the leaf value itself is the natural canonical key) — a small
   change to `Chapter`'s sort and `SpellDraw`'s "canonical order" comment, but
   load-bearing: get it wrong and every enforcement check is off-by-permutation.

4. **Hand mutations run on the owning client for *contents*, but their *position*
   selection is computed identically on both** — see §9's determinism note, which
   changes from the earlier soft-only framing.

---

## 3. Where state lives & its lifecycle

Split per consequence 1:

```dart
// On TurnLoop — the local player's live hand/deck CONTENTS. Null until the
// chapter resolves (async post-construction, like localChapterSpells).
// Local-only: never serialized into the state hash.
SpellDraw? localSpellDraw;

// The POSITION bookkeeping — in-hand / withered index sets per player. Derived
// deterministically from public entropy + the public action log, so BOTH
// clients compute the same thing for BOTH players. Recommended: factor the
// index arithmetic out of SpellDraw into a small `DrawSchedule` (operates on
// int positions only) that both clients run; the local client maps positions →
// SpellAssets through its own chapter for contents/UX.
```

- **Deal** where `localChapterSpells` is set today (`battle_screen.dart:508` /
  `TurnLoop._init*`): `localSpellDraw = SpellDraw.opening(chapter.spells,
  config.bookmarkCount, HashRng(openingSeed))`, with `chapter.spells` sorted by
  `commitmentHex` (consequence 3). The `DrawSchedule` opening is dealt from the
  same seed and leaf count on both clients.
- **Opening seed** = the battle-start joint entropy (`BATTLE_PROTOCOL.md §0`:
  `exchangeNonce` → "joint entropy seeds the SpellDraw shuffle"). **The deal MUST
  run before turn 1's action commit** — turn 1 is fully castable like any other
  turn (Soren, 2026-07-23), so the opening hand must exist when the UI presents
  the turn-1 action, i.e. before the first `beginTurn`.
  **DONE (2026-07-23).** The battle-start `exchangeNonce` was specified in
  BATTLE_PROTOCOL §0 but never implemented, so `_dealOpeningHandsIfNeeded` had
  been dealing mid-turn-1 (after the Phase-3 reveal), leaving turn 1 with no
  castable hand. Implemented as `TurnLoop.startBattle()` — one battle-start
  commit-reveal (`_resolveEntropy`, the same round `runTurn` runs every turn),
  placed ahead of the loop; it deals both opening hands from that joint entropy.
  `battle_screen` awaits it in its init sequence (`_startBattleIfNeeded`, gated
  behind both `_loopConstructed` + `_spellsLoaded`) and only flips `_loopReady`
  once it completes, so the spinner holds until turn 1 has a full hand. Idempotent;
  `runTurn`'s deal stays as a turn-1 fallback for headless tests. Verified: two
  `TurnLoop`s over a paired `BattleSession` deal the opening hand before any
  `runTurn` (`spell_draw_wiring_test`). No look-ahead risk — the opening hand is
  the owner's own cards, and the peer's *contents* stay uncomputable.
- **Chapter leaf count `n` must be public** for the `DrawSchedule` to compute
  `nextInt(n)`: declare it at handshake alongside `peerBookRoot`. Minor
  disclosure (how many spells are in the chapter), and plausibly already implied
  by match config.
- **Solo/practice:** the scripted dummy has no real chapter and never casts from
  a hand, so its draw state stays null — no peer bookkeeping needed.

---

## 4. Wiring B: refill on local cast

- **When:** immediately after the local player's cast is committed to resolution
  — once `myAction` is a real `SpellCastAction`/`MysterySpellCastAction` that
  passed local affordability, inside/next to `_resolveActions`. Refill:
  `localSpellDraw = localSpellDraw!.useSpell(handIndex, drawRng)`, and advance the
  shared `DrawSchedule` for that player by the same position draw.
- **`handIndex`:** the UI selects from `localSpellDraw.hand`; the local action
  carries which hand slot was used. This never crosses the wire — what the peer
  verifies is the cast's *authenticated leaf position* (from the membership
  proof), which it maps back to the in-hand set itself.
- **`drawRng`:** `HashRng(_phaseSeed(entropy, matchId, turnNumber, 0x05))` with
  the player index appended to the seed preimage (per `SPELL_DRAW_ENTROPY_PLAN.md
  §9`; `0x05` is the next free tag after 0x01–0x04). Both clients derive this
  identically for the `DrawSchedule`; the local client additionally uses it for
  contents. Timing is inherently safe: `entropy` is turn-N's, revealed in Phase 3
  *after* the Phase-1 action commit, so the refill can't be foreseen at cast time.
- **Per-draw discriminator — DONE (2026-07-23).** The `(turn, player)` seed is
  unique for the turn-based engine's one-draw-per-turn, but **real-time/sorcerer
  mode casts as fast as mana + input allow** (Soren), so a player draws many
  times within one entropy window and the bare seed would collide every rapid
  draw onto the same RNG stream. Implemented a monotonic per-player draw counter
  (`_consumeDrawNonce` / `_drawSeedNonce`) folded into both the refill (0x05) and
  wither (§9, 0x06) seed preimages via `_playerPhaseSeed`'s new `drawNonce` arg;
  both clients increment it in the same lockstep resolution order, so it stays in
  sync (turn-loop determinism tests guard that). When sorcerer mode lands, swap
  the whole seed to `SORCERER_REALTIME_PLAN.md §4`'s tick pipeline
  (`HashRng(joint_entropy_{t+1}, context = eventKind ‖ authorIndex ‖ tick)`),
  which carries the tick+event discriminator natively — the counter is the
  turn-based stand-in until then.

---

## 5. Wiring C: UI seam

- `battle_screen.dart`'s `_spells` (today the whole resolved chapter, shown in
  `_SpellBook`) becomes `_loop.localSpellDraw?.hand ?? []`. The "Spell hand" label
  finally matches reality.
- Deck count (`localSpellDraw.remaining.length`) is a nice small HUD readout;
  optional this pass.
- Withered hand spells (§9) render greyed + unselectable; `_selectSpell` refuses
  them.

---

## 6. Wiring A: cast validation with the in-hand check

`_verifyPeerSpellCast`'s existing checks are unchanged (proof, commitment,
enhancement claims, chapter membership, authorization, mana). Add **one check**:
the cast's authenticated leaf position (already carried in `MembershipProof.
directions`) must be a member of the caster's **publicly-computed in-hand
position set** for this turn, and not withered. On failure:
`forfeit('cast_out_of_hand')`.

No new wire format — the membership proof already authenticates position; the
in-hand set is derived locally by both clients from the `DrawSchedule`. The only
piece that makes this *sound* rather than *advisory* is the guarantee that the
peer's tree is genuinely sorted, so position *p* really is the *p*-th smallest
card and can't have been arranged. That guarantee is §7.

**Interim (before the §7 circuit lands):** ship the in-hand check anyway. Against
an honest client it's fully correct; against a malicious client it's soft (a
cheat could reorder its tree). This is the *same* residual boundary already
accepted for the Divination reveal (`turn_loop.dart:2820`), and §7 upgrades it to
hard without touching the wire.

---

## 7. Enforcement backstop — the one-time sortedness proof — DECIDED

**Decision (2026-07-23):** enforce hand-membership via a one-time,
chapter-creation ZK proof that the committed tree is well-formed. Chosen over
(a) soft-only and (b) a per-draw / per-battle draw proof, because it gives full
enforcement **and** full deck privacy at **zero in-match proving cost**.

**What it proves, once, when a chapter is created:** the Merkle root `R` commits
a leaf set that is *strictly sorted by `commitmentHex` and duplicate-free*.
That's the entire missing guarantee. With it, §2's positional machinery is
honest forever, for every battle that chapter ever plays.

**Why this is cheap where it counts:**
- **In-match: no proving at all.** Draws are index arithmetic; casts already
  carry a Merkle path (SHA-256 hashing, microseconds); the in-hand check (§6) is
  public-set membership. **Real-time sorcerer mode with rapid replacement is
  unaffected** — nothing is added to the tick loop. (A *per-draw* ZK proof, by
  contrast, would blow the 250 ms micro-tick budget — which is why we're not
  doing that.)
- **One-time cost, off the gameplay path — measured, GO.** It runs once, when you
  build/edit a chapter, and is reused across every match. Binding to `peerBookRoot`
  forces **SHA-256** reconstruction in-circuit (the book tree can't use cheap
  Poseidon2 — Dart builds membership proofs over it and can't reimplement
  Poseidon2, invariant 1), so cost was a genuine unknown. `docs/SORTEDNESS_
  CIRCUIT_SPIKE.md §11` settled it: N=32 and N=48 land in **CA tier-12's padded
  bucket** (2^19; the cheapest, most-validated proving tier), N=64 one bucket up —
  none near tier-48. **GO on Option A**, binding directly to the Merkle root, no
  cost-forced size cap (N=48 is the natural line if a cap is wanted for game-design
  reasons). On-device proving time is a follow-up confirmation, not a blocker.

**Deck privacy:** un-cast, un-seen spells are **never revealed** — cast cards are
opened in-match via their Merkle path; everything else stays behind the root for
life. (The alternative non-ZK audit — reveal the whole sorted leaf list at match
end via the existing `hashLeaves` "Option 2 batch hash" — would confirm sortedness
too, but only by leaking the entire deck. The one-time proof is what buys privacy.)

**Consensus-visibility / versioning:** this introduces a **new circuit and its
own VK**, plus a consensus-visible cast-acceptance rule (the in-hand check).
Coordinate it like any VK-breaking change: the two clients must agree they're
both enforcing it. Whether it rides `RULESET_VERSION` (currently CA-rule-scoped)
or a sibling protocol-version field is a detail to settle when the circuit lands;
nothing has shipped, so the bump is cheap. Chapter assets created before the
proof exists would need a (cheap, one-time) re-commit to carry the sortedness
witness.

---

## 8. Divination Water reveal target — DECIDED (2026-07-23): reveal the hand

Soren confirmed the intended effect is to reveal the target's **current hand**,
not the whole chapter. Change `_exchangeSpellRevealOpenings` so the responder
sends `localSpellDraw.hand` instead of `localChapterSpells`; per-spell
chapter-membership verification against `peerBookRoot` is unchanged (every hand
spell is a chapter member). Transport is unchanged — still a list of
chapter-member spells, just the in-hand subset.

Under §7's enforcement, this reveal is also position-checkable: the revealed
hand's positions must equal the target's publicly-computed in-hand set, so a
cheat client can't under-report its hand either.

---

## 9. Wiring C detail — FuelTransmutation wither/reactivate

Both stubs operate on the caster's own hand. Split by secrecy, per §2:

- **Fire flavor (`witherSpellCount`):** mark N hand *positions* "withered"
  (unusable until reactivated). The *artifact-grant* half of this flavor is
  unchanged (it mutates shared `accoutrements`, already hashed, already using the
  shared `ctx.rng` — leave it alone).
- **Earth flavor (`reactivateSpellCount`):** clear the withered flag on N
  withered hand positions.
- **Model:** the withered set is **positions**, tracked in the `DrawSchedule` on
  both clients. Contents at those positions stay secret; the local client also
  flags the matching `SpellAsset`s in `localSpellDraw` for its UI.

**The determinism note (revised from the soft-only framing):** because a
FuelTransmutation cast and its certified `witherSpellCount` are public, the
withered *positions* are computable on **both** clients — so this is now
cross-client-deterministic bookkeeping, not a caster-only local mutation. Compute
it identically on both sides from a **dedicated RNG** —
`HashRng(_phaseSeed(entropy, matchId, turnNumber, 0x06) + playerIndex)` — kept
**separate from the shared `actionRng` stream** so it can't desync the shared
draws. Enforcement of "can't cast a withered card" is then just the §6 in-hand
check extended to exclude withered positions.

---

## 10. Tests

1. **Canonical-order reconciliation (consequence 3):** a chapter whose `spellId`
   order differs from its `commitmentHex` order draws the position that the
   Merkle leaf index predicts — the regression guard for the sort-key seam.
2. **Opening deal + refill through a real turn:** a local cast refills the hand
   from the deck using that turn's entropy; deck shrinks; hand size holds until
   the deck empties.
3. **Lockstep unaffected:** a two-client turn where one side casts produces
   identical `toCanonicalBytes()` on both sides — hand *contents* never enter the
   ledger.
4. **In-hand enforcement (§6):** a cast whose authenticated position is not in the
   public in-hand set is rejected (`cast_out_of_hand`); an in-hand cast is
   accepted. Both clients compute the same in-hand set.
5. **FuelTransmutation determinism (§9):** withered positions match on both
   clients; the dedicated wither RNG leaves the shared `actionRng` at the same
   position on both (e.g. a following summon-collision draw matches).
6. **Withered-cast refusal:** a cast of a withered position is rejected;
   reactivate restores castability.
7. **Divination reveal (§8):** an active Water link reveals exactly the target's
   hand; positions match the public in-hand set; each entry verifies as a chapter
   member; the reveal clears at end of turn.
8. **Sortedness circuit (§7), when it lands:** positive vector (honest sorted
   tree verifies) + negative vector (a tree built over deliberately un-sorted or
   duplicate leaves is rejected) — the golden-vector pairing CLAUDE.md requires.

---

## 11. Open items & sequencing

1. **Sortedness circuit spike (§7):** **DONE — GO** (`docs/SORTEDNESS_CIRCUIT_
   SPIKE.md §11`). Measurement crates `circuits/book_sortedness_n{32,48,64}/`
   + a bit-parity pin, all vectors behaving. Cost lands in CA tier-12's bucket
   (N≤48). Remaining before this can enforce: (a) an on-device proving-time
   confirmation, (b) turning the measurement crates into a single production
   circuit + its VK/handshake wiring, (c) the versioning-field decision
   (RULESET_VERSION vs a protocol-version sibling), and (d) a vector with
   high-half-differing / realistic leaves (the spike's positive vectors use
   small integers, so all have hi=0 — the `leaf_lt` hi-branch is currently
   untested by a vector; correct-by-reading, but pin it before production).
   All four are scoped in `docs/SORTEDNESS_PRODUCTIONIZING_BRIEF.md` (its §8
   lists the decisions Soren still needs to make). **The Dart wiring itself
   (§§3–9) is done** — `DrawSchedule`, `_advanceDrawState`, the §6 in-hand
   check, and the §8/§9 reveal+wither paths, all with the interim soft
   enforcement live; the productionizing brief only adds the crypto that makes
   the check hard.
2. **Sequencing:** the Dart wiring (§§3–6, 8, 9) is self-contained and can ship
   first with §6's interim soft check; the §7 circuit upgrades it to hard
   enforcement without reworking the wire. Is the wiring next up, or queued? It
   changes the felt game (hand size, deck-out, withering all become real), so it
   wants at least one `flutter run -d linux` pass and ideally a two-device run
   before it's called done (verification hierarchy, CLAUDE.md).

Settled this session: enforcement approach (§7, sortedness proof) and Divination
reveal target (§8, reveal hand).
