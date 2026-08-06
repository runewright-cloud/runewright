// SPDX-License-Identifier: GPL-3.0-or-later
//
// duel_setup.dart — runDuelSetup: the LAN → BattleScreen setup flow
// (LAN_BATTLE_WIREUP_PLAN.md §3.2). This is the one missing seam between a
// connected LAN Transport (battle_lobby_screen.dart already gets this far)
// and a playable network duel — everything downstream (BattleSession,
// TurnLoop, BattleScreen) already exists and works.
//
// Stage 2 (LAN_BATTLE_WIREUP_PLAN.md §4): this handshake resolves everything
// the "sound duel" trust chain needs — peerBookRootHex, the peer's
// authenticated ownerPubkeyHex, and verified peerPermissions are all
// returned in DuelSetupResult for BattleScreen to wire into TurnLoop
// (verifyProof/vkBytes/peerBookRoot/peerOwnerPubkeyHex/peerPermissions).
// This file itself does no proof verification — that's BattleScreen's job
// (loading the VK asset + initializing the SRS/CRS is Flutter-asset-bundle
// work, out of place in a Flutter-free handshake orchestrator).
//
// Sequence (fail-closed on every negative — forfeit + throw, never silent
// accept, mirroring BattleSession.exchangeIdentityAuth's own discipline):
//   1. Agree matchId (DECISION 1) — neither side unilaterally controls it.
//   2. Exchange + check capabilities (protocol-version gate).
//   3. Match config — host authoritative (DECISION 3).
//   4. Identity auth (BATTLE_AUTH_PLAN §3 — already built).
//   5. Spell-permission exchange (BATTLE_AUTH_PLAN §5) — both our grants
//      naming the peer (restricted to spells in our own chapter) and the
//      peer's grants naming us are exchanged and verified.
//   6. Book commitment/hash (feeds peerBookRoot for membership-proof checks).
//   7. Artifact-loadout exchange (required — see duel_battle_setup.dart's
//      doc comment on why this can't be deferred).
//   8. buildDuelBattleState — symmetric, pubkey-ordered (DECISION 2).
//
// Construction note (found while implementing, not in the original plan
// prose — worth keeping here since it's a real correctness constraint):
// BattleSession.matchId is `final`, so it must be supplied at construction —
// but the real matchId isn't known until step 1 runs, and step 1 needs a
// persistent frame-reader subscription to run safely. Real Transports (e.g.
// LanSocketTransport, backed directly by a dart:io Socket) are
// single-subscription streams — listening, cancelling, and re-listening to
// `transport.onReceive` a second time throws. So this constructs ONE
// BattleSession up front with a placeholder matchId (inert plumbing; nothing
// internal to BattleSession reads `this.matchId`), runs the nonce exchange
// through that session's own persistent reader, and threads the *real*
// computed matchId through explicitly to every call that needs it
// (`exchangeIdentityAuth`'s `matchId` parameter, and `TurnLoop`'s ctor) —
// never relying on `session.matchId` itself.

import 'dart:math' show Random;
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;

import '../../identity/identity.dart';
import '../../protocol/transport.dart';
import '../../spells/chapter_asset.dart' show ChapterAsset;
import '../../spells/spell_asset.dart' show SpellAsset;
import '../../spells/spell_identity.dart'
    show SpellKinEntry, kinStackingLeaves, newKinRevealSalt;
import '../../spells/spell_permission.dart' show SpellPermission;
import '../engine/book_commitment.dart';
import '../models/battle_state.dart';
import '../models/duel_battle_setup.dart';
import '../models/match_config.dart';
import 'battle_session.dart';
import 'match_discovery.dart';

enum DuelRole { host, guest }

/// Everything the lobby needs to hand off into [BattleScreen] plus the
/// values Stage 2 (proof verification, cast authorization) will need once
/// it's wired in — see LAN_BATTLE_WIREUP_PLAN.md §4.
class DuelSetupResult {
  const DuelSetupResult({
    required this.session,
    required this.state,
    required this.localPlayerId,
    required this.localChapter,
    required this.matchId,
    required this.effectiveConfig,
    required this.peer,
    required this.peerBookRootHex,
    required this.peerBookLeafCount,
    required this.localKinLeaves,
    required this.peerBookHash,
    required this.peerPermissions,
    required this.localAvatarId,
    required this.peerAvatarId,
  });

  final BattleSession session;
  final BattleState state;
  final String localPlayerId;
  final ChapterAsset localChapter;

  /// The real, jointly-derived matchId (DECISION 1) — NOT `session.matchId`
  /// (a placeholder; see this file's header comment). Thread this into
  /// `TurnLoop(matchId: ...)` for cross-match domain separation.
  final Uint8List matchId;

  /// The agreed [MatchConfig] — host-authored, guest-adopted (DECISION 3).
  final MatchConfig effectiveConfig;

  /// The authenticated peer identity (BATTLE_AUTH_PLAN §3).
  final AuthenticatedPeer peer;

  /// The peer's Chapter Merkle root (hex), for Stage 2's membership-proof
  /// verification. Unused until `verifyProof`/`vkBytes` are wired into
  /// `TurnLoop` (plan §4).
  final String? peerBookRootHex;

  /// The peer's chapter leaf count, declared publicly alongside
  /// [peerBookRootHex] (SPELL_DRAW_WIRING_PLAN.md §3) — lets DrawSchedule
  /// compute `nextInt(leafCount)` for the peer's chapter without ever
  /// learning its contents.
  final int peerBookLeafCount;

  /// Verified loan/transfer grants naming the *peer* as grantee
  /// (BATTLE_AUTH_PLAN §5) — feed into `TurnLoop.peerPermissions` so a
  /// loaned spell the peer casts (but doesn't own) can be authorized.
  final List<SpellPermission> peerPermissions;

  /// This device's chosen [AvatarArt.id] (docs/AVATAR_PICKER_PLAN.md §5.2),
  /// or '' if none has been chosen. Presentation only.
  final String localAvatarId;

  /// The peer's chosen avatar id, exchanged the same way as
  /// [localAvatarId]. Presentation only — an unrecognised id degrades to the
  /// default via `avatarArtById` returning null.
  final String peerAvatarId;

  /// This device's sorted kin-stacking leaves — salted behavioural-kinship
  /// hashes of the local chapter (COUNTER_CHARM_KINSHIP_PLAN.md §3.5). Held
  /// so the post-match [BattleSession.exchangeBookReveal] can send exactly
  /// what [localKinLeaves]' hash was committed to at setup. The salt itself
  /// is discarded — nothing ever needs it again.
  final List<String> localKinLeaves;

  /// The peer's batch leaf hash from [BattleSession.exchangeBookHash] — the
  /// `expectedPeerHash` their post-match reveal is checked against.
  final Uint8List peerBookHash;
}

/// Runs the full LAN duel handshake over an already-connected [transport]
/// and returns everything needed to push [BattleScreen]. Throws (after
/// sending forfeit where applicable) on any handshake failure — callers
/// should catch, disconnect the transport, and return to the lobby.
Future<DuelSetupResult> runDuelSetup({
  required Transport transport,
  required DuelRole role,
  required Identity localIdentity,
  required ChapterAsset localChapter,
  required MatchConfig hostConfig,
}) async {
  // Step 0: placeholder-matchId session — see header comment for why.
  final session = BattleSession(transport, Uint8List(16));

  // Yield once before the first network write. This matters only when both
  // roles run in the same isolate (i.e. every test using InMemoryTransport,
  // never real cross-device play): `Future.wait([runDuelSetup(...host),
  // runDuelSetup(...guest)])` evaluates the host call synchronously up to
  // its *own* first `await` before the guest call is even started — so
  // without this yield, host's first `send()` (its matchId nonce) would race
  // ahead of guest's `BattleSession` constructor ever subscribing a
  // listener. InMemoryTransport's broadcast stream drops events sent before
  // a listener exists (no buffering), so that frame would be lost forever
  // and the guest's corresponding exchange would hang. This yield forces
  // both sides' session construction (and listener subscription) to finish
  // before either proceeds to send anything, independent of resumption
  // order afterward. Harmless in production — a real LAN socket already
  // buffers at the OS level regardless of listener timing.
  await Future<void>.value();

  // Step 1: agree matchId (DECISION 1).
  final myNonce = _random16();
  final peerNonce = await session.exchangeMatchIdNonce(myNonce);
  final matchId = _deriveMatchId(myNonce, peerNonce);

  // Step 2: capabilities + protocol-version gate.
  final peerCaps = await session.exchangeCapabilities(DeviceCapabilities.detect());
  if (peerCaps.battleProtocolVersion != kBattleProtocolVersion) {
    session.sendForfeit('battle_protocol_mismatch');
    throw StateError(
      'battle protocol version mismatch (local=$kBattleProtocolVersion, '
      'peer=${peerCaps.battleProtocolVersion}) — match aborted',
    );
  }

  // Step 3: match config — host authoritative (DECISION 3).
  final MatchConfig effectiveConfig;
  if (role == DuelRole.host) {
    await session.sendHostMatchConfig(hostConfig);
    effectiveConfig = hostConfig;
  } else {
    effectiveConfig = await session.receiveHostMatchConfig();
  }

  // Step 4: identity auth (BATTLE_AUTH_PLAN §3). Throws + forfeits internally
  // on any auth failure/self-reflection — propagate as-is.
  final peer = await session.exchangeIdentityAuth(localIdentity: localIdentity, matchId: matchId);

  final myOwnerHex = await localIdentity.ownerPubkeyHex();
  final localSpells = await _chapterSpells(localChapter);
  final localCommitments = [for (final s in localSpells) s.commitmentHex];

  // Step 4b: wizard display name — unauthenticated, presentation only (see
  // exchangeWizardName's doc comment). Runs after identity auth so it isn't
  // load-bearing for anything auth-adjacent; a stale/missing local name
  // exchanges as ''.
  final myWizardName = await Identity.loadWizardName() ?? '';
  final peerWizardName = await session.exchangeWizardName(myWizardName);

  // Step 4b (cont'd): chosen avatar id — same unauthenticated,
  // presentation-only treatment as wizardName (docs/AVATAR_PICKER_PLAN.md
  // §5.2). Not threaded into buildDuelBattleState/WizardAvatar — the sprite
  // map lives purely in the UI layer via AvatarAssignment.
  final myAvatarId = await Identity.loadAvatarId() ?? '';
  final peerAvatarId = await session.exchangeAvatarId(myAvatarId);

  // Step 5: spell-permission exchange (BATTLE_AUTH_PLAN §5). Send the local
  // grants where WE are grantee, for spells in our own chapter — so a
  // loaned spell we hold a grant for (but don't own) can still be cast and
  // authorized on the peer's side (_verifyPeerSpellCast's castingPlayerMayUse
  // check, BATTLE_AUTH_PLAN §4).
  final allMyGrants = await SpellPermission.loadAll();
  final myOutgoingGrants = allMyGrants
      .where((p) => _hexEq(p.granteePubkeyHex, myOwnerHex) && localCommitments.contains(p.commitmentHex))
      .toList();
  final peerPermissions = await session.exchangeSpellPermissions(
    myOutgoingGrants,
    peerOwnerPubkeyHex: peer.ownerPubkeyHex,
  );

  // Step 6: book commitment/hash — feeds peerBookRoot for Stage 2.
  //
  // Two different identities, deliberately (COUNTER_CHARM_KINSHIP_PLAN.md
  // §3.3): the Merkle ROOT is over grid commitments, because it authenticates
  // per-spell membership and hand position, which needs a one-to-one key. The
  // batch HASH is over salted behavioural-kinship leaves, because what it
  // commits to is the post-match kin-stacking check, which needs the
  // many-to-one key — and must not hand the opponent a stable identifier for
  // every spell in the book (§3.5).
  final localRootHex = BookCommitment.computeRoot(localCommitments);
  final peerRootBytes =
      await session.exchangeBookCommitment(BookCommitment.rootToBytes(localRootHex));
  final kinRevealSalt = newKinRevealSalt();
  final localKinLeaves = kinStackingLeaves(
    [for (final s in localSpells) SpellKinEntry(s.kinKey)],
    salt: kinRevealSalt,
  )..sort();
  final peerBookHash =
      await session.exchangeBookHash(BookCommitment.hashLeaves(localKinLeaves));
  final peerBookRootHex = _bytesToRootHex(peerRootBytes);
  final peerBookLeafCount =
      await session.exchangeBookLeafCount(localCommitments.length);

  // Step 7: artifact-loadout exchange — required in Stage 1, see
  // duel_battle_setup.dart's doc comment.
  final peerArtifacts = await session.exchangeArtifactLoadout(localChapter.artifacts);

  // Step 8: symmetric, pubkey-ordered BattleState construction (DECISION 2).
  final setup = buildDuelBattleState(
    config: effectiveConfig,
    localArtifacts: localChapter.artifacts,
    peerArtifacts: peerArtifacts,
    localOwnerHex: myOwnerHex,
    peerOwnerHex: peer.ownerPubkeyHex,
    localWizardName: myWizardName,
    peerWizardName: peerWizardName,
  );

  return DuelSetupResult(
    session: session,
    state: setup.state,
    localPlayerId: setup.localPlayerId,
    localChapter: localChapter,
    matchId: matchId,
    effectiveConfig: effectiveConfig,
    peer: peer,
    peerBookRootHex: peerBookRootHex,
    localKinLeaves: localKinLeaves,
    peerBookHash: peerBookHash,
    peerBookLeafCount: peerBookLeafCount,
    peerPermissions: peerPermissions,
    localAvatarId: myAvatarId,
    peerAvatarId: peerAvatarId,
  );
}

// ── Helpers ───────────────────────────────────────────────────────────────────

Uint8List _random16() {
  final rng = Random.secure();
  return Uint8List.fromList(List.generate(16, (_) => rng.nextInt(256)));
}

/// `matchId = SHA-256(sorted(a, b))[0:16]` — sorted by byte value so both
/// devices compute the same hash regardless of which nonce arrived "first".
Uint8List _deriveMatchId(Uint8List a, Uint8List b) {
  final ordered = _compareBytes(a, b) <= 0 ? [...a, ...b] : [...b, ...a];
  final hash = sha256.convert(ordered).bytes;
  return Uint8List.fromList(hash.sublist(0, 16));
}

int _compareBytes(Uint8List a, Uint8List b) {
  final len = a.length < b.length ? a.length : b.length;
  for (var i = 0; i < len; i++) {
    if (a[i] != b[i]) return a[i] - b[i];
  }
  return a.length - b.length;
}

/// Resolves a Chapter's entries to their spells' commitmentHex values (a
/// ChapterEntry only stores spellId — mirrors battle_screen.dart's
/// `_loadSpells` id→SpellAsset lookup).
/// The chapter's spells, in entry order, skipping entries whose spell is no
/// longer in the library. Shared by the Merkle-root path (which needs
/// commitments) and the kin-stacking path (which needs kin keys), so the two
/// lists can never disagree about WHICH spells are in the book.
Future<List<SpellAsset>> _chapterSpells(ChapterAsset chapter) async {
  final all = await SpellAsset.loadAll();
  final byId = {for (final s in all) s.id: s};
  return chapter.entries
      .map((e) => byId[e.spellId])
      .whereType<SpellAsset>()
      .toList();
}

String _bytesToRootHex(Uint8List bytes) =>
    '0x${bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';

bool _hexEq(String a, String b) {
  BigInt parse(String s) => BigInt.parse(s.startsWith('0x') ? s.substring(2) : s, radix: 16);
  return parse(a) == parse(b);
}
