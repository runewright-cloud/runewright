# LAN Battle Wire-Up — Implementation Plan

## Implementation status (2026-07-19)

**Stage 1 built** — see `docs/M4_findings.md`'s "LAN duel setup Stage 1
implemented" entry for the full account, including two real bugs found and
fixed along the way (a `BattleFrameReader` frame-drop race that can hit real
two-device play, not just tests; and a test-only harness race). Highlights:

- Commit-sequence steps 1–3 (§8 below) are done: `buildDuelBattleState`,
  `runDuelSetup`, and the lobby/`BattleScreen` wiring all exist and pass
  `test/battle/networking/duel_setup_test.dart` plus the full existing suite
  (479 tests, no regressions).
- **Two implementation details worth recording** (found while building, not
  anticipated in this doc's original prose — see §3.2/§7 below for where
  they now live): `BattleSession` must be constructed with a *placeholder*
  matchId before the real one is known (matchId is `final`, but the real
  value depends on an exchange that needs the session's own persistent
  reader to run safely — see `duel_setup.dart`'s header comment); and
  DECISION 3's "guest adopts what the host sends" needed a genuinely
  asymmetric wire exchange (`sendHostMatchConfig`/`receiveHostMatchConfig`),
  not a literal reuse of `exchangeMatchConfig`'s strict-equality check, which
  can't express one side unilaterally dictating a value in a single round
  trip.
- **Step 4 (commit sequence §8) is NOT done** — no two-device LAN run has
  happened (no second physical device in this environment). This is the
  actual gate per CLAUDE.md's verification hierarchy; headless tests are
  necessary but explicitly not sufficient (see §6 Risks below, unchanged).
- File names below are the plan's *original* naming; actual files built:
  `lib/ui/duel_host_settings_screen.dart` (not a bottom sheet — a full
  screen, host-only), `lib/ui/duel_join_chapter_screen.dart` (guest's
  chapter-only step), `lib/ui/widgets/chapter_picker.dart` +
  `int_stepper_row.dart` (the "shared widgets" §3.3 asked for).
- **2026-07-20: a real bug report from the user's own two-device attempt**
  (Pixel 6 hosting worked; Linux desktop joining "crashed back to the battle
  menu") surfaced that `nsd` has no Linux desktop backend at all — confirmed
  live, not guessed. Fixed with a manual IP fallback in
  `battle_lobby_screen.dart` (permanent host:port field on join, "Listening
  on ip:port" display on host) reusing `gate_screen.dart`'s already-proven
  pattern, plus made `LanMatchDiscovery.startAdvertising`/`_startJoining`
  treat mDNS failure as best-effort rather than fatal. Also fixed a real,
  previously-latent `BattleFrameReader` frame-drop race (buffered
  broadcast stream dropped events arriving before a `.first` listener
  subscribed — reachable on real two-device play, not just tests). See
  `docs/M4_findings.md`'s two matching entries for full detail.

## Stage 2 implementation status (2026-07-20)

**Built** — all of §4's items, plus tests:

1. `localChapterCommitments` — wired in `battle_screen.dart`'s
   `_maybeSetLocalChapterCommitments()`, called from both `_loadSpells()`
   and `_initTurnLoop()` (whichever finishes second sets the real value;
   safe regardless of ordering since neither is user-reachable before both
   are ready — see `_loopReady`/the build() gate below).
2. `verifyProof` + `vkBytes` + `peerBookRoot` — `BattleScreen._initTurnLoop()`
   (new) loads the agreed tier's bundled VK asset + circuit JSON, extracts
   bytecode, and calls `initSrsCached` (CLAUDE.md Bug-Avoidance #4) before
   constructing `TurnLoop`. **This made `_loop`'s construction asynchronous**
   for a real duel (immediate for solo/test, unchanged) — `BattleScreen`
   now has a `_loopReady` gate: `build()` shows a loading spinner until
   `_loop` exists, and a **blocking, fail-closed error screen** (never a
   silent trust downgrade) if VK/SRS/identity init throws — CLAUDE.md
   quality bar: "a check that fails open is worse than no check."
3. Cast authorization — `peerOwnerPubkeyHex`/`peerPermissions` threaded from
   `DuelSetupResult` through `battle_lobby_screen.dart` into `BattleScreen`
   into `TurnLoop`. Also wired the **outgoing** half in `duel_setup.dart`
   (was a TODO): each side now sends its own grants naming the peer,
   restricted to commitments in its own chapter, so a loaned spell can
   actually be cast and authorized in a real duel, not just received.
4. **Phase D signed state hash** — built (not left optional). Added
   `signMessage`/`peerRawPubkey` ctor params to `TurnLoop` (the one
   ctor change §4 anticipated), a new `kStateHashSignatureTag` constant
   (referenced but never defined before — `battle_session.dart`'s doc
   comment mentioned it, this closes that gap), and rewrote
   `_exchangeStateHash` to sign when `signMessage` is set and verify +
   forfeit when `peerRawPubkey` is set, preserving the exact unsigned
   32-byte path for solo/test. `BattleScreen` reloads the local `Identity`
   (cheap, no network) to bind `signMessage`; `peerRawPubkey` comes from
   `DuelSetupResult.peer.rawPubkey` (already existed, just wasn't
   threaded through).
5. Sightings — unchanged, already gated correctly; will start firing the
   moment a real duel plays a turn.
6. Tests — four new files, all real (no mocked crypto):
   - `test/battle/engine/turn_loop_proof_verification_test.dart` — a REAL
     FFI-proven spell (via `inscribeSpell`, tier-12, all-neutral "whiff"
     grid) verified end-to-end through two real `TurnLoop`s over paired
     `BattleSession`s. The actual "real-device proof round trip" §4 asked
     for. ~20s (one real proof); occasionally hits the same SRS-download
     network flakiness `inscribe_test.dart`/`gate_runner_test.dart` already
     have — environmental, not a code issue (passes reliably in isolation).
   - `test/battle/engine/turn_loop_cast_authorization_test.dart` —
     integration-level (not duplicating `spell_authorization_test.dart`'s
     already-thorough pure-`castingPlayerMayUse` unit tests): forged-owner
     cast with no grant → forfeit; same cast backed by a valid unexpired
     loan → authorized; same cast backed by an *expired* loan → forfeit.
     Uses synthetic (not real-FFI) proofs since authorization sits after
     verification and doesn't need real crypto — fast.
   - `test/battle/engine/turn_loop_phase_d_test.dart` — valid signed state
     hash round-trips cleanly; a tampered signature (one bit flipped in the
     signature portion only, hash untouched) forfeits + throws.
   - `test/battle/networking/match_discovery_resilience_test.dart` — the
     manual-IP-fallback fix above.

**Real bug found while writing the negative cast-authorization tests, worth
recording:** two of the three tests initially passed for the *wrong*
reason — `throwsA(isA<StateError>())` is satisfied by ANY `StateError`,
and the caster's `TurnLoop` never had `localChapterCommitments` set, so no
proof bytes were attached to the wire at all; the verifier was actually
forfeiting on `missing_spell_proof`, not on the authorization check under
test. Caught because the *third* (success-path) test hung — `Future.wait`
on two loops where one is expected to complete normally doesn't tolerate
either side silently forfeiting for an unrelated reason (the "healthy"
side then waits forever for an exchange the forfeited side never sends).
Fixed by setting `localChapterCommitments` in the shared test fixture and
tightening the rejection assertions to check the actual forfeit reason
substring, not just "some StateError." General lesson for future tests in
this area: **a bare `throwsA(isA<StateError>())` is too weak** when
multiple failure modes exist — check the message.

**Also confirms a general protocol property worth remembering:** when one
side's `TurnLoop.runTurn()` forfeits and throws mid-turn, the OTHER side's
`runTurn()` call will hang forever waiting for exchanges (melee/free-move/
state-hash) the aborted side never reaches. `Future.wait([both sides])` is
only safe to await directly when neither side is expected to throw; a test
expecting one side to reject must start the other side's call unawaited
with errors swallowed (see `expectVerifierRejects` in the cast-
authorization test file for the pattern).

---

*Written 2026-07-19 for implementation by Sonnet. Closes the one missing seam
between a connected LAN `Transport` and a playable network duel. This is the
"LAN → `BattleScreen` setup flow" that `BATTLE_AUTH_PLAN.md §0a` and
`SIGHTINGS_PLAN.md §0a` both defer to a separate task — this is that task.*

> **Read first:** `CLAUDE.md` (invariants + handoff notes), `BATTLE_AUTH_PLAN.md`
> (the auth handshake this flow must call), `docs/BATTLE_PROTOCOL.md` §0–§2/§6.
> Change order stays **contract → oracle → wiring → tests**. Nothing here touches
> the circuit, the CA rules, or `RULESET_VERSION` (CLAUDE.md invariant 5 is
> satisfied, not altered).

---

## 0. Current state (verified 2026-07-19)

What already exists and works — **do not rebuild any of this**:

| Piece | Location | Status |
|---|---|---|
| Full network protocol session | `lib/battle/networking/battle_session.dart` (`BattleSession`) | ✅ implemented — every exchange method incl. identity auth (A), permissions (C) |
| Solo stub session | `solo_battle_session.dart` (`SoloBattleSession`) | ✅ implemented |
| Turn engine | `lib/battle/engine/turn_loop.dart` (`TurnLoop`) | ✅ ctor already takes `matchId`, `verifyProof`, `vkBytes`, `peerBookRoot`, `peerOwnerPubkeyHex`, `peerPermissions`, `tier`, `isSorcererMode`; mutable `localChapterCommitments` |
| Battle HUD screen | `lib/ui/battle_screen.dart` (`BattleScreen`) | ✅ already accepts injected `BattleTurnSession session` |
| Solo state builder | `lib/battle/models/solo_battle_setup.dart` (`buildSoloBattleState`) | ✅ two-avatar state, but **local-always-at-bottom, sentinel pubkeys** — not symmetric for two devices |
| LAN discovery + transport | `match_discovery.dart`, `lan_socket_transport.dart`, `lan_discovery.dart` | ✅ host/join reach a live `Transport` |
| Lobby | `lib/ui/battle_lobby_screen.dart` | ⚠️ **dead-ends at `_LobbyMode.connected`** ("Ready to duel." static screen). No `BattleSession`, no handshake, no navigation into `BattleScreen`. |

**The entire missing surface is:** (1) a shared setup routine that, from a
connected `Transport` + host/guest role, runs the handshake and builds an
**identical `BattleState` on both devices**, then (2) lobby wiring that calls it
and pushes `BattleScreen` with the real `BattleSession`.

**Known adjacent gap (NOT this task's blocker):** `BATTLE_AUTH_PLAN.md` Phase D
(per-turn *signed* state hash) is **not** implemented — `TurnLoop` has no
`signMessage`/`peerRawPubkey` ctor params and `BattleSession.exchangeStateHash`
still carries its `TODO`. The unsigned 32-byte state-hash lockstep still works.
Phase D is folded into Stage 2 below as optional hardening; Stage 1 does not need
it.

---

## 1. Target flow

```
Menu → Battle → BattleLobbyScreen
   HOST A DUEL ─┐                         ┌─ JOIN A DUEL → pick peer
                ├─ Transport established ──┤
   (settings)   │  (already works today)  │  (settings received from host)
                ▼                          ▼
         runDuelSetup(transport, role, localIdentity, chapter, config)
                │
                ├─ new BattleSession(transport, matchId)
                ├─ exchangeCapabilities          (protocol-version gate, §8 auth plan)
                ├─ agree matchId                 (DECISION 1)
                ├─ exchangeMatchConfig           (host authors; guest adopts — DECISION 3)
                ├─ exchangeIdentityAuth          (BATTLE_AUTH_PLAN §3 — already built)
                ├─ exchangeSpellPermissions      (BATTLE_AUTH_PLAN §5 — already built)
                ├─ exchangeBookCommitment/Hash   (already built; feeds peerBookRoot)
                └─ buildDuelBattleState(...)     (NEW — symmetric, pubkey-ordered)
                        │
                        ▼
        Navigator.push → BattleScreen(state, localPlayerId, chapter,
                                      session: battleSession)
```

The existing `TurnLoop` inside `BattleScreen` then drives every turn over the
real session — no `BattleScreen`/`TurnLoop` logic changes required for Stage 1.

---

## 2. Design decisions (SETTLED — Soren, 2026-07-19)

All four forks are resolved. Build exactly these; do not re-litigate without new
evidence (CLAUDE.md working discipline).

**DECISION 1 — shared `matchId`: symmetric nonce-combine.** `matchId` must be
(a) identical on both devices and (b) agreed *before* `exchangeIdentityAuth`
(auth signs `TAG ‖ matchId ‖ nonce`). There is no proof-exchange handshake on the
LAN path to inherit one from (BATTLE_PROTOCOL §0 assumes one; the LAN lobby uses
`Transport` directly). A dedicated pre-auth exchange: each side sends a fresh
16-byte random nonce; `matchId = SHA-256(sortedConcat(nonceA, nonceB))` truncated
to 16 bytes. Symmetric, per-match unique, neither side controls it. Add one wire
type `matchIdNonce` in the free setup range (0x1A). Sort the two nonces by byte
value before concatenating so both devices compute the same hash regardless of
arrival order.

**DECISION 2 — role / spawn assignment: pubkey-sorted.** The two devices must
produce byte-identical `BattleState` (avatar list order, spawn tiles, player IDs,
team IDs) or the state-hash lockstep diverges on turn 1. Derive roles from the
**authenticated** `ownerPubkeyHex` pair (available after `exchangeIdentityAuth`):
sort the two hexes; lower hex → `spawns[0]` (bottom vertex), higher → `spawns[1]`
(top). Use the two hex strings themselves as the stable `playerId`s, and set each
`WizardAvatar.ownerPubkeyHex` from the authenticated value (this *is* the
avatar-binding step `BATTLE_AUTH_PLAN §4` requires). `localPlayerId` = the local
identity's own `ownerPubkeyHex`. No host/guest branch in state construction —
both devices run the identical sort. This replaces `solo_battle_setup.dart`'s
"local always bottom / sentinel pubkey" convention (fine for solo, wrong for two
devices). *Define the hex sort explicitly (e.g. compare as lowercase, `0x`-
stripped, fixed-width strings) so both devices order identically.*

**DECISION 3 — match settings: host authors, guest adopts.**
`MatchConfig.matches()` is strict equality + abort on mismatch
(`battle_session.dart:282`). Each player still brings their **own** chapter
(chapter is not part of `MatchConfig`; the agreed fields are
hp/radius/tier/sorcerer/etc.). Host authors the `MatchConfig` in a settings step
(reuse the steppers from `solo_practice_settings_screen.dart`); after connect,
host sends it and **guest adopts it verbatim** (shown read-only), so
`exchangeMatchConfig` is a trivial confirm the guest can never mismatch on. Each
device selects its own chapter locally on both host and join paths (new small
chapter-picker step — the lobby has none today).

**DECISION 4 — staging: Stage 1 playable, then Stage 2 sound.** A fully sound
duel proof-verifies every peer cast (`verifyProof` + `vkBytes` + `peerBookRoot` +
membership proofs, Option 3) and cast-authorizes it (`BATTLE_AUTH_PLAN §4`) — a
heavy path (FFI verifier, VK bytes per tier, `localChapterCommitments` plumbing).
Ship in two stages (below). **Stage 1** gets a *playable* end-to-end LAN duel with
identity auth + real pubkey binding, but `verifyProof: null` (peer casts trusted,
exactly like solo). **Stage 2** turns on proof verification + cast authorization +
(optionally) Phase D signed state hash. Stage 1 is honestly labeled a
**trust-incomplete** milestone in the UI/findings doc — do not present it as
secure play.

---

## 3. Stage 1 — playable LAN duel (no proof verification)

Goal: two devices on a LAN complete a full duel through `BattleScreen`, lockstep
in sync, avatars bound to authenticated identities.

### 3.1 New file: `lib/battle/models/duel_battle_setup.dart`

Mirror `solo_battle_setup.dart`, but symmetric and identity-bound.

```dart
class DuelBattleSetup {
  const DuelBattleSetup({required this.state, required this.localPlayerId});
  final BattleState state;
  final String localPlayerId;
}

/// Builds a byte-identical two-avatar BattleState on both devices.
/// [localOwnerHex]/[peerOwnerHex] are the AUTHENTICATED owner_pubkey hexes
/// from exchangeIdentityAuth. Ordering is pubkey-sorted (DECISION 2) so both
/// devices agree on spawns/ids without a host/guest branch.
DuelBattleSetup buildDuelBattleState({
  required MatchConfig config,
  required ChapterAsset localChapter,
  required String localOwnerHex,
  required String peerOwnerHex,
});
```

Requirements:
- Player IDs = the two `ownerPubkeyHex` strings; sort them; lower → `spawns[0]`.
- Each `WizardAvatar.ownerPubkeyHex` = its authenticated hex (NOT a sentinel).
- Local avatar's accoutrements derived from **`localChapter.artifacts`** exactly
  as `buildSoloBattleState` does (reuse the `_toAccoutrementKind` logic — extract
  it to a shared helper rather than duplicating).
- **CONFIRMED (not deferrable): the peer avatar must be built from the peer's
  real artifact loadout, exchanged at handshake — in Stage 1, not Stage 2.**
  Verified against `BattleState.toCanonicalBytes()`
  (`battle_state.dart:214-229`): every avatar's full accoutrement list (id, kind,
  isCoreGem, targetCommitmentHex) is serialized into the per-turn state hash, and
  `maxMana`/`mana` (`:208-209`, also hashed) are derived directly from the
  mana-gem count (`solo_battle_setup.dart`'s `manaGems * config.manaGemPoolPerGem`).
  A placeholder single-core-gem peer loadout diverges from the peer's actual
  chapter on the **very first** state-hash exchange — this is a guaranteed
  lockstep failure, not a theoretical one. Fix is cheap: `ArtifactEntry` already
  has `toJson()`/`fromJson()` (`chapter_asset.dart:36-44`), and an artifact
  loadout (mana gems/bookmarks/rods/charms — equipment) is public, unlike the
  chapter's *spells*, which stay protected by the Merkle-commitment scheme
  (`exchangeBookCommitment`/`exchangeBookHash`). Add one handshake step —
  `exchangeArtifactLoadout` on `BattleSession` (new wire type
  `artifactLoadout` 0x1B, free setup range) — sending
  `jsonEncode(localChapter.artifacts.map((a) => a.toJson()).toList())`
  immediately alongside book commitment (§3.2 step 7). Both devices then call
  the *same* accoutrement-derivation helper on the peer's received artifact list
  that they call on their own local chapter's — no divergent code paths.
- `localPlayerId` = `localOwnerHex`.

### 3.2 New file: `lib/battle/networking/duel_setup.dart`

The handshake orchestrator. Pure of Flutter (unit-testable with paired
`in_memory_transport`, cf. `test/battle/networking/auth_handshake_test.dart`).

```dart
enum DuelRole { host, guest }

class DuelSetupResult {
  final BattleSession session;
  final BattleState state;
  final String localPlayerId;
  final ChapterAsset localChapter;
  // Stage 2 carries: peerBookRoot, peerPermissions, tier, matchId, etc.
}

Future<DuelSetupResult> runDuelSetup({
  required Transport transport,
  required DuelRole role,
  required Identity localIdentity,
  required ChapterAsset localChapter,
  required MatchConfig hostConfig,        // authored by host; guest passes the one it received
});
```

Sequence (fail-closed on every negative — forfeit + throw, never silent accept):
1. Establish `matchId` (DECISION 1) — pre-auth nonce exchange.
2. `new BattleSession(transport, matchId)`.
3. `exchangeCapabilities(DeviceCapabilities.detect())` — abort on
   `battleProtocolVersion` mismatch once that field lands (`BATTLE_AUTH_PLAN §8`;
   add it if not present).
4. `exchangeMatchConfig` — host sends `hostConfig`; guest sends the config it
   adopted; both must `matches()`. Abort (pop to lobby with a snackbar) on `null`.
5. `exchangeIdentityAuth(localIdentity, matchId)` → `AuthenticatedPeer`. On the
   `StateError` it throws (auth failure/self), surface + return to lobby.
6. `exchangeSpellPermissions(myGrants, peerOwnerPubkeyHex: peer.ownerPubkeyHex)`
   — filter local `SpellPermission.loadAll()` to grantee==me (Stage 1 may pass
   `[]` if loaned casts aren't exercised yet; wiring the real list is cheap and
   preferred).
7. `exchangeBookCommitment` / `exchangeBookHash` — compute local root/leaf-hash
   from `localChapter` via `BookCommitment`; keep peer root for Stage 2
   (`peerBookRoot`).
8. `exchangeArtifactLoadout(localChapter.artifacts)` — **required in Stage 1**
   (see §3.1); returns the peer's `List<ArtifactEntry>`, fed into
   `buildDuelBattleState` for the peer avatar's accoutrements.
9. `buildDuelBattleState(...)` with the authenticated hexes and both artifact
   loadouts.
10. Return `DuelSetupResult`.

### 3.3 Lobby wiring: `lib/ui/battle_lobby_screen.dart`

- Add a **chapter picker** + (host only) a **match-settings** step before/at the
  hosting/joining screens. Reuse the chapter dropdown and steppers already in
  `solo_practice_settings_screen.dart` (extract to shared widgets or a small
  settings sheet — don't copy-paste the whole screen).
- On reaching `_LobbyMode.connected` with a live `_transport`, call
  `runDuelSetup(transport: _transport!, role: hosting ? host : guest, ...)`.
  Show a "Preparing duel…" state while it runs.
- On success, `Navigator.pushReplacement` into
  `BattleScreen(state: r.state, localPlayerId: r.localPlayerId,
  chapter: r.localChapter, session: r.session)`.
- On failure, snackbar + return to `_LobbyMode.idle` (and `transport.disconnect()`).
- Ownership: once handed to `BattleScreen`, the session/transport lifecycle is the
  battle's; make sure the lobby's `dispose()` no longer force-disconnects a
  transport it has handed off (guard with a "handed off" flag).

### 3.4 `TurnLoop` construction inside `BattleScreen`

No signature change needed for Stage 1. `BattleScreen.initState` already does
`session: widget.session ?? SoloBattleSession(...)`. For a network session, also
pass `matchId` through so cross-match domain separation is active. Two options:
- **Recommended:** add optional `Uint8List? matchId`, `int tier` fields to
  `BattleScreen` (defaulted null/24), forwarded to the `TurnLoop` ctor. Solo
  callers pass nothing (unchanged).
- Keep `verifyProof`/`peerOwnerPubkeyHex` null in Stage 1 (peer casts trusted).

### 3.5 Stage 1 tests
- **Paired-session integration** (`test/battle/networking/duel_setup_test.dart`,
  `in_memory_transport`): two `runDuelSetup` calls (host+guest) over a paired
  transport produce **identical `BattleState`** (same avatar order, spawns, ids,
  bound pubkeys) and each `localPlayerId` is its own hex. Assert `matchId` equal.
- **Determinism:** drive ≥2 full turns through two `TurnLoop`s over the paired
  sessions (cf. `turn_loop_determinism_test.dart`) and assert state hashes stay
  equal each turn.
- **Solo regression:** `SoloBattleSession` path + existing solo tests unchanged.
- Verification hierarchy (CLAUDE.md): this is device-facing — a **two-device LAN
  run** is required before calling Stage 1 done (`flutter run` on two devices, or
  one device + `-d linux` desktop as the second, both on the same network).

---

## 4. Stage 2 — sound duel (proof verification + authorization + Phase D)

Turn the trust guarantees on. Each item is independently testable.

1. **`localChapterCommitments`** — after `BattleScreen._loadSpells()` resolves,
   set `_loop.localChapterCommitments = <sorted commitmentHex>` so outgoing casts
   carry Merkle membership proofs. (Field already exists on `TurnLoop`.)
2. **`verifyProof` + `vkBytes` + `peerBookRoot`** — pass a real `ProofVerifier`
   (FFI) and the tier's VK bytes into `TurnLoop`. Ensure SRS/CRS init on the
   verify path (CLAUDE.md Bug-Avoidance #4: call `initSrsCached` before first
   `verify_ultra_honk`). `peerBookRoot` = hex of the root from step 7 above.
3. **Cast authorization** — pass `peerOwnerPubkeyHex` from the authenticated peer
   and `peerPermissions` from step 6; `_verifyPeerSpellCast` already enforces
   `castingPlayerMayUse` when these are non-null (`BATTLE_AUTH_PLAN §4`).
4. **Phase D (optional) — signed state hash.** Implement the reserved signature
   in `exchangeStateHash` (`BATTLE_AUTH_PLAN §6`): add `signMessage`/
   `peerRawPubkey` ctor params to `TurnLoop`, sign `TAG_STATE ‖ matchId ‖
   turn ‖ hash`, verify peer's. Distinct tag from auth. This is the only Stage 2
   item that changes `TurnLoop`'s public ctor.
5. **Sightings** — already implemented in `battle_screen.dart`
   (`_recordSightings`, gated on `session is! SoloBattleSession`); it will start
   recording automatically once real duels run. Verify it fires end-to-end.
6. **Tests** — extend with a forged-owner cast → forfeit, expired-grant → forfeit,
   tampered state-signature → forfeit (the §10 negative pairings from the auth
   plan), plus a real-device proof round trip.

*(Peer artifact loadout exchange is **not** a Stage 2 item — moved to Stage 1,
§3.1/§3.2 step 8, since it's required for turn-1 lockstep, not an optional
hardening pass.)*

---

## 5. File checklist

| File | Stage | Change |
|---|---|---|
| `lib/battle/models/duel_battle_setup.dart` | 1 | **New** — symmetric, pubkey-ordered `buildDuelBattleState`. |
| `lib/battle/networking/duel_setup.dart` | 1 | **New** — `runDuelSetup` handshake orchestrator + `DuelRole`/`DuelSetupResult`. |
| `lib/battle/networking/battle_wire.dart` | 1 | Add `matchIdNonce` (0x1A), `artifactLoadout` (0x1B); `battleProtocolVersion` in caps (§8 auth plan) if not already present. |
| `lib/battle/models/match_config.dart` | 1 | Possibly none (host authors, guest adopts). Confirm `matches()` covers the negotiated fields (it does). |
| `lib/ui/battle_lobby_screen.dart` | 1 | Chapter picker + host settings step; call `runDuelSetup` at `connected`; push `BattleScreen`; fix transport hand-off in `dispose()`. |
| `lib/ui/solo_practice_settings_screen.dart` | 1 | Extract chapter picker + steppers into shared widgets for lobby reuse (no behavior change). |
| `lib/ui/battle_screen.dart` | 1 | Optional `matchId`/`tier` params forwarded to `TurnLoop`. Stage 2: set `localChapterCommitments` after `_loadSpells`. |
| `lib/battle/engine/turn_loop.dart` | 2 | Phase D only: `signMessage`/`peerRawPubkey` ctor params + signed `exchangeStateHash`. |
| `test/battle/networking/duel_setup_test.dart` | 1 | **New** — identical-state + lockstep-determinism paired-session tests. |
| `docs/M4_findings.md` | 1 | Record the flow, the Stage-1 trust caveat, and the two-device run result. |
| `docs/BATTLE_PROTOCOL.md` | 1 | Document the `matchId` establishment step and the LAN setup sequence. |

---

## 6. Risks / things that will bite (institutional memory)

- **State must be byte-identical across devices or lockstep diverges on turn 1.**
  Everything hashed into `BattleState`'s state hash must be constructed the same
  way on both devices: avatar list order, spawn tiles, player/team IDs, *and*
  anything derived from artifact loadouts. This is why DECISION 2 sorts by
  authenticated pubkey (no host/guest asymmetry) and why the peer's artifact
  loadout **must** be exchanged in Stage 1 (§3.1) — **confirmed**, not
  hypothetical: `BattleState.toCanonicalBytes()` (`battle_state.dart:214-229`)
  hashes each avatar's full accoutrement list, and `maxMana`/`mana`
  (`:208-209`) are derived from the mana-gem count. A stubbed peer loadout
  diverges on the first state-hash exchange, full stop. If any *other* future
  per-avatar field is added to `WizardAvatar`, re-check whether
  `toCanonicalBytes` picked it up and whether both devices can construct it
  identically before assuming any "build it locally" shortcut is safe.
- **`matchId` must be agreed before auth** (it's signed). Don't reorder the
  handshake so auth runs first.
- **Generation/off-by-one & ordering traps** from CLAUDE.md handoff notes still
  apply to anything touching the engine — but Stage 1 shouldn't touch engine
  internals at all. If you find yourself editing `turn_loop.dart` in Stage 1,
  stop: the seam is already there.
- **Transport ownership.** The lobby currently disconnects the transport in
  `dispose()`. After hand-off to `BattleScreen`, that would kill a live match.
  Guard it.
- **Verification hierarchy.** Headless paired-session tests are necessary but not
  sufficient — a two-device LAN pass is the gate for "done" (CLAUDE.md: M4.6's
  two-device gate found a real bug no automated test caught).

---

## 7. Out of scope (do not build)

- Encrypted/confidential channel (X25519 AKE) — `BATTLE_AUTH_PLAN §9` residual;
  acceptable for in-person LAN.
- 3–6 player / mesh (`MESH_ARCHITECTURE.md`, `SORCERER_REALTIME_PLAN.md`) — this
  is 2-player only; `MatchConfig.experimentalMultiplayer` stays false.
- New CA rules / circuit / `RULESET_VERSION` changes — none needed.
- Conflict-resolution UI for `MatchConfig` mismatch — abort-to-lobby is fine.
- Reworking the solo path — it stays exactly as is on `SoloBattleSession`.

---

## 8. Suggested commit sequence

1. Extract shared chapter-picker/stepper widgets (no behavior change).
2. `buildDuelBattleState` + its identical-state unit test.
3. `runDuelSetup` handshake + paired-session integration test (state identical,
   lockstep holds ≥2 turns). ← **Stage 1 is playable in headless tests here.**
4. Lobby wiring + `BattleScreen` `matchId`/`tier` forwarding; two-device LAN run;
   findings-doc note. ← **Stage 1 done** (2026-07-19 code; 2026-07-20 real
   two-device attempt surfaced + fixed the `nsd`-on-Linux gap, see above).
5. Stage 2 items 1–3 (proof verify + authorization), each with its negative
   test. ← **Done** (2026-07-20).
6. Stage 2 Phase D signed state hash, with its negative tests. ← **Done**
   (2026-07-20) — built, not left optional; see "Stage 2 implementation
   status" above.

**Remaining before this is fully closed out:** a real two-device LAN run of
a duel that actually reaches proof verification (Stage 1's two-device pass
only exercised the trust-incomplete path). No second physical device in
this environment — same gate as Stage 1, unchanged.
