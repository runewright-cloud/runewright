# Runewright — Battle Protocol (`BATTLE_PROTOCOL.md`)

*Contract-first: this document is written before the code that produces or consumes
these messages. Any inter-client message introduced in `lib/battle/` must be documented
here first. When this document and the code disagree, the code is wrong.*

---

## 0. Session lifecycle

Two paths reach `BattleSession`:

- **Proof-exchange path** (original design; not the LAN lobby's actual path — see below):
  after the `MatchSession` proof handshake (`lib/protocol/match_session.dart`), `BattleSession`
  reuses the same `Transport` and inherits a `matchId` from that handshake.
- **LAN duel setup path** (what `battle_lobby_screen.dart` actually runs —
  `runDuelSetup` in `lib/battle/networking/duel_setup.dart`, LAN_BATTLE_WIREUP_PLAN.md §3.2):
  there is no proof-exchange handshake to inherit a `matchId` from, so this path
  establishes one itself via a dedicated pre-auth exchange, then runs the identity-auth
  and permission/book/artifact-loadout exchanges before ever constructing `TurnLoop`.

```
[LAN duel setup — runDuelSetup, lib/battle/networking/duel_setup.dart]
  both:       BattleSession(transport, placeholder matchId) ← real matchId not known yet;
                                                                 `this.matchId` is never read
                                                                 internally, so this is safe
                                                                 (see duel_setup.dart's header
                                                                 comment for why placeholder-then-
                                                                 thread-through is required, not a
                                                                 shortcut)
  both:       exchangeMatchIdNonce()    ← each sends a fresh 16-byte nonce; both derive
                                           matchId = SHA-256(sorted(ourNonce, theirNonce))[0:16]
                                           — neither side unilaterally controls it
  both:       exchangeCapabilities()    ← + battleProtocolVersion gate; abort on mismatch
  host:       sendHostMatchConfig(config)     ← host-authoritative (asymmetric — see
  guest:      receiveHostMatchConfig()          exchangeMatchConfig's doc comment for why
                                                 the strict-equality method can't express this)
  both:       exchangeIdentityAuth(matchId: <real, derived above>)  ← BATTLE_AUTH_PLAN §3
  both:       exchangeSpellPermissions()      ← BATTLE_AUTH_PLAN §5
  both:       exchangeBookCommitment() / exchangeBookHash()
  both:       exchangeArtifactLoadout() ← required for state-hash lockstep (peer avatar's
                                           accoutrements/maxMana are hashed every turn —
                                           see duel_battle_setup.dart's doc comment)
  both:       buildDuelBattleState(...) ← symmetric, pubkey-sorted (no host/guest branch)
  → push BattleScreen(session: <this BattleSession>, matchId: <real matchId>, ...)

[proof exchange — existing MatchSession, alternate path above]
  initiator: MatchSession.initiate(transport)
  responder:  MatchSession.accept(transport)
  both:       presentProof / verifyIncomingProof
  both:       MatchSession.close()          ← cancels subscription; transport stays open
  both:       BattleSession(transport, matchId)  ← reuses same Transport + matchId from proof exchange

[turn loop — TurnLoop in lib/battle/engine/turn_loop.dart — both paths converge here]
  both:       exchangeCapabilities() / exchangeMatchConfig() / exchangeBookCommitment()
              (already done above on the LAN duel setup path)
  both:       exchangeNonce()           ← per-battle commit-reveal for initial entropy
              → joint entropy seeds the SpellDraw shuffle for both players
    each turn:
      both:   exchangeActionCommit()        ← action sealed before entropy is known (B-5 look-ahead fix)
      both:   exchangeMoveCommit()          ← movement sealed before entropy
      both:   exchangeMoveReveal()          ← movement resolved
      both:   exchangeNonce()               ← entropy revealed AFTER all player decisions are locked in
      (both:  summons act — deterministic AI, no wire message)
      both:   exchangeDelayedSpellReveals() ← pending delayed spells firing this turn
      both:   exchangeActionReveal()        ← action resolved
      both:   exchangeStateHash()           ← lockstep per-turn state hash (unsigned in Stage 1 —
                                               Ed25519 signing is BATTLE_AUTH_PLAN §6 Phase D,
                                               not yet implemented; see LAN_BATTLE_WIREUP_PLAN §4)
  both:   sendMatchEnd() or sendForfeit()
```

Stage 1 (LAN_BATTLE_WIREUP_PLAN.md §2 DECISION 4): peer spell casts are trusted, not
proof-verified (`TurnLoop.verifyProof` stays null, same as solo/test) — this is an
honest interim milestone, not secure play. Stage 2 turns on proof verification, cast
authorization, and (optionally) signed state hashes.

---

## 1. Framing

Battle messages use the **same wire framing** as the proof-exchange layer
(`lib/protocol/wire.dart`): `[1 byte type][4 byte BE payload length][payload bytes]`.

Battle type bytes are in the range `0x10–0x4F` to avoid collisions with the
proof-exchange `MsgType` bytes (`0x01–0x07`). The framing is otherwise identical; a
`BattleFrameReader` in `lib/battle/networking/battle_wire.dart` implements the same
reassembly logic.

---

## 2. Message types

| Type name | Byte | Direction | Payload | Notes |
|---|---|---|---|---|
| `capabilities` | 0x10 | both→both | JSON: `DeviceCapabilities.toJson()` (`ramTierCap`, `battleProtocolVersion`) | exchanged simultaneously at session start; LAN duel setup aborts on `battleProtocolVersion` mismatch |
| `matchConfig` | 0x11 | both→both (proof-exchange path) or host→guest (LAN duel setup, host-authoritative — DECISION 3) | JSON: `MatchConfig.toJson()` | proof-exchange path: both send, compare, abort on mismatch (`exchangeMatchConfig`). LAN duel setup path: only the host sends (`sendHostMatchConfig`/`receiveHostMatchConfig`) — the guest has no separate opinion to assert, so there's nothing to compare |
| `matchConfigAck` | 0x12 | both→both | empty | sent after comparing configs and agreeing (or, on the LAN duel setup path, after the guest receives the host's config) |
| `matchConfigReject` | 0x13 | both→both | UTF-8 reason string | sent on mismatch (proof-exchange path only); triggers abort |
| `bookCommit` | 0x14 | both→both | 32 bytes: Chapter Merkle root | both send simultaneously |
| `bookHash` | 0x15 | both→both | 32 bytes: SHA-256(sorted leaf bytes) | batch leaf hash exchanged at handshake (Option 2) |
| `bookReveal` | 0x16 | both→both | JSON: sorted `commitmentHex` list | sorted chapter spell list revealed post-match; verified against `bookHash` |
| `authChallenge` | 0x17 | both→both | 32-byte fresh random nonce | BATTLE_AUTH_PLAN.md §3 — mutual Ed25519 challenge-response, run once per session before any cast is trusted |
| `authResponse` | 0x18 | both→both | rawPubkey(32) ‖ sig(64) over `TAG_AUTH ‖ matchId ‖ peerNonce` | see `exchangeIdentityAuth`; forfeits on invalid/stale/self signature |
| `spellPermissions` | 0x19 | both→both | JSON array of `SpellPermission.toJson()` | BATTLE_AUTH_PLAN.md §5 — loan/transfer grants naming the peer as grantee |
| `matchIdNonce` | 0x1A | both→both | 16-byte fresh random nonce | LAN duel setup only (LAN_BATTLE_WIREUP_PLAN.md §3.2 step 1) — establishes `matchId` before anything that needs to sign it |
| `artifactLoadout` | 0x1B | both→both | JSON array of `ArtifactEntry.toJson()` | LAN duel setup only — public equipment loadout (not the secret-until-revealed spell book); required for state-hash lockstep, see `duel_battle_setup.dart` |
| `nonceCommit` | 0x20 | both→both | 32 bytes: SHA-256(nonce) | commit phase of commit-reveal |
| `nonceReveal` | 0x21 | both→both | 32 bytes: raw nonce | reveal phase; verify matches commit |
| `refreshEntropyCommit` | 0x22 | both→both | 32 bytes: SHA-256(nonce) | mid-resolution entropy refresh commit (§3b) — **B-3/B-7 hardening pending** |
| `refreshEntropyReveal` | 0x23 | both→both | 32 bytes: raw nonce | mid-resolution entropy refresh reveal (§3b) — **B-3/B-7 hardening pending** |
| `moveCommit` | 0x30 | both→both | 32 bytes: SHA-256(movement-decision) | movement sealed before reveals |
| `moveReveal` | 0x31 | both→both | variable: serialised movement decision | must match earlier commit |
| `spellCast` | 0x32 | both→both | JSON: `{"spellId":"…","targetHex":{"q":…,"r":…}}` | declares spell cast this turn |
| `haymaker` | 0x33 | both→both | JSON: `{"targetPlayerId":"…"}` | declares haymaker in place of spell |
| `stateHash` | 0x34 | both→both | 32 bytes: SHA-256(BattleState canonical serialisation) + TODO: Ed25519 signature | per-turn lockstep check |
| `actionCommit` | 0x35 | both→both | 32 bytes: SHA-256(action\_bytes ‖ nonce) | action sealed before entropy; nonce is 16 bytes (`_kRevealNonceBytes`) |
| `actionReveal` | 0x36 | both→both | nonce(16) ‖ action\_bytes | reveal after entropy exchange; verified against earlier commit |
| `delayedSpellReveal` | 0x37 | both→both | `[count:1][id:16, coord:4, delay:1, nonce:16 per entry]` | pending delayed spells firing this turn; `[0x00]` if none |
| `forfeit` | 0x40 | sender→peer | UTF-8 reason: `"withheld_reveal"` \| `"concede"` | ends match; peer wins |
| `matchEnd` | 0x41 | both→both | JSON: `{"winningTeamId":"…","finalStateHash":"…"}` | both send after win condition met |

---

## 3. Commit-reveal entropy protocol

Used for: turn entropy (feeds SpellDraw retargeting, movement tiebreaks, burn targeting,
summon collision).

```
Both simultaneously:
  local nonce  ← 32 random bytes (crypto-secure)
  commit       ← SHA-256(nonce)   [see CommitRevealEntropy.commit]
  send nonceCommit(commit)

Both simultaneously:
  receive peer's commit
  send nonceReveal(nonce)

Both simultaneously:
  receive peer's nonce
  verify SHA-256(peer_nonce) == peer_commit
    → if mismatch: send forfeit("withheld_reveal"); end match
  joint_entropy ← peer_nonce XOR our_nonce   [see CommitRevealEntropy.revealAndCombine]
```

The joint entropy is 32 bytes. It is the **single source** for all randomness this turn:
SpellDraw shuffle seeding, bookmark retargeting, burn-accoutrement targeting, and
summon-collision resolution all draw from the same seeded stream derived from it.

**Withheld reveal:** a player who withholds their nonce after committing forfeits. The
verifier detects a timeout or a reveal that doesn't match the commit and sends
`forfeit("withheld_reveal")`. The enforcement seam is real; timeout policy is
`// TODO(battle): define reveal timeout; depends on turn timer design`.

---

## 3b. Mid-resolution entropy refresh seam

Some interactive spell effects may fire at a point in resolution where foreknowledge of
remaining pseudo-random outcomes could influence a player choice on a modified client.
For those effects, `BattleTurnSession.refreshEntropy(reason)` runs a fresh commit-reveal
exchange mid-turn using `refreshEntropyCommit(0x22)` / `refreshEntropyReveal(0x23)`,
producing new joint entropy that seeds resolution from that point forward.

The effect table hard-codes exactly **when** each effect may call `refreshEntropy` — both
clients must hit the call at the same deterministic point in the resolution sequence.
A client that withholds its reveal at 0x23 receives `forfeit("withheld_refresh_reveal:<reason>")`.

The seam is wired (`BattleSession`, `SoloBattleSession`) but **not yet called by any
effect** — this is the integration point for future interactive spells.

**Hardening TODO (B-3 / B-7 scope):** `0x22` and `0x23` are new peer-to-peer surface
added mid-B-5, outside the original audit. Before shipping interactive spells that call
this path, the B-3/B-7 pass must cover:
- Frame payload length cap (B-7)
- Unknown-type handling (drop vs forfeit)
- `matchId` / `turnNumber` binding in the refresh nonce (same domain-separation
  argument as the turn-start nonce)
- Ed25519 signature over the refresh reveal (B-3)

---

## 4. SpellDraw seeding algorithm

Both clients compute the same shuffle for a given player's Chapter using a
**hash-counter stream** seeded from the joint entropy. The construction is
fully specified here; it does not depend on any Dart SDK or VM internals.

```
// Hash-counter stream (_HashRng in lib/battle/engine/spell_draw.dart):
block_i ← SHA-256(joint_entropy_bytes ‖ BigEndian32(i))   // 32-byte block
Bytes are consumed sequentially from block_0, block_1, ... as needed.

// nextInt(max) — bias-free via power-of-2 masking + rejection sampling:
mask ← smallest (power-of-2 − 1) covering [max−1]
         e.g. max=5 → mask=7,  max=20 → mask=31
loop:
  v ← next 4 bytes from stream, interpreted as big-endian uint32
  v ← v & mask
  if v < max: return v    // expected < 2 iterations for all realistic max

// Fisher-Yates shuffle (Knuth, in-place descending):
shuffled ← copy of chapter_spells
for i from len(shuffled)-1 downto 1:
  j ← nextInt(i + 1)
  swap(shuffled[i], shuffled[j])

hand ← shuffled[0 .. bookmarkCount-1]
deck ← shuffled[bookmarkCount ..]
```

On spell use, the next spell from `deck` slides into the vacated hand slot (no
additional randomness; the shuffle order was fixed at draw time).

The Chapter must be in **agreed canonical order** (sorted by `spellId` lexicographically)
before shuffling, so both clients independently compute the same ordering.

`// TODO(battle): chapter contents must be exchanged or their order agreed during
//   matchConfig / bookCommit phase; exact reconciliation protocol TBD.`

---

## 5. BookCommitment

```
book_root ← MerkleRoot(sorted commitmentHex values of chapter spells)
```

Each player sends their `bookCommit` message at session start. The peer stores this root
for later membership-proof verification (e.g. proving a spell is in-chapter without
revealing the full chapter). Hash function: SHA-256(left ‖ right) for interior nodes;
leaves sorted lexicographically by `commitmentHex` (see `book_commitment.dart`).

`bookLeafCount` (`0x1C`): each player also sends their chapter's leaf count — a bare
`uint32` big-endian, sent alongside `bookCommit`/`bookHash` at session start
(`duel_setup.dart` Step 6). This is the minor disclosure SPELL_DRAW_WIRING_PLAN.md §3
calls for: `DrawSchedule` needs the peer's chapter size `n` to compute
`nextInt(n)`-shaped draws for the *peer's* hand/deck bookkeeping, without ever learning
which spells are in it (only the Merkle root, `bookCommit`, commits to contents).

---

## 6. Per-turn state hash (lockstep seam)

After each turn resolves, both clients compute:

```
state_bytes ← BattleState.toCanonicalBytes()   // binary encoding — see below
state_hash  ← SHA-256(state_bytes)
signature   ← TODO(battle): Ed25519 sign(state_hash, local_identity_key)
send stateHash(state_hash ‖ signature)
```

On receipt, each side verifies `peer_state_hash == our_state_hash`. A mismatch is a
**protocol violation** — either a bug or cheating — and ends the match. Signing is
stubbed (the hash exchange is real; the Ed25519 signing body is `// TODO(battle)`).

### Binary encoding (`BattleState.toCanonicalBytes`)

All integers big-endian. No floats anywhere. Strings length-prefixed as
`[uint16 byte-count][UTF-8 bytes]`. Lists sorted as noted so both clients
produce byte-identical output regardless of local insertion order.

```
[uint32]  turnNumber
[uint8]   winCondition ordinal  (0 = lastTeamStanding, 1 = captureTheFlag)
[uint16]  avatar count
for each avatar sorted by playerId:
  [uint16+bytes]  playerId (UTF-8)
  [32 bytes]      ownerPubkeyHex decoded to raw bytes
  [int32]         hp
  [int32]         mana
  [int32]         maxMana
  [int16]         position.q
  [int16]         position.r
  [uint16+bytes]  teamId (UTF-8)
  [uint16]        accoutrement count
  for each accoutrement sorted by id:
    [uint16+bytes]  id (UTF-8)
    [uint8]         kind ordinal  (0=manaGem 1=counterCharm 2=bookmark 3=absorptionRod)
    [uint8]         isCoreGem     (0 or 1)
    [uint8]         counterCharmRevealed  (0 or 1)
    [uint8]         hasTargetCommitment   (0 or 1)
    if hasTargetCommitment = 1:
      [32 bytes]    targetCommitmentHex decoded to raw bytes
  [uint16]        statusEffect count
  for each statusEffect sorted by effectTypeId:
    [uint16+bytes]  effectTypeId (UTF-8)
    [int32]         remainingTurns
    [uint16]        modifier count
    for each modifier sorted by key:
      [uint16+bytes]  key (UTF-8)
      [int32]         value
[uint16]  team count
for each team sorted by id:
  [uint16+bytes]  id (UTF-8)
  [uint16]        playerIds count
  for each playerId in insertion order:
    [uint16+bytes]  playerId (UTF-8)
```

All game-model values (hp, mana, remainingTurns, modifier values) are stored as
integers at the model level — no `double` fields exist in `BattleState` or its
children, so no scaling is required.

---

## 7. Spell resolution ordering

Within a turn's spell-resolve phase, spells are ordered:

1. **Lower T first** (`spell.t` ascending).
2. **Tiebreak: lexicographically smaller `commitmentHex`** (the Poseidon2 grid hash,
   treated as a hex string; smaller sorts first).

This ordering is deterministic given both players' declared spells and requires no
additional randomness.

---

## 8. Win condition

**Default (`lastTeamStanding`):** all members of every opposing team are eliminated
(hp ≤ 0). The last team with at least one living member wins.

**Alternate win condition seam:** `MatchConfig.winCondition` is a negotiated field.
Alternate conditions (e.g. `captureTheFlag`) are `// TODO(battle)` stubs with their
resolution logic documented here when defined.

---

## 9. Player / transport caps

| Mode | Max players | Notes |
|---|---|---|
| Solo | 1 | no networking; BattleSession absent |
| BLE | 2 | star topology unreliable beyond a pair; hard cap |
| LAN | 2 (supported) | 3–6 behind `experimentalMultiplayer: true` in MatchConfig |

3–6 player win condition is `lastTeamStanding` as above.
`// TODO(battle): team assignment UI and turn-order policy for 3+ players.`
