# Runewright — Trustless Mesh Architecture (`MESH_ARCHITECTURE.md`)

*Status: **design, not yet built.** Written 2026-07-15, ahead of the August playtest
which ships the interim star topology (authoritative host). This document is the
blueprint for replacing the star with a 6-player trustless mesh after core gameplay
stabilizes. It was written with Soren's ratified decisions (§3) baked in; those are
settled — don't re-litigate without new evidence.*

*House rules apply: this document is contract-first in the `BATTLE_PROTOCOL.md` sense.
When implementation begins, each section that defines wire behaviour gets transcribed
into `BATTLE_PROTOCOL.md` (or a v2 successor) before the code that speaks it. When this
document and the eventual code disagree, the ratified contract wins, then the code gets
fixed.*

---

## 0. The problem, and where we start from

**Goal:** up to 6 co-present players, all on local wireless, all verifying everything
every other participant claims, with **no authoritative host**. Anyone's client can be
modified; the match outcome must still be either correct or provably attributable to a
specific cheater.

**What already exists (2-player lockstep, M4 era):**

- A pluggable `Transport` seam (`lib/protocol/transport.dart`) — one peer, raw bytes.
- `MatchSession` proof-exchange handshake, then `BattleSession` framed messaging
  (`[1B type][4B BE len][payload]`, types 0x10–0x4F).
- Commit-reveal for **every** player decision (action, movement, delayed spells) and
  **every** entropy draw — decisions seal before entropy is known (B-5).
- Per-turn lockstep state hash over `BattleState.toCanonicalBytes()` (canonical binary,
  integer-only, sorted iteration).
- ZK proof verification of peer spell casts + Merkle book-membership + certified mana
  cost (`_certifiedManaCost`, the B-1/B-8 single-source-of-truth).
- Deterministic resolution ordering (T ascending, then commitmentHex).

**The one-sentence thesis of this design:** the 2-player protocol is already trustless
between two parties; the mesh generalizes it to N by making every message a **signed,
gossiped broadcast**, so that any inconsistency between what different peers were told
becomes **self-incriminating cryptographic evidence**.

---

## 1. Threat model — what "trustless" means here

In scope (must be detected, with blame assigned where possible):

| Attack | Existing 2P defense | Mesh defense |
|---|---|---|
| Forged spell (invalid CA claim) | ZK proof verification | Same — every peer verifies every proof (§13) |
| Understated mana cost | `_certifiedManaCost` from proof publics | Same, keyed per caster (§13) |
| Decision changed after seeing entropy | commit-before-entropy (B-5) | Same, N-party (§8, §9) |
| Rigged randomness | 2-party commit-reveal XOR | N-party commit-reveal XOR (§8) |
| Withheld reveal (sulking) | forfeit `withheld_reveal` | timeout → pause → forfeit (§8, §12) |
| Divergent simulation (client "house rules") | lockstep state hash | N-party signed state hash (§10) |
| **Equivocation** — telling peer B one thing and peer C another | *impossible with 2 parties — this is THE new attack class* | signed frames + gossip flood + chained set-hashes (§6, §9) |
| Scry-channel abuse — lying to or stonewalling a scrying player | n/a (no 3-party info asymmetry with 2 players) | encrypted-broadcast openings + split commitments (§13b) |
| Collusion — a team shares hidden info out-of-band | out of scope (2P too) | out of scope; see §19 |
| Replay of old frames / cross-match splicing | matchId binding | matchId + turn + phase + author in every signature (§6) |
| Rage-quit disguised as disconnect | forfeit on timeout | pause window, then group decision (§12) |
| Entropy-dodging by "disconnecting" during reveal | n/a (2P: match just ends) | commitment survives rejoin; fresh commits on ejection (§8.3) |

Out of scope, deliberately:

- **Out-of-band collusion** (teammates whispering). No protocol can stop people in the
  same room from talking; the game design treats table talk as part of the game.
- **Denial of service** (jamming the WiFi). Physical-layer; the match pauses/aborts,
  nobody wins by it (abort produces no signed result).
- **Traffic analysis** of frame sizes/timing leaking hidden info. Mitigate with padding
  where cheap (§6.4), accept the rest — the 2P protocol has the same exposure.
- **Long-term identity attacks** (Sybil across matches). Identity is per-device
  self-custodied keys; reputation is a social/ELO-layer concern, not a match-protocol one.

---

## 2. Design thesis: accountability, not BFT

A classical Byzantine-fault-tolerant protocol (PBFT and kin) makes progress *despite*
faults, invisibly. That costs view changes, quorum certificates on every message, and
3f+1 participants to tolerate f faults — machinery that buys almost nothing for a game
where all six players are **standing in the same room**, are **known** (roster signed at
match start), and where the correct response to a caught cheater is social, not silent
masking.

Instead this design provides **accountable lockstep broadcast**:

1. **Every frame is Ed25519-signed by its author** over a domain-separated context
   (match, turn, phase). Nobody can forge, and nobody can deny, a message.
2. **Every frame is gossiped to everyone.** Relaying is safe because relays can delay
   or drop but never alter (signatures). One mechanism gives both partial-connectivity
   relay (§5.3) and equivocation capture: if a cheater signs two different frames for
   the same slot, gossip spreads both, and the pair *is* the evidence.
3. **The simulation is fully deterministic and runs on all six devices.** There is no
   state anyone must take on faith; the per-turn signed state hash proves agreement.
4. **Detection is followed by ejection, not masking** (§3, §11). The match continues
   for the honest players; the cheater leaves with a signed evidence record.

The protocol never needs to *vote on what is true* — truth is recomputable by everyone.
It only needs to *prove who lied*. That is a far easier problem, and it is the reason
this design is buildable by one engineer rather than a distributed-systems team.

---

## 3. Ratified decisions (Soren, 2026-07-15) — settled

1. **Cheat response: eject & continue.** A cryptographically caught cheater is
   forfeited with a signed evidence record; remaining players continue. Fall back to
   abort **only** when blame cannot be pinned (which, per §10.2, usually means a bug,
   not a cheat).
2. **Honest disconnect: pause + rejoin window.** Match pauses; the dropped player has a
   rejoin window (default 3 min, `MatchConfig`-tunable) to reconnect and resync
   verifiably. After timeout the remaining group chooses forfeit-and-continue or abort.
3. **Partial connectivity: signed relay fallback.** If a direct link dies but the
   connectivity graph stays connected, frames route via peers. A match dies only when a
   player is genuinely unreachable by everyone.

---

## 4. Lifecycle overview

```
[lobby]        mDNS discovery → lobby leader collects roster → all sign rosterCommit
[handshake]    pairwise link establishment (full mesh attempt) → capabilities →
               MatchConfig agreement (N-way) → book commitments/hashes → matchId fixed
[turn loop]    per turn: action commits ∥ move commits → move reveals →
               entropy commit/reveal (N-party XOR) → delayed-spell reveals →
               action reveals (+ proof verification) → resolution (local, deterministic)
               → signed state hash (doubles as the turn's chained ack)
[exceptions]   pause/rejoin (§12) · evidence & ejection (§11) · group decision votes
[end]          win condition → N-signed match record → book reveals → session close
```

Every phase is a **broadcast round**: each living player emits exactly one signed frame
for the phase, and the round completes when a valid frame from every living player is
held locally (the *phase barrier*, §9.2).

---

## 5. Topology & transport

### 5.1 Links

- **Full mesh attempted at handshake:** 6 players = 15 pairwise TCP links (each device
  holds ≤5 sockets). This is trivial for LAN sockets; the existing
  `LanSocketTransport` generalizes from one connection to a small pool.
- The `Transport` abstraction grows a multi-peer sibling — do **not** widen `Transport`
  itself (2P star code keeps using it):

```dart
/// A best-effort broadcast fabric over N-1 direct links + gossip relay.
abstract class MeshFabric {
  /// Hand a signed frame to the fabric; it reaches all reachable peers
  /// (directly or by relay). Fire-and-forget; delivery is confirmed at the
  /// protocol layer (phase barriers), never the transport layer.
  void broadcast(Uint8List signedFrame);

  /// All frames received (direct or relayed), deduplicated by frame hash,
  /// signature NOT yet verified (protocol layer verifies).
  Stream<Uint8List> get onFrame;

  /// Link-state changes, for pause detection (§12).
  Stream<LinkEvent> get onLinkEvent;
}
```

- iOS interop is preserved exactly as in M4: plain TCP over shared WiFi, mDNS
  discovery. No platform-native "nearby" API. **BLE stays capped at 2 players**
  (existing `BATTLE_PROTOCOL.md` §9); mesh is LAN/WiFi-only.

### 5.2 Gossip flood (the one mechanism that does two jobs)

On receiving a frame with an unseen hash:

1. Check structural validity + signature against the roster. Invalid → drop, penalize
   the **link** (rate-limit), never the claimed author (relays can't forge, so garbage
   is the relayer's fault or line noise).
2. Store in the turn's frame log (keyed by *slot*, §6.2).
3. Rebroadcast once to every link except the one it arrived on.

Dedup by SHA-256 of the full signed frame. Per-turn frame counts are small and bounded
(§15), so the seen-set resets each turn. **Do not build smarter gossip (hash-announce /
pull) in v1** — measure first; flood at this scale is a few hundred small messages per
turn on LAN (§15).

### 5.3 Relay correctness argument

A relay can: drop (indistinguishable from link loss → pause machinery handles it),
delay (phase barrier just waits; timeouts handle pathological cases), or duplicate
(dedup handles it). It **cannot** alter or forge (Ed25519). Therefore relayed frames
need no additional trust — which is why the relay decision (§3.3) is nearly free once
frames are signed, and why signing is non-negotiable even in the interim star (§16).

---

## 6. The signed frame envelope (protocol v2)

### 6.1 Wire format

All integers big-endian, matching existing wire conventions.

```
[1B  protocolVersion = 0x02]
[32B matchId]
[4B  turnNumber]            (0 during handshake phases)
[1B  phase]                 (phase enum, §9.1)
[1B  authorIndex]           (index into the signed roster, 0-based)
[4B  seq]                   (0 for single-frame phases; reserved for multi-frame)
[32B prevPhaseSetHash]      (chained ack, §9.3; zeros in the first phase)
[4B  payloadLen]
[... payload]               (same payload encodings as BATTLE_PROTOCOL.md types)
[64B ed25519 signature]     over: "RWMESH2" ‖ all preceding bytes
```

- **`authorIndex` + roster, not raw pubkeys per frame:** the roster is fixed and signed
  at handshake (§7); 1 byte per frame instead of 32, and the roster is the single
  place identity is bound.
- **Domain separation** (`"RWMESH2"` prefix) prevents any cross-protocol signature
  reuse (e.g. a match-record signature replayed as a frame).
- **The old 1-byte `BattleMsgType` becomes the `phase`/payload discriminator** — reuse
  the existing type-byte space and payload encodings wherever they carry over
  unchanged; the envelope is new, the payloads mostly are not.

### 6.2 Slots and equivocation

A frame's **slot** is `(authorIndex, turnNumber, phase, seq)`. The honest protocol
emits **exactly one frame per slot**. Two structurally valid frames with valid
signatures in the same slot but different hashes = **equivocation evidence** (§11.1) —
the pair is self-incriminating, portable, and verifiable by anyone with the roster.

### 6.3 Replay resistance

`matchId` (unpredictable, §7.3) + `turnNumber` + `phase` + `seq` are all under the
signature, so no frame can be replayed across matches, turns, or phases. Within a slot,
replay is dedup'd (identical hash) or equivocation (different hash). This subsumes the
B-3 signing TODO and the `matchId`/`turnNumber`-binding hardening flagged in
`BATTLE_PROTOCOL.md` §3b — do not implement those separately for the mesh.

### 6.4 Size discipline

- Hard cap on `payloadLen` (B-7 heritage): 256 KiB (fits a proof frame comfortably);
  frames above the cap are dropped and the link penalized.
- Fixed-size payloads for commitment phases (they are hashes) — no padding needed.
  Variable-size reveals (action bytes, delayed-spell lists) may pad to coarse buckets
  if traffic analysis ever matters; **defer until someone demonstrates a leak.**

---

## 7. Session establishment

### 7.1 Lobby and roster

- mDNS discovery as today (`match_discovery.dart`). One device acts as **lobby
  leader** — a purely *social* role (collects the roster, hits "start"); it has **zero
  protocol authority** after the roster is signed.
- Roster = ordered list of `(displayName, ed25519 pubkey, ownerPubkeyHex)` sorted by
  pubkey bytes (canonical order → stable `authorIndex`).
- Every player signs `SHA-256("RWROSTER" ‖ canonical roster bytes ‖ lobbyNonce)` and
  broadcasts the signature. **The match does not start until every player holds all N
  roster signatures.** This is the moment identity binds; everything after is
  attributable.

### 7.2 Config agreement, N-way

`MatchConfig` exchange generalizes from "compare with the one peer" to: everyone
broadcasts their config frame; configs must be **byte-identical** across all N (the
lobby UI's job is to make that true before start — protocol just verifies). Any
mismatch → abort before any hidden information moves. Capabilities (RAM tier caps) are
broadcast and the effective tier is `min` over the roster, as today with 2.

### 7.3 matchId

```
matchId = SHA-256("RWMATCH" ‖ roster hash ‖ MatchConfig canonical bytes ‖ XOR of N lobby nonces)
```

The lobby nonces are a commit-reveal round (same `CommitRevealEntropy` machinery) so no
single player — including the lobby leader — can grind the matchId.

### 7.4 Book commitments

`bookCommit` (Merkle root) and `bookHash` broadcast by everyone, stored per-player.
Post-match `bookReveal` likewise. The existing duplicate-commitment (Kin-stacking)
check runs per-player; the **cross-player** same-grid case is legal by design (the
commitment is grid-only — CLAUDE.md invariant #2).

---

## 8. N-party commit-reveal entropy

### 8.1 The protocol

Direct generalization of `BATTLE_PROTOCOL.md` §3:

```
Phase entropyCommit:  every player broadcasts SHA-256(nonce_i)      [32B nonce]
  — barrier: all N commits held —
Phase entropyReveal:  every player broadcasts nonce_i
  — barrier: all N reveals held, each verified against its commit —
joint_entropy = nonce_0 XOR nonce_1 XOR … XOR nonce_{N-1}
```

Properties: as long as **at least one** player's nonce is honestly random, the XOR is
uniform. The last revealer learns the outcome first but committed already — they can
only *withhold*, not *steer*. The existing `_HashRng` hash-counter stream and every
consumer of joint entropy are unchanged.

### 8.2 Withholding

A player who never reveals hits the phase timeout → pause machinery (§12). If they
rejoin, **they must reveal the nonce matching their commit** — the commitment survives
the disconnect, so nothing was dodged. If they never return → group decision → if
forfeited, §8.3 applies.

### 8.3 Entropy after ejection/forfeit — the 1-bit grinding hole, closed

Naive recovery ("recompute XOR over the remaining N−1 reveals") gives a leaving player
a choice between **two entropy outcomes fixed at commit time** (with-me / without-me) —
a 1-bit grind that could be spent for a teammate's benefit. Rule:

> **If a player is ejected or forfeited after the commit barrier but before entropy was
> consumed, and their nonce was never revealed, the remaining players discard the
> round and run a fresh commit-reveal.** Fresh commits = randomness the leaver could
> not have predicted. If their nonce *was* revealed (ejection for an unrelated
> offense), keep the original XOR including their revealed nonce — it's already fixed
> and unbiased.

Same rule applies to `refreshEntropy` (mid-resolution refresh, §3b of the battle
protocol), which generalizes to N identically.

---

## 9. The turn loop, generalized

### 9.1 Phases

Same sequence as today, each now an N-party broadcast round:

```
0x35 actionCommit      all players, simultaneous
0x30 moveCommit        all players, simultaneous
0x31 moveReveal        all players, after move-commit barrier
0x20 entropyCommit     all players                     (renamed nonceCommit)
0x21 entropyReveal     all players, after barrier      (renamed nonceReveal)
0x37 delayedSpellReveal all players
0x36 actionReveal      all players, after entropy      (+ proof payloads, §13)
      — local deterministic resolution, no wire traffic —
0x34 stateHash         all players (signed by the envelope like everything else)
```

Movement conflict resolution, spell resolution ordering, and summon AI are already
deterministic; they iterate **sorted by playerId** (never map insertion order) and take
`Map<playerId, decision>` inputs — the 2P code is already close to this shape
(`movePaths = {localPlayerId: …, peerId: …}`); finish the generalization rather than
special-casing player counts.

**Resolution-order tiebreak extension:** today it's `(spell.t asc, commitmentHex asc)`.
With N casters, two players *can* legally cast the same commitment in the same turn
(starter runes make this likely!). Extend to `(spell.t, commitmentHex, casterId)` —
casterId = roster index. Pin with a test the moment the mesh turn loop exists.

### 9.2 Phase barriers

A player proceeds past phase P when it holds one valid frame per living player for P.
No explicit ACK messages — **the next phase's frames are the acks** (§9.3). Timeouts:
soft timeout → status ping / UI "waiting for Dana…"; hard timeout → pause (§12).
Concrete durations are `[DECISION — needs Soren]` and belong with the turn-timer design
(same flag as the existing 2P TODO); the architecture only requires that they exist and
be `MatchConfig`-agreed.

### 9.3 Chained set-hashes — closing the split-view window

Gossip guarantees *eventual* convergence of frame sets, but a player must **act** on
phase P (e.g. reveal after commits) at some moment, and a partition could mean two
honest players acted on different views that each looked complete… only if a cheater
equivocated (honest frames are single per slot, and a *complete* barrier means all N
slots filled — two different complete views require some slot with two frames, i.e.
equivocation). The chained set-hash makes this detectable **at the very next phase**
with zero extra rounds:

- `prevPhaseSetHash` = SHA-256 of the concatenated hashes (sorted) of the exact frame
  set the author used to satisfy the previous barrier.
- On every incoming frame, compare against your own set hash for that phase. Mismatch →
  **set reconciliation**: both parties exchange their frame sets for that phase
  (they're signed — exchange is safe). Outcomes:
  - Two valid frames in one slot surface → **equivocation evidence** against that slot's
    author (§11.1). This is the overwhelmingly common resolution.
  - A player who declared a set hash they cannot produce frames for → fault on **them**
    (they signed a claim about what they saw and can't back it) → evidence (§11.2).

The state-hash phase (0x34) carries the set hash for the whole turn's final phase, so
every turn ends fully acked.

---

## 10. State-hash lockstep, N-party

### 10.1 Agreement

`BattleState.toCanonicalBytes()` is unchanged (it already sorts by playerId and holds
N-player-shaped data). All N broadcast their signed hash; all-equal → turn committed,
proceed.

### 10.2 Divergence — resist the urge to accuse

A state-hash mismatch means *someone's simulation differs*. Unlike every other
detection in this document, a bare mismatch **does not identify the liar** — and in
practice, the most likely cause is a **determinism bug**, not a cheat (float creep, map
iteration order, version skew). Policy:

1. Partition players by reported hash.
2. If the divergent minority's frames also show a *protocol* violation (bad reveal,
   equivocation, invalid proof) → that's the real evidence; eject on it (§11).
3. Otherwise: **abort with a diagnostic record**, not a blame record — all signed
   frames + all state hashes, enough to reproduce offline. Majority does **not** imply
   honesty (5 colluding modified clients vs 1 honest is a valid configuration of this
   threat model). *Never eject on state-hash majority alone.*
4. Every abort-diagnostic is a bug report. If offline replay of the signed frame log
   through the reference engine reproduces one side's hash, the other side's client
   diverged — that's your lead, and if it's a legit bug it's a `RULESET`-relevant fix.

This asymmetry is deliberate: eject only on **self-incriminating cryptographic
evidence**; abort on ambiguity. It's what keeps false accusations impossible.

### 10.3 Signed frame log = match record substrate

Keep every signed frame for the match duration (bounded, §15). The final N-signer match
record (design doc: "N signers, not two") references the final state hash; the frame
log is the audit trail behind it and the input to any post-match dispute or replay.

---

## 11. Evidence & ejection

### 11.1 The evidence catalogue

Every evidence object must be **verifiable by a third party holding only the roster** —
no trust in the accuser. Each detection below pairs with an attack test (the §10/§11
golden-vector discipline, applied to netcode):

| Code | Evidence object | Verify by |
|---|---|---|
| `equivocation` | two signed frames, same slot, different hash | 2 sig checks + slot compare |
| `false_set_claim` | signed frame with `prevPhaseSetHash` H + author's failure to produce a matching set within timeout | sig check + timeout attestation signed by ≥1 other player (weakest evidence class — see below) |
| `bad_reveal` | signed commit frame + signed reveal frame that doesn't hash to it | 2 sig checks + 1 hash |
| `invalid_proof` | signed actionReveal containing proof bytes that fail `verify_ultra_honk` | sig check + proof verify |
| `cost_fraud` | signed cast + proof publics ⇒ certified cost > declared/spent mana per the deterministic ledger | sig check + recompute |
| `not_in_book` | signed cast whose commitment fails Merkle membership vs that player's own signed bookCommit | sig checks + Merkle verify |
| `double_cast` | two signed casts of one commitment (per-caster once-per-match rule) | 2 sig checks |
| `bad_scry_opening` | signed `scryOpen` envelope + the scryer's exposed single-use `EK_priv` ⇒ AEAD failure, or a leaf that mismatches the author's own committed hash | sig checks + `EK_priv`↔`EK_pub` check + decrypt + 1 hash (§13b) |

`false_set_claim` and reveal-*withholding* are the two that involve **absence** of a
message, which no signature can prove. They resolve through the pause/timeout machinery
(§12) rather than instant ejection: unreachability and refusal look identical on the
wire, and the design treats them identically — pause, window, then group decision. A
cheater "escaping" via fake disconnect still loses by forfeit; nothing better is
available to them, so nothing is lost.

### 11.2 The ejection transition

On receiving (or producing) a valid evidence object, a client broadcasts it in an
`evidence` frame (new type byte). Every honest client **independently verifies** the
evidence — never take ejection on anyone's word — and then applies, at the next phase
boundary (a deterministic point):

```
ejectPlayer(playerId, reasonCode, evidenceHash):
  avatar → eliminated (as if hp ≤ 0)
  pending commitments (delayed spells, counter charms, mystery commits) → voided, never revealed
  outstanding entropy round → §8.3 rule
  roster entry → flagged ejected (frames from them no longer expected at barriers, still logged)
  win-condition check runs (their team may thereby lose)
```

The transition is part of the deterministic simulation — it feeds `toCanonicalBytes`
via the avatar elimination — so the next state hash confirms all honest clients applied
it identically. Two players ejected in one turn: process in evidence-hash order
(deterministic). The ejection event + evidence hash goes in the match record.

Voiding (not revealing) an ejected player's pending commitments is the default because
forcing reveals would require their cooperation, which is exactly what's absent.
`[DECISION — needs Soren]` only if playtesting shows voiding creates a perverse
incentive (e.g. deliberately getting ejected to un-commit a bad mystery spell — note
the ejected player *always loses*, so the incentive looks negligible).

---

## 12. Pause, rejoin, resync

### 12.1 Detection & pause

Missing frames past hard timeout, or `LinkEvent` losses, mark a player
**suspect-offline**. Any player may broadcast `pauseProposal(playerId)`; when every
*reachable* player has echoed it (their next frames chain-ack it), the match is paused:
no phase progression, UI shows who dropped and the countdown. Because a partition can
make *different* players look offline to different observers, the pause proposal
carries the proposer's reachability view; the pause is over the **union** of suspects.

### 12.2 Rejoin

The window is `MatchConfig.rejoinWindowSeconds` (default 180). Rejoin:

1. Reconnect (mDNS re-discovery, links to any reachable subset — relay covers the rest).
2. Authenticate: sign a fresh challenge with the roster key. (Device swap mid-match is
   thereby impossible — keys are device-custodied. That's accepted; losing your phone
   mid-duel loses the duel, consistent with the self-custody invariant.)
3. Resync: request from **any** peer:
   - `BattleState` canonical bytes as of last committed turn,
   - all N signed `stateHash` frames for that turn (proof the state is the agreed one —
     including the rejoiner's *own* signature from before the drop, which they can
     trust absolutely),
   - the signed frame set for the current partial turn.
4. Verify all signatures against the roster; re-derive state hash from the received
   bytes; resume at the exact phase boundary. **Outstanding commitments still bind**
   (§8.2) — the rejoiner reveals what they committed or is forfeited for `bad_reveal`
   refusal via the normal timeout path.

A resync source can *withhold* (rejoiner retries others) but cannot *falsify* —
everything handed over is signed by N parties. This is why rejoin needs no trust and no
quorum vote.

### 12.3 Window expiry → group decision

`groupDecision` round (new frame type): every remaining player broadcasts
forfeit-and-continue | abort. **Unanimous forfeit → continue** (the §11.2 transition,
reason `abandoned`); otherwise abort with a no-fault record. Unanimity, not majority,
because continuing changes competitive stakes for everyone and a majority of one team
must not be able to force it. `[DECISION — needs Soren]` if unanimity proves annoying
in playtests (alternative: unanimity-minus-teammates-of-the-dropped).

---

## 13. ZK proofs & certified cost, N-party

- **Every client verifies every remote cast's proof** — `verify_ultra_honk` is
  tens-of-ms cheap; 5 remote casters is nothing. The verifier init invariant holds
  (Bug Avoidance #4: `initSrsCached` before first verify).
- `_certifiedManaCost` stays the **only** cost path (B-1/B-8), generalized from "the
  peer" to a per-playerId ledger. It must remain operation-order-identical to
  `_spellManaCost`. Do not, under any refactor pressure, introduce a per-player cost
  cache computed anywhere else.
- Per-caster once-per-match commitment replay (`_usedCommitments`) becomes
  `Map<playerId, Set<commitmentHex>>` — per player, **not** global, because two players
  legally cast the same grid (grid-only commitment invariant).
- Counter-charm targeting is unchanged: commitments are grid-only, so a charm committed
  against a commitment counters **any** caster's instance of that grid. With 6 players
  this becomes strategically richer (starter runes especially); no protocol change, but
  flag for playtest tuning.
- Book membership: verify each cast against **that caster's** signed `bookCommit`.

---

## 13b. Asymmetric information effects — the scrying pattern

*Added 2026-07-15 (airy-scrying-pool review). The standing pattern for any effect that
grants ONE player private knowledge of another player's committed-but-unrevealed
information — the airy scrying pool ("see what tile that player's spell is targeting")
is the type case; other scrying-pool effects follow the same recipe.*

### 13b.1 The tension, and why "just send it privately" isn't quite enough

Gossiping the opened information to everyone (§5.2's default) would destroy the
advantage the effect exists to grant. The obvious fix — the victim sends the opening to
the scryer over their direct link; everyone else verifies the full commitment at the
normal public reveal a few phases later — is sound in its trust core: the scryer checks
what they receive against the victim's already-broadcast commitment hash *immediately*,
so the victim cannot lie, and the room re-verifies everything at reveal. Three defects
remain, all fixable:

1. **Over-reveal.** `actionCommit` is one hash over the whole action; opening "the
   target tile" from it means handing the scryer the *entire* preimage — spell identity
   included. The effect's design grants a tile, not the whole action.
2. **Unprovable withholding, and relay leakage.** A plaintext private send breaks two
   architecture properties at once. Absence stops being globally observable: "V never
   sent it" vs. "S is lying about not receiving it" is undecidable by the other four
   players — §11.1's absence problem, but invisible to the room instead of resolved at
   a public barrier. And §5.3 relay may legitimately route any frame through *other
   players' devices* — a plaintext opening transiting a teammate's phone leaks the
   secret to exactly the people it is hidden from.
3. **Determinism hazard.** Whether the scryer received/decrypted the opening is private
   knowledge; the shared simulation must never branch on it, or state hashes fork on
   something unobservable.

The fix changes the *transport* (encrypted broadcast, never a private link) and the
*commitment structure* (openable leaves) — not the trust story.

### 13b.2 The pattern

1. **Split, salted sub-commitments.** Any commitment a scry effect can partially open
   is structured as independently salted leaves combined into the committed hash:
   `actionCommit = SHA-256( H(spell_part ‖ salt_a) ‖ H(target ‖ salt_b) ‖ … )`.
   Opening the target leaf reveals `(target, salt_b)` and nothing else; the public
   `actionReveal` opens all leaves and everyone verifies the whole structure as today.
   Salts are fresh per commitment — small spaces ("61 tiles") are trivially
   brute-forceable unsalted, same rule as mystery/counter-charm commitments. This is a
   wire-visible format change: introduce it with a protocol version bump the first time
   any openable-commitment effect ships (star era included).
2. **Encrypted broadcast, never a private link.** The opening travels as a normal
   gossiped, signed, slotted frame — everyone observes *that* it was sent (absence is
   handled by the standard barrier/timeout machinery, §9.2/§12); only the scryer can
   read *what* it says. Per scry instance:
   - Scryer S broadcasts a `scryKey` frame carrying a **fresh, single-use** X25519
     public key `EK_pub` (never a long-term key).
   - Victim V generates its own ephemeral pair `VK`, derives
     `key = HKDF( ECDH(VK_priv, EK_pub), matchId ‖ turn ‖ slot )`, and broadcasts a
     `scryOpen` frame: `VK_pub ‖ AEAD(key, leaf opening)`, padded to fixed size.
   - S derives the same key from `EK_priv` + `VK_pub`, decrypts, and verifies the leaf
     against V's committed hash — instantly, before acting on the information.
3. **Disputes are third-party verifiable by ephemeral-key exposure.** If the envelope
   fails AEAD authentication or the leaf mismatches V's commitment, S broadcasts
   `EK_priv` as evidence. Anyone checks `EK_priv ↔ EK_pub` (pinned in S's signed
   `scryKey` frame), re-derives the key from V's signed `scryOpen`, decrypts, and
   checks the leaf — a bad opening is self-incriminating for V (`bad_scry_opening`,
   §11.1). Exposing `EK_priv` costs S nothing (single-use), and S only ever burns the
   secrecy when V has already cheated; an honest opening is never exposed.
4. **Mechanical consequences key off observable facts only.** For any in-simulation
   purpose, "the scry succeeded" means *the `scryOpen` frame was present at its
   barrier* — nothing more. Content failures route through evidence → ejection
   (§11.2), itself a deterministic transition. The simulation never reads the private
   content.
5. **Openings only after the opened commitment's phase barrier.** The effect table
   hard-codes the opening point (like `refreshEntropy` call sites — every client hits
   it at the same deterministic spot), and it may only fall **after the barrier of the
   phase containing the opened commitment**. Consequence: the scryer's own same-phase
   decisions are already sealed, so the advantage is structurally bounded to
   later-phase decisions (see the committed target after `actionCommit`, dodge with
   `moveCommit`) or later turns. No scry can ever un-seal a decision.
6. **Both scry frames are mandatory slots** once the effect is publicly active (spell
   resolution is public, so the room knows who scries whom, and when). A scryer who
   doesn't want the information still sends `scryKey`; a victim always answers with
   `scryOpen`. Barriers stay uniform — no conditional slot logic.

### 13b.3 Interactions and caveats

- **What the room learns anyway:** that the scry happened, between whom, and when. The
  effect's *existence* is public; only its *content* is confidential. Don't design a
  scry whose balance depends on the victim not knowing they're scried — the victim's
  *client* must produce the opening, so a modified client always knows. Victim-facing
  secrecy is honest-UI courtesy only, never enforceable.
- **The scried value is the committed one.** If later entropy re-randomizes the actual
  outcome (bookmark retargeting and kin), the scryer saw the commitment, not fate.
  Game-design flavor, not a protocol defect.
- **Collusion:** the scryer can whisper what they saw — out of scope (§1), like every
  other secret at the table.
- **Ejection / rejoin:** scry envelopes are ordinary logged frames — a rejoining
  scryer recovers them in resync (`EK_priv` lives on their device, per self-custody);
  a victim ejected before the public reveal has their commitments voided as usual
  (§11.2) — the scryer's glimpse of a spell that never fires is harmless.
- **Star-era note:** the same envelope works hub-and-spoke — the host relays ciphertext
  it cannot read (one fewer `// TRUST(host):`). If a scrying effect ships during the
  August-era star build, implement this pattern there directly; do not ship a
  plaintext-to-host interim.

---

## 14. Match records

As reserved in the design doc: **N signers, never a hardcoded pair.** The record
carries roster, config hash, final state hash, ejection events (+ evidence hashes),
forfeits/abandonments, and all remaining players' signatures. A record signed by all
non-ejected players is complete; ejected/abandoned players' signatures are welcome but
not required (they may refuse; their loss is attested by the others + evidence).

---

## 15. Performance envelope

Per turn, per player: ~8 frames, mostly ≤100 B (hashes) + one actionReveal that may
carry a proof (~10–20 KiB). Flood cost: each frame transits each of ≤15 links ≤2×
(send + one rebroadcast per receiving node minus dedup) → worst case a few hundred
frames ≈ low hundreds of KiB per turn across the whole room. Venue WiFi handles this
with three orders of magnitude to spare; **do not optimize gossip before measuring.**
Frame log for a 50-turn match: ~2,400 frames, ≲5 MB with proofs — keep in memory,
persist on match end with the record.

The real perf risks are elsewhere: (a) 6 phones running full simulation + 5 proof
verifications per cast burst — measure on the weakest supported device; (b) phase
barriers make the *slowest human* the clock, which is a game-design (turn timer)
matter, not a protocol one.

---

## 16. Migration path — what the star build should do NOW

The star topology for August is throwaway *authority*, but it need not be throwaway
*code*. Each item below is cheap during star-mode work and expensive to retrofit:

1. **Implement Ed25519 frame signing** (the existing `stateHash` TODO, but for all
   frames). The envelope of §6 minus gossip works fine hub-and-spoke. This is the
   single highest-leverage item: it makes star-mode messages *already* evidence-grade,
   and the mesh inherits the format.
2. **Key every structure by `playerId`, never local/peer booleans.** The turn loop's
   `movePaths` map is the pattern; hunt down remaining `peer*` singletons
   (`peerBookRoot`, per-peer used-commitment set, …) and make them
   `Map<playerId, …>` even while N=2-with-host.
3. **Roster + rosterCommit at lobby time**, even with a host. The host relays; identity
   still binds pairwise-verifiably.
4. **`protocolVersion` in `MatchConfig`** and reject-on-mismatch, so v2 negotiation
   isn't a flag day.
5. **N-signer match-record struct** (already design-mandated).
6. **Keep `BattleState.toCanonicalBytes` N-clean** — it already is; guard it with a
   3-and-6-player serialization test now.
7. **Write the star host as a *sequencer*, not an *oracle*:** the host orders and
   relays messages but clients still verify commits/reveals/proofs pairwise where
   possible. Every place the playtest code "just trusts the host" is a line item in the
   mesh migration — keep a `// TRUST(host):` comment convention and grep for it when
   mesh work starts. That grep output *is* the gap analysis.

---

## 17. Build plan (when the time comes)

Contract → Dart oracle → wire → devices, per house discipline. Every mechanism lands
with its attack test (a `CheatingFabric`/`CheatingPlayer` test double that equivocates,
withholds, replays, over-claims) — **a detection you can't write a cheating client for
is a detection you don't understand yet.**

- **MESH.1 — Envelope + roster.** Signed frame codec, roster commit, matchId
  derivation. Pure Dart, no I/O. Attack tests: forged sig, cross-match replay,
  slot conflicts.
- **MESH.2 — Fabric.** `MeshFabric` over in-memory transports (N in-process nodes),
  gossip flood + dedup + relay. Attack tests: partition relay, duplicate storms,
  garbage-from-link.
- **MESH.3 — Broadcast rounds.** Phase barrier + chained set-hashes + N-party
  commit-reveal. Attack tests: equivocation capture end-to-end, false set claim,
  bad reveal, §8.3 entropy-regrind.
- **MESH.4 — Turn loop generalization.** `TurnLoop` over N `Map<playerId,…>` inputs;
  resolution tiebreak extension; state-hash round. Regression: full 2P suite must
  still pass with N=2 (the mesh with N=2 should be *behaviorally identical* to the
  lockstep protocol — that equivalence is the migration safety net).
- **MESH.5 — Evidence & ejection.** Catalogue of §11, deterministic transition, match
  record. Attack tests: one per catalogue row, plus double-ejection ordering.
- **MESH.6 — Pause/rejoin/resync + group decision.** Attack tests: resync from a
  lying source (must fail closed), rejoin with withheld re-reveal.
- **MESH.7 — Localhost N-instance soak,** then **real-device gate**: 6 physical phones
  on real venue-grade WiFi, including a mid-match phone reboot and a mid-match WiFi
  drop. Per the verification hierarchy, MESH.7 on hardware is the done-gate; nothing
  before it counts as validated.

Findings go in `docs/MESHn_findings.md` as you go — including what didn't work.

---

## 18. How to add features on top of the mesh (the standing checklist)

Any future feature — new spell effects, new win conditions, spectators, tournaments —
answers these questions **before** code. This section is the part of this document
meant to outlive the details above.

1. **Does it touch simulation state?** Then it must be: integer-only, iteration sorted
   by stable keys, seeded exclusively from joint entropy, and **added to
   `toCanonicalBytes`** (a state field outside the hash is a consensus hole — the hash
   must cover everything the simulation reads). Bump the protocol/battle version.
2. **Does it involve a player decision?** Then it commits **before** the entropy that
   resolves it is revealed (the B-5 rule), via the standard commit-reveal frames, in
   its own slot. No decision ever travels plaintext-first.
3. **Does it involve hidden information?** Salted commitment at the moment the
   information becomes fixed, reveal at the moment it acts (the mystery-spell/counter-
   charm pattern — salt mandatory, small commitment spaces are brute-forceable).
4. **Does it grant one player private knowledge of another player's committed
   information?** That's the scrying pattern — follow §13b: split salted
   sub-commitments, encrypted-broadcast openings (never a plaintext private send —
   relay would leak it and withholding would be unprovable), and mechanical
   consequences keyed only to globally observable frames.
5. **Does it need mid-resolution randomness a player could react to?** Use the
   `refreshEntropy` seam at a table-hard-coded resolution point; never a second RNG.
6. **Does it add a message?** Contract-first in `BATTLE_PROTOCOL.md`: type byte from
   the reserved space, payload encoding, slot semantics (one frame per author per
   phase?), barrier participation, and the **timeout/absence behaviour**. Unknown types
   from a roster peer are a protocol violation in v2 (versions negotiated at config —
   there is no legitimate unknown frame), not a silent drop.
7. **What's the attack?** Write the cheating-client test first. If you cannot say what
   a malicious participant would send and how it's caught (which evidence-catalogue
   row, or which new row + verifier), the feature is not specified yet. New evidence
   rows must stay third-party-verifiable from the roster alone.
8. **Does it change what an ejected/rejoining player must produce?** Check §8.3 and
   §12.2 interactions — commitments must survive rejoin, and voiding-on-ejection must
   stay deterministic.
9. **Does it widen any trust seam?** Any value computed by one client and believed by
   others is a B-1-class bug. The rule is: **peers send claims; clients recompute.**
   If recomputation is impossible, the claim needs a proof (ZK or signature) or it
   doesn't ship.
10. **Version it.** Consensus-visible changes bump the battle protocol version;
   CA-visible changes bump `RULESET_VERSION` (VK-breaking, deliberate). Mixed-version
   lobbies reject at config, never mid-match.
11. **Validate on hardware** before calling it done, with at least one adversarial run
    (the cheating client on a real phone, not just in-process).

And three standing prohibitions: no second mana-cost path, ever (B-1/B-8); no
reimplementing hashes client-side (CLAUDE.md invariant #1 — mesh code treats
commitments as opaque bytes exactly like the ZK layer does); no feature that requires a
server, an account, or a recovery backdoor (the identity invariant is
architecture-wide).

---

## 19. Open questions — flagged, not blocking

- `[DECISION — needs Soren]` Phase timeout durations + turn timer (shared with the
  existing 2P TODO; UX-driven, decide from playtest feel).
- `[DECISION — needs Soren]` Group-decision unanimity vs unanimity-minus-teammates
  (§12.3) — only if playtests surface griefing.
- `[TODO — playtest]` Counter-charm meta with 6 players and shared starter-rune
  commitments (§13).
- `[TODO — playtest]` Whether voided-on-ejection commitments create any incentive to
  get ejected (§11.2 — expected no, since ejection is always a loss).
- **Spectators**: read-only roster members who receive the flood, verify everything,
  and sign nothing. Architecturally almost free (they're a roster entry with no slots
  at barriers) — but out of scope until asked for.
- **Out-of-band collusion** stays out of scope permanently; it's a game-design and
  social-layer question.
- **BLE mesh**: not planned. BLE stays a 2-player transport; the mesh assumes WiFi
  bandwidth and connectivity.
