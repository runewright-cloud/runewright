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
// This file does no proof verification of its own account and loads no Flutter
// assets — but it now RUNS one verification during setup, for the peer's
// equipped Aetherial Armor, which must be certified before a BattleState
// exists. The resources for that ([verifyProof] + [vkBytesForTier]) are
// INJECTED by the lobby, which is the layer that may touch rootBundle; the
// asset loading and `initSrsCached` call stay there (see
// battle_lobby_screen.dart's prepareDuelVerifierResources). Spell-cast
// verification is still BattleScreen's job and is unchanged.
//
// Sequence (fail-closed on every negative — forfeit + throw, never silent
// accept, mirroring BattleSession.exchangeIdentityAuth's own discipline):
//   1. Agree matchId (DECISION 1) — neither side unilaterally controls it.
//   2. Exchange + check capabilities (wire-protocol gate, then the
//      battle-engine consensus gate — battle_engine_version.dart).
//   3. Match config — host authoritative (DECISION 3), and the engine epoch
//      the agreed config pins is checked against this build's.
//   4. Identity auth (BATTLE_AUTH_PLAN §3 — already built).
//   5. Spell-permission exchange (BATTLE_AUTH_PLAN §5) — both our grants
//      naming the peer (restricted to spells in our own chapter) and the
//      peer's grants naming us are exchanged and verified.
//   6. Book commitment/hash (feeds peerBookRoot for membership-proof checks).
//   7. Artifact-loadout exchange (required — see duel_battle_setup.dart's
//      doc comment on why this can't be deferred).
//   7b. Armor-loadout exchange + certification (docs/AETHERIAL_ARMOR.md) —
//      sent on every duel, `{"armor":null}` when nothing is worn; the peer's
//      proof is cryptographically verified here and both sides' armor is
//      derived through the one `CertifiedArmor.fromOutputs`.
//   7c. Setup-ready barrier — each side declares that every check above
//      passed, and waits for the other's declaration, so a refusal on either
//      side aborts BOTH rather than leaving one device in a battle screen for
//      a match the other has already abandoned.
//   8. buildDuelBattleState — symmetric, pubkey-ordered (DECISION 2).
//      UNCHANGED by armor this slice: the certified armors are returned in
//      [DuelSetupResult] and applied to nothing yet, deliberately, so that
//      "both devices agree on the armor" can be proven before armor can move
//      the lockstep state.
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
import '../../spells/chapter_armor.dart' show resolveEquippedArmor;
import '../../spells/chapter_asset.dart' show ChapterAsset;
import '../../spells/spell_asset.dart' show SpellAsset;
import '../../spells/spell_identity.dart'
    show SpellKinEntry, kinStackingLeaves, newKinRevealSalt;
import '../../spells/spell_permission.dart' show SpellPermission;
import '../../protocol/match_session.dart' show ProofVerifier;
import '../engine/armor_certification.dart';
import '../engine/battle_engine_version.dart' show kBattleEngineVersion;
import '../engine/book_commitment.dart';
import '../models/armor_envelope.dart';
import '../models/battle_state.dart';
import '../models/certified_armor.dart';
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
    required this.localArmor,
    required this.peerArmor,
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

  /// This device's equipped armor as its own proof attests it, or null if
  /// nothing is worn (docs/AETHERIAL_ARMOR.md).
  ///
  /// Derived via `ProofIntake.parseOwn` — our own bytes, so no verification —
  /// then through the same `CertifiedArmor.fromOutputs` the peer's goes
  /// through, so the two devices' readings of one proof cannot diverge.
  ///
  /// **Applied to nothing yet.** Setup produces it; the next slice feeds it
  /// into avatar/state construction. The one-slice gap is deliberate: it lets
  /// us prove both devices agree on the armor before armor can influence
  /// canonical state.
  final CertifiedArmor? localArmor;

  /// The peer's equipped armor as THEIR proof attests it, or null if they
  /// declared none.
  ///
  /// Derived via `ProofIntake.verifyAndParse` — their bytes, so the proof is
  /// cryptographically verified first — and then through the identical
  /// derivation. Nothing the peer asserted about their armor is used; only the
  /// verified public outputs.
  final CertifiedArmor? peerArmor;
}

/// Runs the full LAN duel handshake over an already-connected [transport]
/// and returns everything needed to push [BattleScreen]. Throws (after
/// sending forfeit where applicable) on any handshake failure — callers
/// should catch, disconnect the transport, and return to the lobby.
///
/// [verifyProof] and [vkBytesForTier] are the injected verification resources
/// for step 7b (peer armor certification). The lobby loads the VK assets and
/// initialises the SRS/CRS before calling — see
/// `prepareDuelVerifierResources` in battle_lobby_screen.dart, and CLAUDE.md
/// bug-avoidance #4 for why finding the SRS cache on disk is not the same as
/// initialising it.
///
/// They are optional so that a caller with no armor on either side (and every
/// existing test) needs no proving stack. That is NOT a loophole: if the peer
/// declares an armor and these are absent, certification refuses it and the
/// match aborts. A missing verifier can only ever cost you a match, never buy
/// an unverified armor.
Future<DuelSetupResult> runDuelSetup({
  required Transport transport,
  required DuelRole role,
  required Identity localIdentity,
  required ChapterAsset localChapter,
  required MatchConfig hostConfig,
  ProofVerifier? verifyProof,
  Uint8List? Function(int tier)? vkBytesForTier,
}) async {
  // Step 0: placeholder-matchId session — see header comment for why.
  final session = BattleSession(transport, Uint8List(16));

  try {
    return await _runSetupSteps(
      session: session,
      role: role,
      localIdentity: localIdentity,
      localChapter: localChapter,
      hostConfig: hostConfig,
      verifyProof: verifyProof,
      vkBytesForTier: vkBytesForTier,
    );
  } on PeerForfeitException {
    // They already stopped and told us why; forfeiting back at a device that
    // has gone is noise.
    rethrow;
  } on PeerConnectionLostException {
    rethrow;
  } catch (_) {
    // Backstop for every refusal path that does not forfeit on its own —
    // corrupt local library JSON, an unreadable identity, anything unforeseen.
    // Load-bearing now that the peer blocks on [BattleSession.exchangeSetupReady]:
    // an unforfeited throw here would leave them waiting for a readiness frame
    // that is never coming, right up until the socket dies. A second forfeit
    // on a path that already sent one is harmless — the peer consumes the
    // first and the rest sit unread.
    session.sendForfeit('setup_failed');
    rethrow;
  }
}

Future<DuelSetupResult> _runSetupSteps({
  required BattleSession session,
  required DuelRole role,
  required Identity localIdentity,
  required ChapterAsset localChapter,
  required MatchConfig hostConfig,
  required ProofVerifier? verifyProof,
  required Uint8List? Function(int tier)? vkBytesForTier,
}) async {
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

  // Step 2b: battle-engine consensus gate (battle_engine_version.dart). The
  // capabilities exchange is the only symmetric declaration in the handshake —
  // both peers state their own build at once — so it is the only place either
  // side can learn the OTHER's engine epoch. The config that follows is
  // host-authored, and an old guest that adopted it would announce nothing at
  // all.
  //
  // Both roles run the identical comparison (peer's declaration vs this
  // build's constant), so the verdict does not depend on who is host, who
  // connected first, or which device is asking. It runs before identity auth,
  // before the config, before any state exists — an incompatible pair never
  // reaches turn 1, rather than discovering it as a state-hash mismatch
  // mid-duel with no way to tell an old build from a cheat.
  if (peerCaps.battleEngineVersion != kBattleEngineVersion) {
    session.sendForfeit('battle_engine_mismatch');
    throw StateError(
      'battle engine version mismatch (local=$kBattleEngineVersion, '
      'peer=${peerCaps.battleEngineVersion}) — match aborted',
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

  // Step 3b: the engine epoch the match is PINNED to, which is a different
  // question from what the peer's build is (step 2b). Both sides check the
  // agreed config against this build's constant, so a config authored under
  // rules this build does not implement — a stale stored config, a host on a
  // build whose capabilities lied, a future negotiated downgrade — is refused
  // here rather than silently played under whichever semantics happen to be
  // compiled in.
  if (effectiveConfig.battleEngineVersion != kBattleEngineVersion) {
    session.sendForfeit('battle_engine_mismatch');
    throw StateError(
      'match config pins battle engine version '
      '${effectiveConfig.battleEngineVersion} but this build implements '
      '$kBattleEngineVersion — match aborted',
    );
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

  // Step 7b: armor loadout — exchanged on every duel, then certified.
  //
  // Ordering matters twice over. It is AFTER identity auth because both
  // certifications bind a proof to an authenticated owner_pubkey, and before
  // auth there is no authenticated peer key to bind to — an armor checked
  // against a self-declared identity is not checked at all. It is BEFORE
  // buildDuelBattleState because a match with an armor neither side can agree
  // on must never reach a BattleState at all.
  //
  // Local armor is certified first, so a broken local loadout fails before we
  // ask the peer to trust anything.
  final SpellAsset? localArmorAsset;
  try {
    localArmorAsset = await resolveEquippedArmor(localChapter);
  } on StateError {
    // A binding whose asset is gone is still a refusal, and the peer is
    // blocked on our armor frame — forfeit before rethrowing or they wait for
    // a frame that is never coming.
    session.sendForfeit('armor_certification_failed');
    rethrow;
  }
  final CertifiedArmor? localArmor;
  try {
    localArmor = certifyOwnArmor(
      armor: localArmorAsset,
      wearerOwnerPubkeyHex: myOwnerHex,
      ordinaryArtifactCount: localChapter.ordinaryArtifactCount,
      // The leyline agreed at step 3, hundreds of lines above — the host's, or
      // ours if we are the host. Both devices reach this line holding the same
      // `effectiveConfig`, so both derive the same keyword dictionary and the
      // wire carries nothing about it (audit R-8).
      lexicon: ArmorLexicon.of(effectiveConfig.leyline),
    );
  } on ArmorCertificationException catch (e) {
    session.sendForfeit('armor_certification_failed');
    throw StateError('local armor cannot be certified: ${e.reason} — match aborted');
  }

  // The envelope carries the proof and a routing tier; nothing derived. The
  // tier is re-derived from our own T rather than read off SpellAsset.tier,
  // for the same reason certifyOwnArmor does it: the stored tier is authored.
  final ArmorEnvelope? localEnvelope = localArmorAsset == null
      ? null
      : ArmorEnvelope(
          tier: armorProofTier(localArmorAsset),
          proofBytes: localArmorAsset.proofBytes,
        );

  final ArmorEnvelope? peerEnvelope;
  try {
    peerEnvelope = await session.exchangeArmorLoadout(localEnvelope);
  } on FormatException catch (e) {
    // A malformed payload is a failed handshake, never "they have no armor".
    session.sendForfeit('armor_loadout_malformed');
    throw StateError('peer armor loadout is malformed: $e — match aborted');
  }

  final CertifiedArmor? peerArmor;
  try {
    peerArmor = await certifyPeerArmor(
      envelope: peerEnvelope,
      wearerOwnerPubkeyHex: peer.ownerPubkeyHex,
      ordinaryArtifactCount: peerArtifacts.length,
      verifyProof: verifyProof,
      vkBytesForTier: vkBytesForTier,
      lexicon: ArmorLexicon.of(effectiveConfig.leyline),
    );
  } on ArmorCertificationException catch (e) {
    session.sendForfeit('armor_certification_failed');
    throw StateError('peer armor cannot be certified: ${e.reason} — match aborted');
  }

  // Step 7c: the setup-finalization barrier. Everything that can refuse this
  // match has now run on this side, so declare readiness and wait for theirs.
  //
  // This is what makes a refusal two-sided. Certification is asymmetric in
  // time — the side whose armor is fine finishes its own checks while the
  // other side is still verifying — so without this barrier a rejected match
  // could leave one device in a battle screen and the other in the lobby. Any
  // refusal forfeits, and a forfeit interrupts this wait
  // (BattleSession._awaitFrame, slice 4.5), so both sides end up aborting on
  // the same cause.
  //
  // Deliberately AFTER armor certification and BEFORE buildDuelBattleState:
  // readiness has to mean "I have finished checking", and no state may exist
  // for a match that either side is about to reject.
  await session.exchangeSetupReady();

  // Step 8: symmetric, pubkey-ordered BattleState construction (DECISION 2).
  final setup = buildDuelBattleState(
    config: effectiveConfig,
    localArtifacts: localChapter.artifacts,
    peerArtifacts: peerArtifacts,
    localOwnerHex: myOwnerHex,
    peerOwnerHex: peer.ownerPubkeyHex,
    localWizardName: myWizardName,
    peerWizardName: peerWizardName,
    // Already certified above — handed on as equipment, never re-read. The
    // builder's pubkey ordering decides which avatar each lands on, so both
    // devices seat the same armor on the same wizard without a host/guest
    // branch.
    localArmor: localArmor,
    peerArmor: peerArmor,
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
    localArmor: localArmor,
    peerArmor: peerArmor,
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
