# Battle Identity Authentication + Cast Authorization — Implementation Plan

*Written 2026-07-19 for implementation. Closes the missing cast-time Ed25519
authentication on the battle path (the gap surfaced while planning Sightings).
Decisions in §1 are settled (Soren). Build this **before** SIGHTINGS_PLAN.md —
Sightings' identity records are only trustworthy once this lands.*

---

## 0. Current state (verified)

The battle path binds identity but never authenticates it:

- **Handshake** (BATTLE_PROTOCOL.md §0; `battle_session.dart`): `exchangeCapabilities`
  → `exchangeMatchConfig` → `exchangeBookCommitment`/`exchangeBookHash` →
  `exchangeNonce`. **No identity/pubkey exchange, no challenge, no signature.**
- **`_verifyPeerSpellCast`** (`turn_loop.dart:3050`) verifies the proof and extracts
  `outputs.ownerPubkeyHex` (`proof_intake.dart:173`, public input [1]) but **never
  checks it against an authenticated peer** and **never calls the ready-made
  `castingPlayerMayUse`** (`spell_authorization.dart:64`, explicitly deferred:
  *"Until then pass an empty list"*).
- **`exchangeStateHash`** (`battle_session.dart:366-373`) and BATTLE_PROTOCOL.md §6
  already reserve a `TODO: Ed25519 sign(state_hash)` — an unused signing seam.
- `owner_pubkey = Poseidon2(key_hi, key_lo)` where the halves are the **public**
  key (`identity.dart:96,119`) — a *label*, not a signature and not secret-derived.
  The circuit deliberately never verifies key possession (CLAUDE.md invariant 5).

**Consequence:** a peer can present any `owner_pubkey` its proof declares (forgeable
by anyone holding the victim's raw pubkey), and a static proof can be replayed —
nothing ties a cast to a party that proves it holds the private key. This plan adds
that tie.

**Building blocks already present:** `Identity.sign` / `verify` /
`ownerPubkeyMatches` / `ownerPubkeyHexFromRawKey` / `publicKeyBytes`
(`identity.dart`); `castingPlayerMayUse` (`spell_authorization.dart`);
`SpellPermission` — self-verifying signed grants with `toJson`/`fromJson`
(`spell_permission.dart`); `CommitRevealEntropy.generateNonce`
(`commit_reveal.dart`); `in_memory_transport.dart` for paired-session tests;
`TurnLoop`'s nullable dependency-injection pattern (`turn_loop.dart:397-411`).

## 0a. Dependency & sequencing (read this)

The **LAN → `BattleScreen` setup flow does not exist yet** (see SIGHTINGS_PLAN §0a:
`BattleScreen` is only built from solo/test screens). So the handshake exchanges
added here have **no production caller until that flow lands** — exactly like
Sightings capture. That is fine and expected:

- Everything here is fully implementable and testable **now**, in isolation, via
  paired `in_memory_transport` sessions and unit tests (§10). This is the security
  foundation the LAN flow will build on.
- **When the LAN-flow task is built, it MUST call these exchanges in its handshake
  and construct the peer avatar's `ownerPubkeyHex` from the authenticated
  identity** — auth is a required step, not optional. Add a one-line note to that
  effect in `docs/M4_findings.md` and (if it exists by then) the LAN-flow plan.
- Do **not** expand scope into building the LAN flow here.

---

## 1. Decisions (settled — Soren, 2026-07-19)

1. **Full scope: A + B + C + D.** Handshake mutual challenge-response (A), cast
   authorization (B), loan-permission exchange (C), **and** per-turn signed state
   hash (D) for continuous channel binding.
2. **Loan-permission exchange is in scope now** (C) — loaned spells are authorized
   in battle this pass, not deferred.

---

## 2. Threat model — what each phase closes

| Threat | Closed by |
|---|---|
| Impersonating a *specific* wizard's identity (their pubkey/sigil) in a duel | **A** — you only ever see the identity whose fresh challenge signature verified against a presented key you re-hashed to that `owner_pubkey`. |
| Casting a spell you don't own (replaying someone's proof; forging authorship) | **B** — `castingPlayerMayUse(owner=proof, caster=authenticated K_peer)`; a cast is authorized only if `owner == K_peer` or a valid grant covers it. |
| Loaned-spell casting without breaking B | **C** — verified signed `SpellPermission`s let a genuine loanee cast; forgeries fail signature/expiry. |
| Mid-session connection hijack / lockstep-hash tampering | **D** — every turn's state hash is Ed25519-signed by the authenticated identity. |
| **Out of scope (residual):** passive eavesdrop / full relay-MITM where an attacker interposes as its *own* identity M to both sides | Not closed — but the attacker appears as M's sigil to both, so it cannot imitate a *named* victim. True confidentiality needs an encrypted channel (X25519 AKE) — defer; acceptable for in-person LAN. Document, don't build. |

---

## 3. Phase A — handshake mutual challenge-response

**New wire types** (`battle_wire.dart`, free setup range between `bookReveal`
0x16 and `nonceCommit` 0x20):

```
authChallenge   (0x17)  32-byte fresh random nonce
authResponse    (0x18)  rawPubkey(32) ‖ sig(64)
spellPermissions(0x19)  JSON array of SpellPermission.toJson()  (Phase C)
```

**Sequence** — symmetric, simultaneous send like every other setup exchange:

1. Each side generates `nonceLocal` = 32 crypto-random bytes
   (`CommitRevealEntropy.generateNonce()`; confirm it returns ≥32 bytes, else use
   `Random.secure()`). Send `authChallenge(nonceLocal)`; receive `noncePeer`.
2. Each side signs the peer's fresh nonce and sends its raw key + signature:
   ```
   TAG_AUTH = utf8("RUNEWRIGHT_BATTLE_AUTH_V1\x00")
   msg  = TAG_AUTH ‖ matchId ‖ noncePeer
   sig  = Identity.sign(msg)
   send authResponse( identity.publicKeyBytes(32) ‖ sig(64) )
   ```
3. On receiving the peer's `authResponse` (`peerRawPubkey(32) ‖ peerSig(64)`):
   ```
   ok = Identity.verify(
          message: TAG_AUTH ‖ matchId ‖ nonceLocal,   // the peer signed OUR nonce
          signatureBytes: peerSig, publicKeyBytes: peerRawPubkey)
   ```
   - `ok == false` → `sendForfeit('auth_failed')` and abort the session.
   - `peerOwnerPubkeyHex = await Identity.ownerPubkeyHexFromRawKey(peerRawPubkey)`
     — the authenticated circuit-level identity (K_peer).
   - **Reject self/reflection:** if `peerOwnerPubkeyHex == myOwnerPubkeyHex`, abort
     (`'auth_self'`) — you can't duel yourself; also defeats a reflected response.
   - Return `AuthenticatedPeer(rawPubkey: peerRawPubkey, ownerPubkeyHex: peerOwnerPubkeyHex)`.

**Why this is sound:** signing `noncePeer` proves freshness (the verifier chose it,
so the signature can't be replayed from a prior session) and possession (only the
private-key holder can sign). `ownerPubkeyHexFromRawKey` binds the presented raw
key to the circuit `owner_pubkey` the proofs use. A no-key attacker cannot forge a
signature; a reflection is rejected by the self-check and the wrong-nonce
mismatch. An active relay can only interpose as *its own* identity (§2 residual).

**Where it runs:** a new concrete method on `BattleSession`:
`Future<AuthenticatedPeer> exchangeIdentityAuth({required Identity localIdentity, required Uint8List matchId})`.
Called by the battle **setup** code (before `TurnLoop` construction). Its result
feeds Phases B/C/D. Add `AuthenticatedPeer` as a tiny value class
(`rawPubkey`, `ownerPubkeyHex`).

**Domain separation:** use a *distinct* tag from Phase D (`TAG_STATE`) so an auth
signature can never be replayed as a state-hash signature or vice-versa.

---

## 4. Phase B — cast authorization

In `_verifyPeerSpellCast` (`turn_loop.dart:3050`), after proof verification yields
`outputs` (step 2) and before mana deduction (step 4), add:

```dart
// Cast authorization: the authenticated peer may cast only spells they own
// or hold a valid grant for. peerOwnerPubkeyHex is null in solo/test (skip).
if (peerOwnerPubkeyHex != null) {
  final authorized = await castingPlayerMayUse(
    spellOwnerPubkeyHex: outputs.ownerPubkeyHex,          // proof's declared owner
    commitmentHex: outputs.commitmentHex,
    castingPlayerPubkeyHex: peerOwnerPubkeyHex,           // Phase A (authenticated)
    permissions: peerPermissions ?? const <SpellPermission>[], // Phase C
  );
  if (!authorized) {
    session.sendForfeit('unauthorized_spell:${outputs.commitmentHex}');
    throw StateError('peer cast a spell they neither own nor hold a grant for '
        '(owner=${outputs.ownerPubkeyHex}, caster=$peerOwnerPubkeyHex) — match forfeit');
  }
}
```

- Own-spell casts pass via `castingPlayerMayUse`'s first branch (`owner == caster`).
- Loaned casts require a matching verified `SpellPermission` (Phase C).
- **Avatar binding (setup-side, note for the LAN-flow task):** the peer avatar's
  `WizardAvatar.ownerPubkeyHex` (which feeds the signed state hash, §D and
  BATTLE_PROTOCOL.md §6 `toCanonicalBytes`) MUST be constructed from
  `peerOwnerPubkeyHex`, not from any unauthenticated source. Optionally assert
  `peerAvatar.ownerPubkeyHex == peerOwnerPubkeyHex` once at setup and forfeit on
  mismatch.

Gate on `peerOwnerPubkeyHex != null` so solo/test (where it's null, like
`verifyProof`) is unaffected.

### 4a. Basic-spell exemption (added 2026-07-27, docs/BASIC_SPELLS_PLAN.md)

The five shipped starter spells (`lib/spells/basic_spells.dart`) ship with every
install under a fixed dev `owner_pubkey` — not any individual player's. Without an
exemption, `castingPlayerMayUse` would forfeit the match the first time ANY player
other than that dev key cast one. `isBasicGridAndT(commitmentHex, t)` — checked
against the caster's own **verified** proof outputs, never a wire-supplied claim —
short-circuits both `localIdentityMayUse` and `castingPlayerMayUse` to `true` before
the ownership/permission checks run. This does not weaken the trust model: the proof
still must verify, and `ruleset_version`/mana/geometry are still fully certified —
only the "owner == caster" requirement is waived, and only for five grids that are
deliberately public.

**A second, independent guard needed the same treatment.** `_seenPeerCommitments`
("Kin-stacking" — a peer forfeits on casting the same `commitmentHex` twice in a
match) predates this feature and assumed a chapter could hold at most one copy of any
grid (the library UI enforced that). Unlimited copies of a Basic spell breaks that
assumption outright: casting a second copy is now legitimate. The check
(`_verifyPeerSpellCast` in `turn_loop.dart`) was moved to run **after** proof
verification so it can key `isBasicGridAndT` off verified `outputs.commitmentHex`/
`outputs.t` rather than the untrusted wire value, and skips the forfeit only for a
Basic match — a non-Basic spell still forfeits on a second cast of the same grid,
unchanged. See `test/battle/engine/basic_spell_duplicate_chapter_test.dart` for both
the positive (Basic, exempt) and negative (non-Basic, still forfeits) cases.

---

## 5. Phase C — loan-permission exchange

**New setup exchange** (`spellPermissions` 0x19), run **after** Phase A (so each
side knows the authenticated K_peer), before the turn loop:

`Future<List<SpellPermission>> exchangeSpellPermissions(List<SpellPermission> ours)`
on `BattleSession` — send `jsonEncode([...ours.map((p) => p.toJson())])`, receive
and decode the peer's list.

**What each side sends:** grants where *they* are the grantee, for commitments in
their own chapter — i.e. `SpellPermission.loadAll()` filtered to
`granteePubkeyHex == myOwnerPubkeyHex && commitmentHex ∈ myChapterCommitments`.
(Sending only book-relevant grants keeps the payload small; sending all
grantee-grants is also acceptable.)

**Verify every received permission before trusting it:**
- `await perm.isCurrentlyUsable()` — signature valid (owner raw key hashes to
  `ownerPubkeyHex` AND Ed25519 signature over the canonical grant message) **and**
  not expired. `SpellPermission` already does all of this (`:200-219`).
- `_hexEq(perm.granteePubkeyHex, peerOwnerPubkeyHex)` — the grant names the
  **authenticated** peer as grantee. This is essential: it stops a peer presenting
  someone else's grant.
- Drop any permission failing either check (don't forfeit — a stale/foreign grant
  in the bundle is not itself an attack; the spell it covers simply won't
  authorize in Phase B).

Pass the verified list into `TurnLoop` as `peerPermissions`. `castingPlayerMayUse`
re-checks `isCurrentlyUsable()` per cast (`spell_authorization.dart:75`), so a loan
that lapses mid-match stops working without extra plumbing.

---

## 6. Phase D — per-turn signed state hash

Implement the reserved `exchangeStateHash` signature (BATTLE_PROTOCOL.md §6). The
crypto lives in `TurnLoop` (it already owns lockstep verification); `exchangeStateHash`
keeps just ferrying bytes.

Where `TurnLoop` currently sends `ourHash` and compares the peer's:

```dart
TAG_STATE = utf8("RUNEWRIGHT_BATTLE_STATE_V1\x00")   // distinct from TAG_AUTH
final signed = (signMessage == null)
    ? ourHash                                        // solo/test: unsigned, 32 bytes
    : Uint8List.fromList([...ourHash,
        ...await signMessage(TAG_STATE ‖ matchId ‖ be(state.turnNumber) ‖ ourHash)]);
final peerBytes = await session.exchangeStateHash(signed);

// Verify (real session only):
if (peerRawPubkey != null) {
  if (peerBytes.length < 32 + 64) { forfeit('missing_state_signature'); throw ... }
  final peerHash = peerBytes.sublist(0, 32);
  final peerSig  = peerBytes.sublist(32, 96);
  final sigOk = await Identity.verify(
      message: TAG_STATE ‖ matchId ‖ be(state.turnNumber) ‖ peerHash,
      signatureBytes: peerSig, publicKeyBytes: peerRawPubkey);
  if (!sigOk) { forfeit('bad_state_signature'); throw ... }
  // then the existing hash-equality lockstep check on peerHash
} else {
  // solo/test: existing behaviour on the raw 32-byte hash
}
```

- The wire payload grows 32 → 96 bytes → **protocol-incompatible** (see §8).
- `signMessage` is `Identity.sign` bound to the local identity, injected into
  `TurnLoop` (nullable, gated like `verifyProof`). `peerRawPubkey` likewise.
- Keep the existing hash-mismatch → forfeit behaviour; signature verification is
  an *additional* gate, not a replacement.

---

## 7. Interface / DI changes

- **`battle_wire.dart`**: add `authChallenge(0x17)`, `authResponse(0x18)`,
  `spellPermissions(0x19)` to `BattleMsgType`.
- **`BattleSession`** (concrete): add `exchangeIdentityAuth(...)` (§3) and
  `exchangeSpellPermissions(...)` (§5). Add the `AuthenticatedPeer` value class.
- **`BattleTurnSession`** (abstract, `battle_session.dart:34`): add both methods to
  the interface so setup can call them uniformly; `SoloBattleSession` implements
  them as no-ops — `exchangeIdentityAuth` returns a sentinel `AuthenticatedPeer`
  with a null/zero pubkey (setup treats solo as "no authenticated peer"),
  `exchangeSpellPermissions` returns `[]`.
- **`TurnLoop`** ctor (`turn_loop.dart:397`): add nullable
  `Uint8List? peerRawPubkey`, `String? peerOwnerPubkeyHex`,
  `List<SpellPermission>? peerPermissions`,
  `Future<List<int>> Function(List<int> message)? signMessage`. All gated exactly
  like `verifyProof`/`vkBytes` (null ⇒ solo/test path, checks skipped).
- **Setup code** (the future LAN flow / wherever `BattleSession` + `TurnLoop` are
  wired — §0a): sequence `exchangeIdentityAuth` → `exchangeSpellPermissions` →
  construct `TurnLoop` with the results + `Identity.sign`, and build the peer
  avatar from `peerOwnerPubkeyHex`.

---

## 8. Protocol versioning

New handshake steps + the 32→96-byte state-hash payload make this
**battle-protocol-incompatible** with older clients. It is **not** a
circuit/`RULESET_VERSION`/VK change (no CA rule changes; the circuit is untouched —
CLAUDE.md invariant 5 is *satisfied*, not altered). Nothing has shipped, so this is
cheap. Add a `battleProtocolVersion` int to `DeviceCapabilities`
(`match_discovery.dart`), exchanged in the existing `exchangeCapabilities` step, and
abort the session on mismatch — same discipline as `RULESET_VERSION` bumps.

---

## 9. Out of scope (do not build)

- **Encrypted / confidential channel** (X25519 AKE). The residual relay-MITM in §2
  is acceptable for in-person LAN; note it, don't build it.
- **The LAN → `BattleScreen` setup flow** (§0a). Separate task; it must *call* this
  auth but this task does not build it.
- **`refreshEntropy` reveal signing** (B-3/B-7 hardening, BATTLE_PROTOCOL.md §3b) —
  related but separate; leave its existing TODO.
- Mesh/relay signed-forwarding (MESH_ARCHITECTURE §signed relay) — separate.

---

## 10. Testing

Verification hierarchy (CLAUDE.md): unit → paired-session integration → (device
later, once a LAN flow exists). All of the below run headless now.

1. **Challenge-response unit** (`test/battle/networking/auth_handshake_test.dart`):
   valid signature accepted → correct `peerOwnerPubkeyHex`; wrong key rejected;
   signature over a *different* nonce rejected (replay); tampered `peerRawPubkey`
   (hashes to a different `owner_pubkey`) rejected; self/reflection
   (`peerOwnerPubkeyHex == mine`) rejected.
2. **Cast authorization unit** (extend the `_verifyPeerSpellCast` tests): own-spell
   (`owner == K_peer`) accepted; foreign owner with no grant → `sendForfeit` +
   throw; loaned spell with a valid grant accepted; expired grant → forfeit; grant
   whose `granteePubkeyHex != K_peer` ignored (→ forfeit). Use real
   `SpellPermission.createAndSign` fixtures.
3. **Permission-exchange unit**: valid grants survive `isCurrentlyUsable` +
   grantee-match filter; forged/expired/foreign-grantee grants are dropped.
4. **State-hash signing unit**: valid signature + matching hash accepted; forged
   signature → forfeit; absent signature (short payload) → forfeit; hash mismatch →
   forfeit (existing behaviour preserved); solo (null `signMessage`) still exchanges
   the raw 32-byte hash.
5. **Paired-session integration** (`in_memory_transport`, cf.
   `test/trade/trade_session_test.dart`, `test/protocol/match_session_suite.dart`):
   two `BattleSession`s complete the full handshake (auth + permissions) and run ≥2
   turns with signed state hashes; assert both authenticate to each other's real
   `owner_pubkey`, a foreign-owner cast forfeits, and a valid loaned cast is
   accepted.
6. **Solo regression**: `SoloBattleSession` path unchanged — no-op auth, empty
   permissions, unsigned state hash, cast authorization skipped. Run the existing
   `turn_loop_determinism_test` and solo session tests green.

Run the full suite before commit.

---

## 11. File checklist

| File | Change |
|---|---|
| `lib/battle/networking/battle_wire.dart` | Add `authChallenge`/`authResponse`/`spellPermissions` msg types (§7). |
| `lib/battle/networking/battle_session.dart` | Add `exchangeIdentityAuth` + `exchangeSpellPermissions` + `AuthenticatedPeer`; add both to `BattleTurnSession` interface (§3,§5,§7). |
| `lib/battle/networking/solo_battle_session.dart` | No-op implementations of the two new interface methods (§7). |
| `lib/battle/engine/turn_loop.dart` | New ctor params (`peerRawPubkey`, `peerOwnerPubkeyHex`, `peerPermissions`, `signMessage`); cast authorization in `_verifyPeerSpellCast` (§4); signed state-hash in the `exchangeStateHash` call site (§6). |
| `lib/battle/networking/match_discovery.dart` | Add `battleProtocolVersion` to `DeviceCapabilities`; abort on mismatch (§8). |
| Battle setup site (future LAN flow) | Call auth + permission exchanges; build peer avatar from `peerOwnerPubkeyHex` (§0a, §4). Note in `docs/M4_findings.md`. |
| `docs/BATTLE_PROTOCOL.md` | Document the auth handshake steps, `spellPermissions`, and the now-implemented §6 signature; retire the two TODOs. |
| `test/battle/networking/…`, `test/battle/engine/…` | New + extended tests (§10). |

## 12. Invariants & discipline (CLAUDE.md)

- **This is CLAUDE.md invariant 5 done right** — all signatures off-circuit
  Ed25519; the circuit is untouched; no `owner_pubkey`/commitment folding; no
  `RULESET_VERSION` bump (no CA rule change).
- **Fail closed, always.** Any auth/verify/signature failure → `sendForfeit` +
  throw, never a silent accept. A check that fails open is worse than no check
  (the quality bar). Pair each new check with the negative test that fails without
  it (§10) — the §10.1/§10.2 rejects are that pairing.
- **Distinct domain-separation tags** for auth vs state-hash signatures; include
  `matchId` in both so a signature can't cross sessions.
- Constant-time compare for any secret/hash equality (`_constantTimeEqual` exists,
  `battle_session.dart:208`); use the crypto library for signatures.
- Small, focused commits; keep the change order contract → oracle → wiring → tests.
  Land Phase A+B first (the core), then C, then D — each independently testable.
