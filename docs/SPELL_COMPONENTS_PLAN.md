# Spell Components — Vocal, Somatic, and Casting Order

*Ratified 2026-08-06. Supersedes the single "Sorcerer Mode" toggle. Companion to
`VOCAL_RECALL_PLAN.md` (the vocal half, already built) and `SOMATIC_GESTURE_PLAN.md`
(the somatic half, built but until now unwired). This document is the contract for how
the two components are enabled, performed, and paced.*

---

## 1. What changed and why

"Sorcerer Mode" was one boolean covering two unrelated capabilities. Splitting it is not
cosmetic: the two components have **different trust properties**, different hardware
requirements, and different failure modes, so a player has real reason to want one
without the other.

| | Vocal | Somatic |
|---|---|---|
| What it measures | Which slot was spoken at each position (`IncantationRecall`) | Which of five gestures was performed (`GestureClassifier`) |
| Peer-verifiable? | **Yes** — recomputed from the certified `dominance_trajectory` | **No** — a self-attested sensor claim |
| What it can do | Move mana cost, up and down, in exact integers | Select an enhancement the caster is *already certified* to hold |
| What it can never do | Fizzle a cast; gate an enhancement | Grant unearned power (it only ever resolves to neutral) |
| Hardware | Microphone | Accelerometer + gyroscope |

That asymmetry is load-bearing and is why the somatic side gets no mana lever at all
(§4.2). Anything self-reported that could *reduce* the caster's cost would be the
B-1/B-8 shape the vocal redesign specifically removed.

Three negotiated `MatchConfig` flags replace the one:

```dart
final bool vocalComponents;      // was sorcererMode
final bool somaticComponents;    // new
final bool simultaneousCasting;  // new, default false
```

All three are compared field-by-field in `MatchConfig.matches()`, so both sides must
agree or the session aborts — same as every other negotiated field. `fromJson` reads a
legacy `sorcererMode` key into `vocalComponents` so an older stored config still loads.

Derived, not stored:

```dart
bool get componentsEnabled  => vocalComponents || somaticComponents;
bool get sequentialCasting  => componentsEnabled && !simultaneousCasting;
```

With no components enabled there is nothing to perform, so ordering is moot — that is
why `sequentialCasting` is gated on `componentsEnabled` rather than being the plain
negation of `simultaneousCasting`.

---

## 2. The cast cycle, end to end

Press-and-hold CAST is the single capture window for **both** components — one control,
matching enrollment exactly (`SOMATIC_GESTURE_PLAN.md` §7: if enrollment is
press-delimited and live capture is not, every DTW distance is skewed).

```
  ┌ hold starts ───────────────────────────────── hold ends ┐
  │  mic opens (vocal)                                      │
  │  IMU streams (somatic)                                  │
  │                                                         │
  │  player chants OPENER + the trajectory                  │
  │  player gesticulates freely, ending on the gesture      │
  │  for the enhancement they want                          │
  └─────────────────────────────────────────────────────────┘
        ↓                               ↓
   IncantationRecall              GestureMatch
        ↓                               ↓
   mana multiplier              enhancement zone
   (exact integers,             (client-side downgrade
    peer-recomputed)             against supremeTags)
                    ↓
              _commitAction  ←── lock-in point
                    ↓
              componentsDone  →  peer's UI unlocks (§5)
                    ↓
              beginTurn → action commit-reveal (unchanged)
```

Nothing about the commit-reveal machinery changes. The action still crosses the wire as
a salted split commitment first and a reveal second; no client ever learns what another
locked in until everyone has locked in.

---

## 3. Vocal components

Unchanged from `VOCAL_RECALL_PLAN.md`. Enabling `vocalComponents` is exactly what
`sorcererMode` used to do: it opens the mic on hold, scores the recital with
`IncantationRecallScorer`, and appends the recall suffix to the action payload
(`TurnLoop.isVocalComponents` now gates that suffix, renamed from `isSorcererMode`).

The **bluff** the design wants falls out of this for free and needed no new code: a
caster may deliberately speak the wrong words to mislead a listening opponent, and pays
for it in mana at the rate `RecallTally.applyTo` already charges. The peer recomputes
the tally from the certified trajectory, so the bluff is priced honestly — you cannot
mislead the room without also paying.

---

## 4. Somatic components

### 4.1 The free-style motion gate

The hold is a performance, not a trigger. `castMotionSatisfied()` (in
`gesture_classifier.dart`) requires the caster to have been *moving throughout*, not
merely to have twitched once:

- the hold must produce at least `kMinCastMotionSamples` IMU samples, and
- splitting the hold into `kCastMotionQuarters` equal windows, at least
  `kCastMotionQuartersRequired` of them must exceed `GestureClassifier.energyFloor`.

**Deliberately reuses the one calibrated number** (`energyFloor = 8.0`, the measured
Pixel 6 idle ceiling of 7.76 with margin) rather than inventing a second threshold —
§6.5 of the somatic plan forbids invented constants. What makes this an independent
check is the *coverage* rule, not a new floor: a single flourish inside an otherwise
still hold clears the classifier's stillness gate but fails the coverage rule.

**Consequence of failing it: the cast proceeds with no enhancement.** `[RATIFIED —
Soren, 2026-08-06]`. Not a mana penalty, and not a refused cast. This is the only
choice consistent with §1's trust table: any penalty would be a self-reported sensor
claim, and any hard block would let a sensor glitch cost a turn.

### 4.2 Gesture selects the enhancement — and is the only thing that does

`[RATIFIED — Soren, 2026-08-06]` With `somaticComponents` on, the tap-based
`_EnhancementPicker` is **hidden**. The enhancement is whatever the gesture resolves to
at release, subject to the two-layer eligibility rule from `SOMATIC_GESTURE_PLAN.md` §5:

1. **Client-side downgrade** — if the recognized gesture's zone is not in
   `spell.supremeTags`, resolve to neutral and send no enhancement claim.
2. **Peer-side forfeit** — unchanged; `turn_loop.dart`'s `unbacked_enhancement_claim`
   remains the backstop for modified clients.

Two consequences worth stating:

- **Earth/Mystery still needs a delay.** The 0–3 delay picker cannot be chosen during
  the hold, so a recognized `earth` gesture pops the delay prompt *after* release,
  before the action is committed. Cancelling the prompt cancels the cast (nothing has
  been committed yet, no turn is lost).
- **The cost preview becomes a range.** Water/Efficiency is −1/3 and is not known until
  release, so the CAST button prices the spell as `min…max` while somatic is on. The
  affordability gate uses the **maximum**, because an unaffordable cast makes the peer
  forfeit — the button must never offer one it might not be able to pay for.

`kSomaticCaptureEnabled` is retired as a gate: the lobby toggle is now the real one.

---

## 5. Casting order

### 5.1 Simultaneous casting (opt-in, default off)

All players perform their components at once. Turning it on raises a warning:

> When using this mode all players will be saying weird things and doing weird things
> simultaneously. Not recommended unless you are wizards of singular focus, have plenty
> of room to spread out, and are wearing headsets.

The practical problem is acoustic, not mechanical: two people chanting a metre apart
put each other's words into each other's microphones.

### 5.2 Sequential casting (the default)

One player at a time performs their components and locks in. Everyone else waits.

**Order** — clockwise around the map, by *starting* position. `spawnPositions()` already
lists the six battlefield vertices in visual clockwise order, so the seat order is the
players sorted by the clockwise index of the vertex they spawned on. Starting positions,
not current ones: the seating must not shuffle as wizards walk around.

**Who goes first** — chosen at battle start from the joint commit-reveal entropy
(`startBattle()`'s `startEntropy`), so neither device picks it. Then it **rotates by one
each turn**: whoever went second on turn 1 goes first on turn 2, and so on.

```dart
first(turn) = order[(startIndex + turn - 1) % order.length]
```

**What is gated** `[RATIFIED — Soren, 2026-08-06]`: only the **lock-in**. Selecting a
spell, picking a target, browsing the hand, and inspecting the battlefield stay live for
everyone at all times. The CAST hold — and DASH / MEDITATE / PASS, which consume their
slot too so nothing leaks from who acts when — unlock only in your slot.

That is precisely the information asymmetry the design wants: a later player hears the
earlier player's incantation *with their own ears* and may change their pick before
locking in. A player who cracks their opponent's vocabulary starts predicting spells.
Nothing about this is transmitted — the wire carries only "I am done", never what was
chosen.

**Pacing** `[RATIFIED — Soren, 2026-08-06]`: automatic, no timer. The next player's
controls unlock the instant the previous player's `componentsDone` lands. Stalling is
policed socially, consistent with the rest of the shouting-distance trust model.

### 5.3 The `componentsDone` signal (0x46)

A new `BattleMsgType`, payload `turnNumber` as a big-endian uint32.

**Why a dedicated frame rather than watching for `actionCommit`:** the action commit is
sent from inside `beginTurn`, which first awaits `beginArtifactPhase()` — a *simultaneous*
Phase-0 exchange that only completes once the peer has also declared. A second player
waiting on the first player's `actionCommit` would therefore wait on a frame the first
player cannot send until the second player has committed. That is a deadlock, and it is
the reason this signal exists as its own frame, sent at `_commitAction` entry, before
any of the turn's exchanges are touched.

It is information-free by construction. It says only "I have finished performing," which
every player in the room can already hear.

Receiving is **latched, not streamed**: `BattleSession` records which turns the peer has
signalled and hands back an already-completed future if the signal arrived before anyone
asked. A live broadcast stream would drop a signal that beat its listener to the wire.

Solo/practice sessions complete it immediately — the target dummy has no components to
perform, so nobody ever waits on it.

---

## 6. Trust boundary summary

Nothing in this pass adds a new trusted input.

| Claim | Who can check it | Backstop |
|---|---|---|
| Which words were spoken | Peer, from the certified trajectory | Priced in mana; no forfeit condition |
| Which gesture was performed | Nobody | Can only reduce to neutral |
| That the caster moved during the hold | Nobody | Never leaves the device — no wire field at all |
| Which enhancement is claimed | Peer, against `supreme_dominance_flags` | `unbacked_enhancement_claim` forfeit |
| That components were finished | Nobody | Carries no information; worst case is casting out of order in a room where everyone can see you |

---

## 7. Outstanding

- **Real-device pass for somatic cast capture.** The classifier cleared its
  confusion-matrix gate on the committed Pixel 6 corpus, but the *live cast seam* —
  IMU streaming during a real hold, with a real hand, mid-battle — has not been run on
  hardware. `SOMATIC_GESTURE_PLAN.md` §11 step 6's hardware gate is still open, and the
  free-style coverage rule (§4.1) has never been measured against real casting motion.
- **Two-device LAN pass for sequential ordering.** The order gate is a wire-timing
  behaviour; the verification hierarchy says a hardware run outranks the integration
  test that currently covers it.
- **Somatic + Mystery ergonomics.** The post-release delay prompt (§4.2) is the one
  place where the gesture-only flow adds a tap back. Worth a playtest look.
