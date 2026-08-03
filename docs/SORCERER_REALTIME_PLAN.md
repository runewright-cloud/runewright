# Runewright — Full Sorcerer Mode: Real-Time Architecture & Build Plan

*Status: **proposal, not yet ratified.** Written 2026-07-17 at Soren's request: (a) determine
the maximum feasible player count for full sorcerer mode on the `MESH_ARCHITECTURE.md`
design, (b) architect the implementation. Soren's own proposed solutions (movement
abstraction, turn-economy dissolution, somatic-as-enhancement, public-on-action, optimistic
entropy toggle) are addressed inline — most are endorsed, one is argued against (§4.3).
Items marked `[PROPOSED]` need Soren's sign-off; items marked `[SETTLED — Soren 2026-07-17]`
restate decisions from his commissioning message.*

*House rules apply: contract-first. Before any code that speaks a new frame, the frame goes
into a `BATTLE_PROTOCOL.md` v3 addendum (SORC.0, §9). When this doc and the eventual
contract disagree, the ratified contract wins.*

---

## 1. Player count: 6 is feasible — networking is not the binding constraint

### 1.1 The load model

Full sorcerer mode = free real-time movement/casting, 15 s resource tick, vocal + somatic
+ pedometer/compass input. The proposed engine (§3) is micro-tick lockstep: every player
emits exactly one small signed input frame per micro-tick (τ = 250 ms proposed), plus
occasional cast frames carrying proofs.

Worst-case arithmetic on the mesh, 6 players:

| Quantity | Value |
|---|---|
| Input frames | 4/s × 6 players = 24 frames/s |
| Frame size (signed envelope §6 of mesh doc + payload) | ~150–200 B |
| Gossip amplification (flood, 15 links, dedup) | ≤ ~25 transmissions/frame |
| Aggregate room-wide steady state | ~100–150 KB/s |
| Cast-completion frame (with UltraHonk proof) | 10–20 KiB, a few per minute |
| Proof verifications per cast, per device | 1 (tens of ms; `initSrsCached` invariant holds) |
| State-hash + chained-ack round | every 15 s macro tick, ~200 B/player |

LAN WiFi (even one phone acting as 5 GHz hotspot for field play — BLE stays 2P-only per
`BATTLE_PROTOCOL.md` §9, so sorcerer mode is WiFi/hotspot-only) delivers megabytes per
second; this is two-plus orders of magnitude of headroom. The mesh doc's "do not optimize
gossip before measuring" stands. Bandwidth and CPU do **not** cap the player count.

### 1.2 What actually constrains N

1. **Barrier stall probability.** Micro-tick lockstep waits for all N frames per tick;
   every added player multiplies the chance the room stalls on one phone's WiFi hiccup or
   GC pause. Mitigated by input delay (§3.2) — with a 500–750 ms jitter budget, venue
   WiFi should stall rarely — but this is the number to *measure*, and it degrades with N.
2. **Vocal cross-talk.** Six people chanting the same closed 5-word Latin vocabulary
   within earshot of each other's mics. Per-user enrollment + contrastive scoring
   (practice mode, 2026-07-16) is exactly the right mitigation — the enrolled voice is
   the reference, and cross-voice contrastive ranking measured much weaker (2/5) than
   same-voice (5/5) — but it has never been tested against *simultaneous competing
   speech of the same vocabulary*. This is the genuine go/no-go for 6, and it is a
   sensing problem, not a networking one.
3. **Physical space & safety.** Six adults moving in a radius-4-ish arena
   (~1 step ≈ 1 tile per Casting Stillness). Game design, not protocol.

### 1.3 Verdict `[PROPOSED]`

**Architect for 6; gate by hardware, staged 2 → 4 → 6.** Nothing in the protocol design
below depends on N, so there is no cheaper "design for 2" to buy — the 2-player version
*is* the N-player version with N=2 (the mesh doc's MESH.4 equivalence argument). The
build order (§9) ships a 2-player real-device sorcerer duel first regardless, because
N > 2 requires the mesh (or at least the star) which isn't built yet. If cross-talk or
stall rates fail at 6 on hardware, cap `MatchConfig.maxPlayers` for sorcerer-toggled
matches at whatever passed — a config clamp, not a redesign. Two people frantically
declaiming Latin is the floor and it is guaranteed reachable; six is the target and
nothing in the math says no.

---

## 2. What survives from the turn-based trust model

Soren's instinct — *"most commit-reveal schemes will not be necessary; in real time an
action becomes public knowledge as soon as it's taken"* — is correct, with two carve-outs.

| Mechanism | Turn-based role | Real-time fate |
|---|---|---|
| Action commit/reveal (B-5) | seal decision before entropy | **Dropped** as a distinct phase — replaced by the pipelined entropy rule (§4), which preserves the same guarantee at tick granularity for free |
| Move commit/reveal | simultaneity fairness | **Dropped** — movement is continuous public claims |
| Melee commit/reveal | simultaneity after movement | **Dropped** — melee becomes a declared, wound-up action (§7.4) |
| Entropy commit/reveal | unriggable randomness | **Kept**, pipelined & piggybacked (§4) — near-zero cost |
| Mystery spell / counter-charm commitments | hidden information | **Kept unchanged** — hidden-info commitments are orthogonal to turn structure |
| Spell identity during incantation | n/a (turn-based reveals atomically) | **New commitment needed** (§6.1) — without it, clients auto-decode the telegraph |
| Lockstep state hash | per turn | **Kept**, on the 15 s macro tick (design doc v3.0 already flags exactly this) |
| ZK proof + `_certifiedManaCost` + book membership | per cast | **Kept unchanged** — cast-time verification is identical |

And one new category with no turn-based ancestor: **self-attested sensor claims** (§8).

---

## 3. The real-time engine: micro-tick lockstep

### 3.1 Structure

- **Micro-tick τ = 250 ms** `[TODO — playtest]`. All simulation time is an integer tick
  count; no wall-clock enters the simulation (no clock sync needed — the barrier is the
  clock). Every living player broadcasts exactly one signed input frame per micro-tick;
  a frame with no events is the heartbeat. Slot = `(authorIndex, tick)` — the mesh
  envelope's equivocation machinery applies verbatim (two frames in one slot = evidence).
- **Simulation of tick t runs when frames for t are held from all living players.**
  Deterministic, integer-only, iteration sorted by playerId — `BattleState.toCanonicalBytes()`
  unchanged in kind. Within a tick, events are ordered `(eventKind, authorIndex)` —
  canonical, never arrival order.
- **Macro tick = 60 micro-ticks (15 s):** mana regen, status-effect durations, minion
  action budgets (§7), the signed state-hash round, and the chained set-hash ack. This
  is the design doc's "lockstep hash on the 15 s tick" carried-forward item, discharged.
- **Stalls:** missing frames past a soft timeout → "waiting for Dana…" UI; past hard
  timeout → the existing pause/rejoin machinery (mesh §12), unchanged. The simulation
  freezes for everyone — in a physical-movement game the UI must say so *loudly*
  (players are mid-stride; the always-signal-state rule from the dive-dodge spec
  applies to pauses too).

### 3.2 Input delay

A player's local inputs at tick t enter the shared simulation at tick t+k, **k = 2–3**
`[TODO — playtest]`. This is the classic RTS-lockstep jitter absorber: it gives every
frame ~500–750 ms to cross the room before anyone waits on it. Consequences:

- Your own step registers on the board ~0.5 s after your foot lands. Steps take ~0.5 s
  anyway; acceptable.
- The dive-dodge reaction budget is `windup W − k·τ`; W must be tuned ≥ ~2 s (§6.2) so
  the input delay doesn't eat the dodge window. W was already flagged as the key
  playtest knob in the design doc; this just adds its floor.
- A rushing client (holds its tick-t frame until others' arrive, then decides) gains at
  most one tick window (~250 ms) of information advantage — and the physical layer
  makes that nearly worthless: you cannot retroactively begin vocalizing or diving
  250 ms ago. Documented as accepted residual risk (§8.3).

### 3.3 Where it lives in the code

`RealTimeLoop` as a sibling of `TurnLoop`, sharing the resolution internals —
`effect_resolver.dart`, `effect_applicator.dart`, minion AI (`_creatureTurn`,
`_aggressiveMove`, …), `_certifiedManaCost`, `_reapDead` — extracted into a shared
engine layer rather than forked. The extraction is SORC.1's real work, and the
regression gate is: **the full existing turn-based suite still passes after it.**
`BattleTurnSession`'s request/response exchanges don't fit a broadcast tick stream; a
new `RealTimeSession` interface (implemented over `BattleSession` framing for N=2 now,
`MeshFabric` later) carries `sendTickFrame`/`onTickFrame`. Mesh-migration discipline
(mesh §16) applies from day one: playerId-keyed maps, signed frames, N-clean state.

---

## 4. Entropy: pipelined commit-reveal, piggybacked — and why not optimistic mode

### 4.1 The scheme

Every input frame at tick t carries two extra fixed-size fields:

```
commit_t  = SHA-256(nonce_t)        (32 B)
reveal    = nonce_{t-k}             (32 B, matching the commit sent k ticks ago)
```

Joint entropy for events *declared* at tick t is the XOR of all players'
`nonce` values revealed at tick t+1 — i.e. an entropy-consuming event resolves one tick
(~250 ms) after it is declared, seeded by nonces that were **committed before the event
was declared and revealed only after the declaration was broadcast.**

This is exactly B-5 ("decisions seal before entropy is known"), preserved at tick
granularity: a cheater cannot see the tick-t+1 reveals before sending its tick-t frame,
because honest players won't emit t+1 until the tick-t barrier — which includes the
cheater's frame — is complete. Withholding a reveal is a visible stall → pause machinery.
A revealed nonce that doesn't match its commit is `bad_reveal` evidence, verbatim from
the mesh catalogue. The §8.3 regrind rule (fresh commits after an ejection with
unrevealed nonces) carries over unchanged.

Cost: **64 bytes per frame and zero extra round trips.** The `_HashRng` hash-counter
stream and all consumers are unchanged; the seed context string gains the tick number.

### 4.2 Per-event derivation

Within a tick, each entropy-consuming event draws from
`HashRng(joint_entropy, context = eventKind ‖ authorIndex ‖ tick)` — the same
domain-separation habit as everywhere else. `refreshEntropy` call sites generalize to
"the next tick's XOR" at table-hard-coded resolution points, as today.

### 4.3 Against the optimistic-mode toggle `[PROPOSED — decision for Soren]`[Confirmed - Optimistic Mode Scrapped]

Soren suggested an optimistic mode (assume good actors, skip entropy ceremony) as a
player-selectable relief valve for bad networks. Recommendation: **don't build it.**

- The pipelined scheme costs 64 B/frame and no latency — there is nothing meaningful to
  relieve. The expensive thing in bad network conditions is the *barrier*, and optimistic
  entropy doesn't remove the barrier (input frames are still lockstep).
- A consensus-visible toggle forks the protocol: two entropy paths to test, two attack
  surfaces, and a `MatchConfig` axis whose "fast" setting quietly deletes the
  rigged-randomness defense. The B-1/B-8 lesson — one path, ever — applies.
- If barriers themselves prove too slow on real hardware, the right relief valves are
  larger τ and k (pure config numbers), not weaker cryptography.

---

## 5. Sensors never touch the wire

The single most important scaling decision: **all sensor processing is local; the wire
carries only small discrete claims.** Audio and IMU streams stay on-device. This is what
makes N=6 cost the same as N=2 per-link, and it's already the shape of the code
(VocalScorer runs locally; `VocalScore` crosses the wire as 2 quantised bytes).

Wire events (each inside the signed input frame of the tick it occurred):

| Event | Payload | Source pipeline |
|---|---|---|
| `stepTaken` | direction (3 bits, hex-snapped) | pedometer + compass |
| `castDeclared` | salted spell commitment (32 B), §6.1 | UI selection |
| `castCompleted` | commitment + salt, target tile, gesture enum (1 B), VocalScore (2 B), crescendo intensity (1 B), proof bytes | mic scorer + gesture classifier |
| `castBroken` | (empty — tick position implies cause) | locomotion detector |
| `meleeDeclared` | target tile | UI |

### 5.1 Vocal — reuse the practice-mode stack

The enrollment + contrastive scorer (`PerUserEnrolledTemplateSource`, the 4-condition
crossing rule) is the battle scorer; battle mode adds: (a) scoring a *sequence* of
element words per the spell's formulas, streamed, (b) the final-formula crescendo —
score = average of accelerometer intensity, volume, accuracy per the design doc, (c)
running while the rest of the game runs (CPU budget to measure at SORC.6).
Cross-talk mitigations, in escalation order: near-mouth capture until the final formula
(the design already choreographs this — phone pulls away only at the crescendo);
enrollment contrastive margin; **push-to-incant** (hold thumb on screen while incanting)
as a `[PROPOSED]` fallback — UX-negative but it segments attempts crisply, gates the
mic, and hard-limits cross-talk pickup. Decide only if open-mic fails on hardware.

### 5.2 Somatic — enhancement selection only `[SETTLED — Soren 2026-07-17]`

Gestures select the casting enhancement (potency / velocity / efficiency / mystery /
neutral) and nothing else. This is the right cut: it removes precision aiming from the
fragile sensor, makes the classifier a bounded closed-set decision on bounded
stationary oscillations, and the wire cost is the 1-byte enum already reserved
(`gesture.dart`'s `Gesture` seam, VocalScore's somatic byte). `gesture.dart` maps
gestures to *elemental* zones, which already lines up with the enhancement list
(fire=Potency, air=Velocity, water=Efficiency, earth=Mystery) — no reconciliation
against a separate enhancement-named enum is needed.

**All five gestures ship together, not phased** `[RESOLVED — Soren, §10.2]`: the four
elemental/enhancement gestures (fire/air/water/earth) plus neutral and melee. An earlier
pass at this section read velocity/mystery choreography as still open and phased
fire+water+melee ahead of air+earth (see the now-superseded
docs/SOMATIC_GESTURE_PLAN.md v1/v2 table) — that was stale against Soren's answer
already recorded in §10.2 below. Choreography for all five is Soren's own performed
baseline, captured via the enrollment tool (docs/SOMATIC_GESTURE_PLAN.md) rather than
specified in writing here — the capture *is* the choreography spec. Calibration mirrors
vocal enrollment: record each gesture repeatedly, per-user templates (never averaged —
a query matches the nearest individual repetition via DTW, since averaging misaligned
repetitions produces a template that matches nothing), fixture-harness gate before any
constant tuning (the practice-mode discipline).

### 5.3 Movement — steps + compass, with protocol-checkable claims

`[SETTLED — Soren 2026-07-17]` (confirming the design doc's lean): step-count +
compass-bearing; **S steps ≈ 1 tile** (S default 2, `[TODO — playtest]`); speed
buffs/free movement reduce the required steps per tile rather than moving the avatar
(the game-coordinate abstraction); forced movement (conveyors, knockback) moves game
coordinates only. Endorsed — with these notes:

- **Compass:** snap bearing to the 6 hex directions; magnetometers need calibration UX
  (figure-8 prompt at match start) and drift indoors. Fallback: gyro-integrated relative
  heading, re-anchored at each stillness window. Facing is *claimed per step*, so a bad
  compass hurts its owner only.
- **Anchor drift is permanent and by-design:** after one knockback, physical position and
  game position never re-converge. Consequences (players physically colliding while
  game-distant, walking toward walls) are a safety/UX matter — proposed relief: a free
  "re-anchor" that rotates/translates your *physical* frame without moving game
  coordinates, usable while standing still `[DECISION — Good suggestion, approved by Soren]`.
- **Claims are clamped by protocol** (§8.2): max step cadence, adjacency, arena bounds.

### 5.4 Locomotion vs. gesture disambiguation

Casting Stillness already resolves this by design: gestures are bounded oscillations
with ~zero net displacement; steps/dives translate and land footfalls. The abort
detector keys on displacement/footfall only. Ship the soft-lock baseline first (movement
input suspended during a declared cast), add abort-on-locomotion as the additive upgrade
— both per the design doc, both purely local.

---

## 6. The casting flow

### 6.1 The one new commitment: salted cast declaration

If `castDeclared` carried the spell commitment in the clear, any client — modified *or
honest* — could look it up (starter-rune commitments are public; opponents' non-mystery
casts become known over a match) and display "incoming: Fireball," deleting the
listen-and-decode skill that is the entire point of the vocal telegraph. So:

```
castDeclared:  H(commitment ‖ tier ‖ salt)      — 32 B, salt fresh per cast
castCompleted: commitment, tier, salt, target, … — opens it; peers verify the hash
```

The only channel for *what is coming* during the incantation is the player's actual
voice and body — exactly the design intent. Mismatched opening = `bad_reveal` evidence.
Small commitment spaces brute-force without salt; the salt is mandatory (standing rule).

### 6.2 State machine

```
idle
 └─ castDeclared (tick d)          — stillness window opens; movement input suspended
     └─ incanting                  — local streaming vocal scoring; nothing on the wire
         ├─ castBroken             — locomotion detected (dive!) or player cancel;
         │                           haptic + visual flip, back to idle. Mana: no cost
         │                           `[TODO — playtest]` (or small chip to stop bluffing)
         └─ final formula + gesture, simultaneously (the crescendo)
             └─ castCompleted (tick c) — opens declaration; carries target, gesture,
                 │                       VocalScore, crescendo intensity, proof bytes.
                 │                       Peers: verify proof, book membership,
                 │                       _certifiedManaCost, declaration hash.
                 └─ wind-up: W ticks (W·τ ≈ 2 s `[TODO — playtest]`, the dodge window)
                     └─ resolution at tick c+W, entropy from the §4 pipeline
```

Cast-time verification is unchanged from today: proof → `verify_ultra_honk`, cost →
`_certifiedManaCost` (still the only path), commitment → caster's `bookCommit`, per-caster
`_usedCommitments`. Vocal quality feeds `CastingEnhancements.fromSorcererQuality` from
the wire-quantised u8s, as already built.

Bluff economics: declaring and aborting is free theatre (fake-outs are good gameplay),
but the *stillness* it demands is a real cost, and a declared cast that never completes
telegraphs nothing — the vocalization is the telegraph, and that can't be faked silently.

---

## 7. Turn economy in real time `[SETTLED — Soren 2026-07-17, mechanics as proposed]`

- **"One turn" := one macro tick (15 s)** for every rules-text purpose: buff/status
  durations, mana regeneration, minion budgets, chain-state decay.
- **Minions:** a minion with speed M moves 1 tile every ⌊60/M⌋ micro-ticks (spread
  evenly, as Soren specified), and may attack once per macro tick, firing at the first
  micro-tick in the window where a valid target is in range. Both rules are pure
  functions of shared state — no input frames, no fairness machinery, deterministic on
  every device. The existing `_creatureTurn` AI is re-hosted on this schedule.
- **Player action economy:** dissolved; replaced by physical constraints (vocalization
  time, stillness, step cadence) plus per-spell wind-ups. If playtests show spam,
  add cooldowns as data, not protocol.
- **Melee:** `meleeDeclared` with a short wind-up (~1 s) requiring adjacency at both
  declaration and resolution; dodge by stepping away. Replaces the melee commit-reveal.
  `[TODO — playtest]` numbers.
- **Delayed spells:** the delayed-spell commitment machinery carries over; the reveal
  fires at its trigger tick through the normal `castCompleted`-style opening.

---

## 8. Trust model deltas — what's verified, what's clamped, what's accepted

### 8.1 Still cryptographically enforced (unchanged)

Spell validity (ZK), mana cost (certified), book membership, entropy (pipelined
commit-reveal), state agreement (macro-tick hash), identity/frames (Ed25519 envelope),
equivocation (slots), hidden info (mystery/counter-charm/cast-declaration commitments).

### 8.2 New deterministic validity checks → evidence rows

Signed claims can contradict *each other* or the rules; both are third-party-verifiable
from the frame log alone, extending the mesh §11.1 catalogue:

| Code | Evidence | Verify by |
|---|---|---|
| `impossible_movement` | step claims exceeding cadence cap (default 4 steps/s `[TODO]`), non-adjacent tile entry, out-of-bounds | signed frames + recompute |
| `cast_while_moving` | `stepTaken` claimed between `castDeclared` and `castCompleted` without `castBroken` | signed frames, pure ordering check |
| `malformed_claim` | out-of-range VocalScore/gesture/intensity bytes (clamps are rejects, not fixes) | signed frame + range check |
| `bad_reveal` (extended) | `castCompleted` opening ≠ `castDeclared` hash | 2 sig checks + 1 hash |

Each row lands with its cheating-client attack test (standing rule: a detection you
can't write a cheater for is a detection you don't understand).

### 8.3 Accepted self-attested claims — the honest paragraph

Vocal score, gesture classification, and step *authenticity* are measurements of the
player's own body by the player's own device. **Peers cannot recompute them, and no
protocol can make them; streaming raw audio/IMU for auditing would cost more than the
whole game's networking and still be spoofable at the sensor.** This is a deliberate,
documented exception to mesh checklist item 9 ("peers send claims; clients recompute"),
bounded three ways:

1. **Range and consistency clamps** (§8.2) cap the mechanical advantage: a fabricated
   vocal score buys at most the legitimate best-case discount; fabricated steps are
   capped at sprint cadence.
2. **Co-presence is the audit.** This is an in-person game by construction: everyone can
   hear whether you actually declaimed the incantation your score claims, and see
   whether you actually ran. A shouting-distance sport polices sensor honesty the way
   physical sports do.
3. The rushing-client residual (§3.2, ~one tick of lookahead) is likewise accepted:
   bounded to 250 ms and physically unusable for vocal/somatic/locomotive reactions.

These acceptances hold for casual/venue play. If signed-record stakes ever demand more
(tournaments), that's a referee-attestation layer on top, not a protocol change.

---

## 9. Build plan

Contract → Dart oracle → wire → devices, per house discipline. Findings to
`docs/SORC_findings.md` as they happen. Each stage lists its gate.

- **SORC.0 — Contract.** `BATTLE_PROTOCOL.md` v3 real-time addendum: tick semantics,
  input-frame format (slot rules, piggybacked entropy fields), the five claim events,
  cast state machine, evidence rows, timeout/pause behaviour, `MatchConfig` additions
  (τ, k, W, S, cadence cap, maxPlayers-for-sorcerer). Reconcile `Gesture` enum vs
  enhancement list. *Gate: Soren ratifies; open `[DECISION]`s in §10 resolved or
  explicitly deferred.*
- **SORC.1 — Engine extraction + RealTimeLoop core.** Extract shared resolution
  internals from `TurnLoop`; build the micro/macro-tick simulator over an in-memory
  `RealTimeSession`, N-player-shaped (`Map<playerId,…>`) from the start; minion
  scheduling per §7. *Gate: full existing turn-based suite green; new determinism test —
  two in-process instances, identical frame logs, identical macro-tick hashes.*
- **SORC.2 — Entropy pipeline + barriers.** Piggybacked commit-reveal, input delay,
  stall→pause wiring. *Attack tests: withheld reveal, bad reveal, rushing client
  (delayed frames), §8.3-regrind analogue.*
- **SORC.3 — Movement claims.** Pedometer/compass service → `stepTaken`; clamps +
  `impossible_movement`/`cast_while_moving` evidence; conveyor/knockback game-coordinate
  offsets; synthetic IMU fixture corpus (the practice-mode fixture discipline — commit
  recorded walks/dives/gestures as test vectors). *Attack tests: teleporting client,
  cadence flood.*
- **SORC.4 — Casting flow.** Salted declaration, streaming battle vocal scoring on the
  enrollment stack, crescendo scoring, wind-up + resolution, abort-on-locomotion
  (soft-lock first). *Gate: e2e fixture harness (recorded incantations incl. competing
  background chant) passes; no constant ships un-harnessed.*
- **SORC.5 — Gesture classifier.** Neutral + potency + efficiency; per-user gesture
  enrollment; fixture harness. *Gate: same as vocal — harness before tuning.*
- **SORC.6 — 2-player real-device gate.** Two physical phones, outdoors on a phone
  hotspot, all four sorcerer toggles on, full duel. Measure: stall rate, scorer CPU +
  battery, mic cross-talk at 2, input-delay feel, dodge-window feel. *This is the
  M4.6-style hardware gate; nothing before it counts as validated.*
- **SORC.7 — Scale gate (blocked on mesh MESH.1–4 or the star sequencer).** Same
  protocol, N=4 then N=6 on hardware, including one adversarial device running the
  cheating client. Cross-talk measurement at 6 decides the final `maxPlayers` clamp.

Sequencing note: SORC.0–SORC.5 are independent of the mesh build and mostly independent
of each other after SORC.1; SORC.3/4/5 can interleave. The August star playtest is
unaffected — this track merges behind the sorcerer toggles.

---

## 10. Open decisions

`[DECISION — needs Soren]`
1. Drop the optimistic-entropy toggle (§4.3 recommends: yes, drop).
Yes Dropped
2. Velocity + mystery gesture choreography (§5.2).
Forthcoming, my plan is to record myself doing the needed gestures and use those as baselines, have all four enhancement gestures and one neutral cast gesture in mind, along with a melee attack gesture which I'm planning to also link to gestures in real time real movement modes.
3. Re-anchor mechanic for physical/game frame drift (§5.3).
Approved, can replace the not needed action button in the UI not needed in this mode.
4. Push-to-incant fallback — only if open-mic fails at SORC.6 (§5.1).
Approved, may potentially implement for all incanting as seems a simple way to improve performance in any setting.
5. Abort cost for a broken cast — free vs. small mana chip (§6.2).
No mana cost for now, only penalty is lost time, might revise after playtesting.
6. Accessibility alternates (design doc flag, unresolved): accuracy-only vocal path,
   seated somatic path — schedule alongside SORC.4/5, not after.
   I believe current somatic gestures will all be performable while sitting. Have accessibility expert friend will consult on specific implementations after play testing.

`[TODO — playtest]` τ, k, W, S, cadence cap, melee wind-up, macro-tick length itself
(15 s inherited from the design doc).
