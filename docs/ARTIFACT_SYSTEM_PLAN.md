# Artifact System Rework — Implementation Plan

*Target implementer: Sonnet. Written 2026-07-30 on `feature/practice-mode`. Source of design
truth: `docs/runewright_design_v3_0.md` §artifacts (L509–518) as amended by the ratified
decisions in §2 below. Eight decisions were ratified by Soren in the design conversation of
2026-07-30; none of them are open. Two rulings I made on his behalf are flagged in §3 —
review those before building on them.*

*Read `CLAUDE.md` first. Nothing here touches the CA, the circuit, `stepper.dart`, or the
golden corpus, so **no `RULESET_VERSION` bump is required**. It does change the battle wire
protocol and `BattleState.toCanonicalBytes()`, which is its own compatibility break — see §6.*

---

## 1. What this builds

Every artifact becomes **passive + one consumable activation**. At most one artifact may be
activated per player per turn, declared in a new public pre-action phase. The 12-slot loadout
stops being a static stat block and becomes a depleting resource pool.

| Artifact | Passive | Activation (consumes it) |
|---|---|---|
| **Mana Gem** (Water) | +100 max mana, +10 regen/turn *(unchanged)* | Instantly restore 100 mana |
| **Bookmark** (Earth) | +1 hand size *(unchanged)* | Redraw entire hand next turn |
| **Rod of Spreading** (Air) | 10%/rod for +1 movement next turn | +1 effect radius on next cast *(unchanged)* |
| **Counter Charm** (Fire) | 5%/charm for melee to destroy a gem or wither a spell | Auto-fires on its attuned spell *(unchanged)* |

Two properties do the design work, and everything below serves them:

- **Activation is public, and it happens before actions are committed.** This is the whole
  point. A player who spends an artifact this turn has their counter charms disabled for the
  turn, and the opponent *sees this in time to act on it*. That window is the game.
- **Artifacts deplete.** A long match grinds both wizards down. Late-game wizards are weaker
  than early-game ones, by design.

### Explicitly out of scope

- **Absorption Rods / Deflection Totems.** They are summon-only (`AccoutrementKind` has
  entries, `ArtifactKind` does not) and have no loadout presence. They keep their current
  behavior and get no passive/active split. Do not touch them.
- Changing the 12-artifact loadout budget, or the loadout-selection UI beyond what §10 names.
- Rebalancing the Water-Earth Burn effect, which remains the other artifact-attack vector.
- Any change to the circuit, `CIRCUIT_IO.md`, or the golden vectors.

---

## 2. Ratified decisions (do not re-litigate)

**2.1 — Activation is declared in a new public Phase 0, before the Phase 1 action commit.**
Rejected alternative: keeping it as a flag inside the action commit. Under that scheme the
opponent learns your guard is down at the same instant they'd already have committed their
spell, so the information arrives too late to act on and the entire mind game is decorative.

**2.2 — The charm holder's *own* activation disables their *own* charms for that turn.**
Not the caster's. The tension is internal to the charm holder: *"do I want that 100 mana
badly enough to open a window this turn?"*

**2.3 — The counter charm's passive is an anti-caster melee proc.** Each unspent charm gives
5% (linear, so `n` charms = `n × 5%`) for a successful melee attack to destroy one of the
victim's mana gems or wither one of their in-hand spells. This replaces the earlier proposal
of a 1% chance to negate an incantation, which was rejected as swingy, invisible, and
unlearnable. The passive exists to make an Eldritch Knight / Mage Slayer archetype real:
dump all 12 slots into charms, run on the innate 100 mana pool with no gems at all
(meditating when you need a refill), spend your limited casting on cheap self-buffs, and
force mages into a kiting game.

**2.4 — A charm that fires its counter is spent and stops contributing to the melee proc.**
60% → 55% → 50% as you counter things. Without this the 12-charm build gets full counter
coverage *and* a full proc rate for free; with it, the archetype self-limits.

**2.5 — A melee proc withers a spell, it does not destroy the bookmark.** Withering uses the
existing `DrawSchedule.withered` set and is reversible via Earth's existing "reactivate 1
withered spell." Gems die permanently; hand slots do not. The asymmetry is deliberate — gems
are the engine, hand disruption is tempo.

**2.6 — Melee-inflicted wither lasts until reactivated.** Identical to FuelTransmutation
Fire's existing behavior. No duration bookkeeping, no new mechanic.

**2.7 — Burning a bookmark redraws the whole hand, effective next turn.** Declared at Phase 0,
resolves at Phase 6, new hand available the following turn. The base non-bookmark slot
reshuffles too. Old spells can return — they go back in the pool before the redraw. Price:
one permanent hand slot plus a full turn of tempo.

**2.8 — The rod's movement passive is 10% per rod, rolled at Phase 6 for the following turn.**
Rejected: 1%, which over a 20-turn match with 4 rods is ~0.8 tiles — a rounding error that
still costs a determinism surface and untestable tests. The Phase-6 timing is not optional:
movement is committed in Phase 2 and entropy arrives in Phase 3, so a bonus rolled from the
current turn's entropy is unknowable when the movement decision is made.

### Derived rulings that follow from the above

- **Every gem is activatable, including the last one.** The core gem was removed 2026-07-30:
  the mana pool is innate (`MatchConfig.innateManaPool`, default 100) and
  `accoutrementsFromArtifacts` inserts nothing, so there is no indestructible instance to
  carve out. Spending your last gem drops you to the innate pool with zero passive regen —
  a real cost, self-inflicted, which is exactly the trade this activation is meant to be.
  The melee proc has the same reach for the same reason.
- **A charm auto-firing does not consume the once-per-turn activation budget.** The budget is
  spent at Phase 0 declaration; the charm fires at Phase 5. They can never collide, because
  declaring anything at Phase 0 disables your charms for that turn (§2.2).
- **The mage slayer is never off-guard**, since an all-charm loadout has no voluntary
  activation available. This is a feature, not a gap. The bluffing game is a mage's minigame.

---

## 3. Rulings I made on Soren's behalf — review before building

**3.1 — A Mystery (delayed) spell's rod is declared on the turn it *fires*, not the turn it
was committed.** `PendingDelayedSpell` currently carries `isRodOfSpreading` through from
commit time ([turn_loop.dart:373](../lib/battle/engine/turn_loop.dart#L373)). Moving rod
declaration to Phase 0 forces a choice, and firing-turn is the consistent one: every other
activation is declared on the turn it takes effect. It also means a delayed spell can't
reserve a rod for three turns while you spend your activation budget elsewhere. **Consequence
if wrong:** the field stays on `PendingDelayedSpell` and the Phase-0 declaration is
ignored for delayed fires.

**3.2 — Rod passive is one roll at `min(n × 10, 100)%`, not `n` independent rolls.** "Each
adds a chance" reads as cumulative probability of a single +1, not a chance at multiple tiles.
One roll is one RNG draw, which is simpler to keep deterministic and to test. Note this makes
10+ rods a guaranteed +1 every turn — an archetype-defining passive parallel to the mage
slayer, which I believe is intended.

---

## 4. The architecture: Phase 0

### 4.1 There is already a precedent for this, and it should be followed

The codebase has solved this exact problem shape once already. Dash's flag is folded into the
**movement** commit-reveal rather than the action commit-reveal, specifically so both clients
know each other's dash status before movement resolves — see the wire-encoding comment at
[turn_loop.dart:89-97](../lib/battle/engine/turn_loop.dart#L89-L97). Artifact activation has
the same requirement (public before a later decision is committed) and gets the same
treatment: its own earlier exchange.

### 4.2 Phase 0 runs commit-reveal, not a plain exchange

It must be commit-reveal, mirroring the melee round at
[turn_loop.dart:1308-1335](../lib/battle/engine/turn_loop.dart#L1308-L1335) exactly. The
declaration is public *after* the exchange, but simultaneity still has to be enforced: with a
plain send-then-await, a peer can stall, read your declaration, and then choose theirs. That
is a strategic advantage, so it needs the same protection as every other simultaneous
decision in the turn.

Sequence, inserted before the Phase 1 action commit at
[turn_loop.dart:1183](../lib/battle/engine/turn_loop.dart#L1183):

1. Prompt the local player via a new `ArtifactActivationPicker` typedef (shape it like
   `MeleeTargetPicker` at [turn_loop.dart:443](../lib/battle/engine/turn_loop.dart#L443),
   with a default that declares nothing, so tests and solo mode need no changes).
2. `commit = SHA-256(activation_bytes ‖ nonce)`, `exchangeArtifactActivationCommit`.
3. `exchangeArtifactActivationReveal`, then `_verifyReveal(..., 'artifact')`.
4. Validate the peer's declaration (§5), then apply both, in sorted-`playerId` order.

### 4.3 Wire encoding

```
No activation: [0x00]
Activation:    [0x01][kind:1]
```

`kind` is the `AccoutrementKind` index. **The declaration names a kind, never a specific
accoutrement id.** The engine picks *which* instance is consumed by sorting the owner's
accoutrements by id and taking the first match — the determinism convention already used by
`_findCounteringCharm` ([turn_loop.dart:2930-2946](../lib/battle/engine/turn_loop.dart#L2930-L2946)).
This removes a whole class of trust bug: a peer cannot name an id it does not own, because it
does not get to name an id.

`counterCharm` is never a legal declared kind (charms self-trigger). `manaGem` is a valid
declaration whenever the declarer holds any gem at all — see §5.

### 4.4 Turn-scoped activation state

`Set<String> _activatedThisTurn` (player ids), populated at Phase 0, cleared at end of turn.
Per this file's existing convention, per-turn scratch lives in locals rather than fields where
possible — but the counter-charm gate needs it at Phase 5, so it must survive the turn. Follow
whatever `_pendingAction` does for lifetime discipline.

`_findCounteringCharm` gains a guard: **skip any charm whose owner is in `_activatedThisTurn`.**
Note this correctly covers the caster's own charms too, since that method deliberately
searches all avatars including the caster.

---

## 5. Trust boundary

`_consumeRodOfSpreading` already flags itself as the peer trust boundary
([turn_loop.dart:2737-2755](../lib/battle/engine/turn_loop.dart#L2737-L2755)) — a lying peer
claiming a rod it does not hold. Every declared activation now needs that same treatment, in
**one** validation path, not two. This is the B-1/B-8 lesson from `CLAUDE.md`: do not
reintroduce a second path.

A peer's Phase-0 declaration is valid only if all of the following hold. Any failure means the
declaration is **discarded and treated as no-activation** — not an error, not a disconnect,
since a desync here would be indistinguishable from a stale client.

- The declared kind is `manaGem`, `bookmark`, or `rodOfSpreading`. Never `counterCharm`,
  never a summon-only kind.
- The declaring avatar holds at least one accoutrement of that kind. (No sub-filter for
  `manaGem`: every gem is consumable now that the core gem is gone.)
- That avatar has not already declared this turn.

The local player's own declaration goes through the identical check. Write it once, call it
for both.

---

## 6. Determinism and the state hash

**This is the top desync risk in the feature.** Three things need care.

### 6.1 A pre-existing latent desync in the melee round, which this feature makes routine

The melee round applies haymakers **local-first, then peer**
([turn_loop.dart:1344-1350](../lib/battle/engine/turn_loop.dart#L1344-L1350)) — so device A
applies A-then-B and device B applies B-then-A. Both draw from the *same* shared `meleeRng`.
Today this is narrow: `_applyHaymaker` only touches the stream via `_redirectIfIllusion`
([turn_loop.dart:4708-4723](../lib/battle/engine/turn_loop.dart#L4708-L4723)), which
early-returns without drawing unless the target holds active illusions. So a divergence needs
*both* players to melee in the same turn *and* an illusion in play — rare enough that it has
never been caught.

**The counter-charm proc makes every melee draw from that stream.** Any turn with two melees
would then desync. Fix this first, as a standalone commit, before adding the proc: sort the
melee applications by `playerId` the way `_findCounteringCharm` does. It is a real bug on its
own and it deserves its own test.

### 6.2 `maxMana` is stored, not derived

`WizardAvatar.maxMana` is a plain field; `maxManaFor(config)` only *computes* the pool. So
removing a gem — by activation *or* by melee proc — must recompute and assign `maxMana`, then
clamp `mana` down to the new max. Do not assume removing the accoutrement is sufficient.
`EffectApplicator._syncMaxMana` is the existing helper that does exactly this for burns;
reuse that shape rather than open-coding `maxMana -= 100`.

For the activation specifically, the order is **lower the max first, then grant**:
`maxMana -= 100; mana = min(mana + 100, maxMana)`. This makes the gem burst worthless when
you are already near full — correct, it is an emergency button. `_grantMana` already clamps
to `maxMana` ([turn_loop.dart:2547](../lib/battle/engine/turn_loop.dart#L2547)), so reuse it
*after* decrementing the max.

### 6.3 `toCanonicalBytes` must cover the new state

`BattleState.toCanonicalBytes()` already serializes each accoutrement's id, kind index,
`counterCharmRevealed`, and target
([battle_state.dart:214-229](../lib/battle/models/battle_state.dart#L214-L229)). Accoutrement
*removal* is therefore already covered for free — the list shortens on both devices.

What is **not** covered and must be added: the per-turn activation set, since it gates
counter-charm firing at Phase 5 and both devices must agree on it. Serialize it as part of
the avatar record (a `uint8` flag) rather than as a separate section, so the sort order is
already established.

Do not reorder `AccoutrementKind` — its ordinals are hashed. Nothing here requires a new kind.

### 6.4 New phase-seed tags

Tags `0x05`–`0x08` are taken (see
[turn_loop.dart:1575-1583](../lib/battle/engine/turn_loop.dart#L1575-L1583)). Allocate:

- `0x09` — bookmark-burn hand redraw, per-player, via `_playerPhaseSeed`.
- `0x0A` — rod movement-passive roll, per-player, via `_playerPhaseSeed`.

The melee proc needs **no new tag** — it draws from the existing `meleeRng`, which is already
a joint-entropy stream sequenced at the right point in the turn. That is the single cheapest
thing about this feature; do not invent a new stream for it.

---

## 7. Build order

Six commits, each independently testable. Do not reorder — 7.1 is a prerequisite for 7.5, and
7.2 is a prerequisite for everything else.

1. **Melee RNG ordering fix** (§6.1). Standalone bug fix, own test, no new features.
2. **Phase 0 scaffolding** — session methods, wire encoding, picker typedef, validation,
   `_activatedThisTurn`, canonical-bytes coverage. No artifact actually does anything yet;
   the test is that a declaration round-trips, validates, and gates charms.
3. **Counter-charm gate** (§2.2) — `_findCounteringCharm` skips gated owners.
4. **Mana gem activation** (§6.2). Smallest real activation; proves the Phase-0 plumbing.
5. **Rod migration + rod passive** — move `isRodOfSpreading` off the action commit onto the
   Phase-0 declaration (§3.1), then add the Phase-6 movement roll (§2.8).
6. **Bookmark burn + counter-charm melee proc** — the two that need new draw machinery.

---

## 8. Per-file changes

### 8.1 `lib/battle/networking/battle_session.dart` + `battle_wire.dart`

Add `exchangeArtifactActivationCommit` / `exchangeArtifactActivationReveal` to the
`BattleTurnSession` interface (alongside the melee pair at
[battle_session.dart:105-106](../lib/battle/networking/battle_session.dart#L105-L106)) and two
new message tags in `battle_wire.dart`. Every existing `BattleTurnSession` implementation and
test fake needs the new methods — grep for `exchangeMeleeCommit` to find them all.

### 8.2 `lib/battle/engine/turn_loop.dart`

The bulk of the work. In turn order:

- **Phase 0** (new, before L1183): picker, commit-reveal, validation, application.
- **`_findCounteringCharm`** (L2930): gate on `_activatedThisTurn`.
- **Phase 4b melee** (L1344): sort by `playerId` (§6.1); add the proc after damage lands.
- **`_applyHaymaker`** (L2573): new proc block, or a sibling method called from the same site.
  Prefer a sibling — `_applyHaymaker` is already doing four things.
- **`_consumeRodOfSpreading`** (L2743): source the request from Phase 0 rather than the action
  flag; keep the method as the single consumption path.
- **Phase 6** (L2962 `_endOfTurn`): bookmark redraw, rod movement roll. The rod's status
  effect must be added **after** `tickStatusEffects` runs, or it expires before it is usable —
  `remainingTurns: 1` added post-tick survives to next turn's Phase 2 and is cleaned up by the
  following Phase 6.
- **Action wire encoding** (L73-85 comment block, and the encode/decode at L3796/L4064): drop
  `isRodOfSpreading`. Update the comment — it is the de-facto protocol spec.

### 8.3 `lib/battle/engine/draw_schedule.dart` + `spell_draw.dart`

`DrawSchedule` needs `redrawHand(HashRng)`: return every in-hand position to `remaining`,
clear their withered flags, then draw a fresh full hand. `SpellDraw` needs the mirroring
method for the local player, exactly as `addSlot`/`removeSlot` are mirrored today
([turn_loop.dart:819-822](../lib/battle/engine/turn_loop.dart#L819-L822)).

For the melee proc's wither: **there is no bookmark→hand-position mapping.** `handSize` is
`bookmarkCount + 1` and `DrawSchedule.hand` is a flat position list; no bookmark "owns" a
slot. So "wither a bookmarked spell" is implemented as *wither a uniformly-chosen in-hand,
non-withered position*. This is the correct reading and needs no new data structure.

### 8.4 `lib/battle/models/wizard_avatar.dart`

Add `activeCounterCharmCount` (unspent charms only — `!counterCharmRevealed`), which is what
the proc rate keys off per §2.4. §5's validation needs no new gem getter — the existing
`manaGemsEquipped` is the whole test now that every gem is consumable. Extend the doc comment at the top of the file: it currently describes the
pre-rework artifact behavior and will otherwise be actively misleading.

### 8.5 `lib/battle/models/battle_state.dart`

Serialize the activation flag (§6.3).

---

## 9. Tests

Follow the existing per-feature layout — `test/battle/engine/counter_charm_test.dart` and
`rod_of_wind_test.dart` (renamed from `rod_of_spreading_test.dart` 2026-07-31, alongside the
"Rod of Wind" terminology sweep) are the models to extend rather than replace.

**Determinism (highest value, write these first):**
- Two `TurnLoop`s with swapped local/peer perspectives produce identical state hashes across a
  turn where **both** players melee and both have illusions in play. This is the §6.1
  regression test and it should fail before that fix lands.
- Same swapped-perspective assertion for a turn where both players declare activations.

**Trust boundary (§5):** a peer declaring a kind it holds none of; a peer declaring
`counterCharm`; a peer declaring `manaGem` while holding no gem; a peer declaring twice. Each must degrade to no-activation with both devices agreeing.

**Per-artifact:**
- Gem: burst at full mana is a near-no-op; `maxMana` drops by exactly 100; `mana` is clamped
  when it exceeded the new max; spending the last gem lands on the innate pool (100) and
  zero regen rather than being blocked.
- Charm gate: a charm that would fire does not fire on a turn its owner activated something;
  it still fires the following turn.
- Charm decay (§2.4): proc rate drops after a charm fires.
- Proc: victim with no destructible artifacts and no witherable position → fizzles cleanly.
- Bookmark burn: hand size drops by one; the new hand may legally contain previously-held
  spells; burning the last bookmark still redraws the remaining single slot.
- Rod: passive rolls at Phase 6 and is readable during the *next* turn's Phase 2.

**Device pass.** Per `CLAUDE.md`'s verification hierarchy, the Phase-0 exchange is a new
network round trip and needs at least one two-device run before this is called done. A
green test suite is not sufficient evidence for a protocol change.

---

## 10. UI

`lib/ui/battle_screen.dart` (3.5k lines) needs, at minimum:

- A Phase-0 activation prompt: available artifacts with counts and spent state. Spending
  your last gem is legal, so the prompt should make the resulting pool/regen loss legible
  rather than blocking it.
- A clear **"your counter charms are down this turn"** indicator once an activation is
  declared. If a player can activate a gem without realizing they just opened their guard,
  the entire mechanic reads as a bug rather than a trade.
- The opponent's declaration, surfaced before the action commit. This is the information the
  whole design exists to deliver — if it is not legible, nothing above matters.
- Rod activation moves out of the cast flow into the Phase-0 prompt.

---

## 11. Doc updates

`docs/runewright_design_v3_0.md` §artifacts (L509–518) describes the pre-rework system and
must be rewritten to match §1's table. While there, resolve the stale
`[DECISION — needs Soren]` on the absorption totem at L518 — it is unrelated to this work but
sits in the same paragraph and is now the only open flag in the section.

Record findings in `docs/M4_findings.md` as you go, per `CLAUDE.md`'s working discipline —
especially anything learned about the melee RNG ordering, which is institutional memory.

---

## 12. Playtest flags

Tag these `[TODO — playtest]` in the design doc; they are whiteboard numbers:

- **5% per charm.** Twelve charms is a 60% proc, which is only balanced if melee is hard to
  land against a kiting mage. That is a play question, not a math question.
- **10% per rod**, and whether the 100% cap at 10+ rods is the archetype it should be.
- **Whether artifact depletion ends matches too fast.** This is the largest untested
  assumption in the whole rework: the entire artifact economy now trends toward zero, and
  nothing in the current match-length data accounts for that.

---

## 13. Addendum (2026-07-31) — long-press declaration + same-turn resolution

Ratified by Soren the same day this plan's Phase-0 scaffolding shipped, superseding two
pieces of §1/§2/§4 above. Everything else in this document — the trust boundary (§5), the
determinism rules (§6), and both ratified rulings not touched here — stands unchanged.

**What changed and why.** The original design forced a blocking full-screen prompt at the
very top of the turn, before the player had looked at their hand or the board, and it
deferred Bookmark's redraw and Rod's movement roll to resolve on a *later* turn than the one
they were declared on. Soren's ask: let players see their hand and the tactical situation
before deciding whether an activation is worth it, and make every activation's effect land
the turn it's declared, not the next one.

**13.1 — UI: no forced modal.** `beginArtifactPhase()`'s kind-declaration commit-reveal is no
longer triggered eagerly at the top of the turn. The main phase is free to browse; a
long-press on a loadout corner tile declares that activation and fires the exchange right
then (`_onArtifactCornerLongPress`). A player who commits a spell without ever long-pressing
anything gets the implicit "declared nothing" path the engine always supported — `_commitAction`
calls the same (memoized) exchange as a safety net. The ordering invariant that makes the
mind game work — Phase 0 fully resolves before either side's action commit — is unchanged;
only the UI trigger point moved. `[TODO — playtest]` whether the opponent's declaration still
reaches a slow-deciding player "in time" often enough to matter, now that it isn't forced to
the very top of the turn for both sides simultaneously.

**13.2 — Rod's movement passive and Bookmark's redraw both resolve the turn they're rolled/
declared, not the next one.** This requires entropy that exists *before* this turn's own
movement commit, which the turn's main joint entropy structurally cannot provide (§3.2's
"movement is committed in Phase 2, entropy arrives in Phase 3" is still true and still the
reason spell-resolution RNG stays post-commit). The fix is a **second, dedicated commit-reveal
exchange**, fired unconditionally at the top of every turn — `TurnLoop.beginArtifactEntropy()`,
reusing the mid-resolution `refreshEntropy` seam (`BATTLE_PROTOCOL.md` §3b) that was already
wired for exactly this kind of need ("the integration point for future interactive spells").
It is cheap (one extra LAN round trip, same shape as the turn-start nonce exchange) and kept
strictly separate from the main entropy stream — it is never used for anything look-ahead
sensitive (spell retargeting, burn targeting, summon collision), only for a player's own rod
roll and their own bookmark redraw, so knowing it early leaks nothing that the B-5 protection
cares about.

- **Rod:** the passive roll moves from Phase 6-of-the-previous-turn to Phase 0-of-this-turn.
  The `rodMobility` status effect is added with `remainingTurns: 1` same as before, but the
  timing is now genuinely one-shot: it's read by this same turn's Phase 2 movement sizing,
  then ticked away by this same turn's Phase 6 — it does not carry into next turn, and doesn't
  need to (a fresh roll happens every turn regardless). This also deletes the old "must be
  added AFTER tickStatusEffects or it's swept in the same breath" bookkeeping entirely; there
  was nothing to work around once the add and the tick landed in the same turn in the
  intended order.
- **Bookmark:** the redraw call moves out of `_endOfTurn` and into `_applyArtifactActivation`'s
  bookmark case, using `beginArtifactEntropy()`'s dedicated entropy (still tag `0x09`) instead
  of the main turn entropy. The bookmark is still consumed at declaration time; the redraw now
  happens in the same breath rather than at Phase 6. §2.7's price is down to just the permanent
  hand slot — the "full turn of tempo" cost is gone, by design, per this ruling.

**13.3 — Banners.** The Phase-0 read-out is corner-tile-only now: "mine" is the tile's outlined
state, "my charms are down" is the counter-charm tile's dimmed state (both pre-existing), and
the opponent's declaration is a one-shot `SnackBar` toast fired the moment it's revealed,
replacing the persistent full-width banner that used to linger for the rest of the turn.

**13.4 — Not changed.** The Phase-0 wire format (`artifactCommit`/`artifactReveal`, §4.3), the
trust boundary (§5), `_activatedThisTurn`/counter-charm gating (§2.2), the melee-proc ordering
fix (§6.1), and the Rod's cast-time radius-bonus *activation* (unrelated to the movement
*passive* touched here — see `_consumeRodOfSpreading`) are all untouched.
