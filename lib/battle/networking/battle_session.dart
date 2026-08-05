// SPDX-License-Identifier: GPL-3.0-or-later
//
// battle_session.dart — bidirectional battle protocol session.
//
// Unlike MatchSession (strict request/response, one Completer at a time),
// BattleSession routes incoming frames by type to a broadcast stream —
// required because both clients can send simultaneously (movement commits,
// state hashes, etc.). Callers subscribe to framesOfType() for the type
// they're waiting for; the TurnLoop drives the exchange order.
//
// Lifecycle: created from a Transport AFTER MatchSession.close() has
// cancelled its subscription, then discarded at match end.
// The matchId carried over from the proof-exchange handshake is stored for
// context (BATTLE_PROTOCOL.md §0).
//
// See docs/BATTLE_PROTOCOL.md §0-§2 for the full protocol sequence.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../../identity/identity.dart';
import '../../protocol/transport.dart';
import '../../spells/chapter_asset.dart' show ArtifactEntry;
import '../../spells/spell_permission.dart';
import '../engine/book_commitment.dart';
import '../engine/commit_reveal.dart';
import '../models/match_config.dart';
import '../models/match_outcome.dart';
import 'battle_wire.dart';
import 'match_discovery.dart';

/// Domain-separation tag for the identity-authentication handshake signature
/// (BATTLE_AUTH_PLAN.md §3). Distinct from [kStateHashSignatureTag] so an
/// auth signature can never be replayed as a state-hash signature or
/// vice-versa.
const kIdentityAuthSignatureTag = 'RUNEWRIGHT_BATTLE_AUTH_V1\x00';

/// The result of a successful [BattleTurnSession.exchangeIdentityAuth] — the
/// peer's raw Ed25519 public key and its derived circuit-facing owner_pubkey,
/// both *authenticated* by a fresh-nonce signature (not merely asserted by an
/// unverified proof public input — see BATTLE_AUTH_PLAN.md §0/§2).
class AuthenticatedPeer {
  const AuthenticatedPeer({required this.rawPubkey, required this.ownerPubkeyHex});

  /// Raw 32-byte Ed25519 public key, verified via a fresh-nonce signature.
  final Uint8List rawPubkey;

  /// Poseidon2(key_hi, key_lo) of [rawPubkey] — the circuit-facing identity
  /// that spell proofs declare as their owner_pubkey public input.
  final String ownerPubkeyHex;

  /// Sentinel for solo/local play, where there is no real peer to
  /// authenticate. Empty owner_pubkey hex so identity/authorization checks
  /// (which compare hex strings) never accidentally match a real spell owner.
  static final none = AuthenticatedPeer(rawPubkey: Uint8List(0), ownerPubkeyHex: '');
}

bool _hexEq(String a, String b) {
  BigInt parse(String s) => BigInt.parse(s.startsWith('0x') ? s.substring(2) : s, radix: 16);
  return parse(a) == parse(b);
}

// ── TurnLoop exchange interface ───────────────────────────────────────────────

/// Abstract interface for the per-turn commit-reveal exchanges that [TurnLoop]
/// needs. Implemented by [BattleSession] (network) and [SoloBattleSession]
/// (local solo stub).
abstract class BattleTurnSession {
  /// Mutual Ed25519 challenge-response identity authentication
  /// (BATTLE_AUTH_PLAN.md §3). Must run once per session, before any spell
  /// cast is trusted (it feeds cast authorization and loan-permission
  /// verification). Solo/local play returns [AuthenticatedPeer.none].
  Future<AuthenticatedPeer> exchangeIdentityAuth({
    required Identity localIdentity,
    required Uint8List matchId,
  });

  /// Exchanges signed loan/transfer grants naming the authenticated peer as
  /// grantee (BATTLE_AUTH_PLAN.md §5). Returns only permissions that verify —
  /// signature valid, not expired, and [SpellPermission.granteePubkeyHex]
  /// matches [peerOwnerPubkeyHex] (the value [exchangeIdentityAuth] returned).
  /// Solo/local play returns an empty list.
  Future<List<SpellPermission>> exchangeSpellPermissions(
    List<SpellPermission> ours, {
    required String peerOwnerPubkeyHex,
  });

  Future<({Uint8List theirNonce, Uint8List theirCommit})> exchangeNonce({
    required Uint8List ourCommit,
    required Uint8List ourNonce,
  });
  Future<Uint8List> exchangeActionCommit(Uint8List ourCommit);
  Future<Uint8List> exchangeActionReveal(Uint8List ourReveal);
  Future<Uint8List> exchangeMoveCommit(Uint8List ourCommit);
  Future<Uint8List> exchangeMoveReveal(Uint8List ourReveal);
  Future<Uint8List> exchangeDelayedSpellReveals(Uint8List ourReveals);
  Future<Uint8List> exchangeStateHash(Uint8List ourHash);

  /// Phase 0 artifact-activation commit-reveal (ARTIFACT_SYSTEM_PLAN.md §4.2).
  ///
  /// The first exchange of the turn, ahead of the Phase 1 action commit: each
  /// player secretly commits which artifact (if any) they are spending this
  /// turn, then both reveal simultaneously. Shape mirrors
  /// [exchangeMeleeCommit]/[exchangeMeleeReveal] exactly, and like them it is
  /// sent uniformly every turn — `[0x00]` means "declaring nothing" — so the
  /// frame sequence is identical on both clients regardless of who spent what.
  ///
  /// Commit-reveal rather than a plain send-then-await because the declaration
  /// is a simultaneous decision: with a plain exchange a peer could stall,
  /// read our declaration, and then choose theirs.
  Future<Uint8List> exchangeArtifactActivationCommit(Uint8List ourCommit);
  Future<Uint8List> exchangeArtifactActivationReveal(Uint8List ourReveal);

  /// Resolution-phase melee commit-reveal: after movement has resolved (so
  /// both final positions are known), each player secretly commits an
  /// optional adjacent melee target, then both reveal simultaneously. Mirrors
  /// [exchangeMoveCommit]/[exchangeMoveReveal] exactly. Independent of the
  /// main-phase action — a player may cast a spell AND melee the same turn.
  Future<Uint8List> exchangeMeleeCommit(Uint8List ourCommit);
  Future<Uint8List> exchangeMeleeReveal(Uint8List ourReveal);

  /// Post-resolution free-move commit-reveal: after every spell for the turn
  /// has resolved, each avatar whose barrier burst from damage this turn
  /// (see [WizardAvatar.pendingFreeMoveBurst]) may commit an optional
  /// single-tile reactive step to an adjacent free tile. Shape mirrors
  /// [exchangeMeleeCommit]/[exchangeMeleeReveal] exactly; sent uniformly by
  /// both sides regardless of whether either avatar actually earned one.
  Future<Uint8List> exchangeFreeMoveCommit(Uint8List ourCommit);
  Future<Uint8List> exchangeFreeMoveReveal(Uint8List ourReveal);

  /// Divination (Air-Water) scrying pattern (MESH_ARCHITECTURE.md §13b).
  ///
  /// Always called once per turn regardless of whether either side has an
  /// active scry link this turn (uniform slot; content is conditional —
  /// [0x00] means "no active outgoing scry"). [ourFrame] carries a fresh,
  /// single-use X25519 public key when the local player is scrying the peer
  /// this turn.
  Future<Uint8List> exchangeScryKey(Uint8List ourFrame);

  /// The reply half of the scrying pattern: an AEAD-encrypted opening of the
  /// local player's committed spell-target leaf, addressed to the peer's
  /// [exchangeScryKey] public key, when the peer is scrying the local player
  /// this turn. [0x00] means "no active incoming scry to open."
  Future<Uint8List> exchangeScryOpen(Uint8List ourFrame);

  /// Divination (Water flavor — Watery Scrying Pool) spell-list reveal.
  /// Same shape and uniform-slot rule as [exchangeScryKey]/[exchangeScryOpen],
  /// kept as an independent exchange so simultaneous Air + Water links to the
  /// same peer never share a payload format.
  Future<Uint8List> exchangeSpellRevealKey(Uint8List ourFrame);

  /// The reply half: an AEAD-encrypted JSON spell list, addressed to the
  /// peer's [exchangeSpellRevealKey] public key, when the peer is scrying the
  /// local player's spell list this turn. [0x00] means "no active incoming
  /// reveal to open."
  Future<Uint8List> exchangeSpellRevealOpen(Uint8List ourFrame);

  /// Forced reveal-and-cast (docs/WILD_MAGIC_PLAN.md §9.5): each side sends
  /// the spells (with proofs and Merkle paths) for the hand slots that were
  /// publicly selected out of its own hand, and receives the peer's.
  ///
  /// **Not a uniform per-turn slot** — unlike the scry exchanges, this is sent
  /// only on turns where a forced cast actually fires. Both clients derive the
  /// triggering wild magic from the same certified proof outputs, so they
  /// always reach this call together or not at all.
  ///
  /// Returns null when there is no peer (solo/practice), so the caller
  /// resolves only local picks rather than awaiting a reveal that will never
  /// arrive.
  Future<Uint8List?> exchangeForcedReveal(Uint8List ourFrame);

  /// Request a fresh commit-reveal entropy exchange during spell resolution.
  ///
  /// For interactive effects where foreknowledge of pseudo-random outcomes
  /// could influence a player choice. Both clients MUST call this at the same
  /// deterministic point in the resolution sequence (the effect table
  /// hard-codes when). [reason] is a logging tag; it is not transmitted.
  ///
  /// Not yet called by any effect — this is the seam for future interactive
  /// spells. A modified client that refuses this exchange forfeits the match.
  Future<Uint8List> refreshEntropy(String reason);

  void sendForfeit(String reason);

  /// Completes with the peer's forfeit reason the moment they send a
  /// [BattleMsgType.forfeit] frame — the receive side of [sendForfeit].
  ///
  /// Every forfeit condition in the engine is one-sided by construction: the
  /// device that detects it throws out of `runTurn` and stops, while the peer
  /// (which sees nothing wrong) sits waiting for the next frame of whatever
  /// exchange came next. Until this existed the forfeit frame was written and
  /// never read by anything, so that peer simply hung — the "desync" a real
  /// LAN test shows as one dead device and one live one.
  ///
  /// Default: a future that never completes, for the implementations with no
  /// peer to hear from (solo/practice, test doubles). Only [BattleSession]
  /// overrides it.
  Future<String> get peerForfeit => Completer<String>().future;
}

// ── Network session ───────────────────────────────────────────────────────────

class BattleSession implements BattleTurnSession {
  BattleSession(this._transport, this.matchId) {
    _reader = BattleFrameReader();
    _sub = _transport.onReceive.listen(_reader.addChunk);
  }

  final Transport _transport;
  final Uint8List matchId;
  late final BattleFrameReader _reader;
  late final StreamSubscription<List<int>> _sub;

  /// See [BattleTurnSession.peerForfeit]. Safe to register lazily (on first
  /// read) even though a forfeit can arrive at any moment — including during
  /// the handshake, long before the battle screen subscribes:
  /// [BattleFrameReader.framesOfType] is queue-backed, so a frame that
  /// arrives with no listener yet is held in `_pendingByType` and handed to
  /// this listener when it registers, rather than dropped the way a bare
  /// broadcast `.where()` would.
  @override
  late final Future<String> peerForfeit = framesOfType(BattleMsgType.forfeit)
      .first
      .then((frame) => utf8.decode(frame.payload));

  /// All incoming battle frames, broadcast. Only used directly by
  /// [exchangeMatchConfig]'s ack/reject dual-type wait — everything else
  /// should use [framesOfType].
  Stream<BattleFrame> get frames => _reader.frames;

  /// The next frame of exactly [type] — buffers if it already arrived, never
  /// drops it. See [BattleFrameReader.framesOfType]'s doc comment for why
  /// this isn't a `.where()` filter over [frames].
  Stream<BattleFrame> framesOfType(BattleMsgType type) => _reader.framesOfType(type);

  void send(BattleMsgType type, Uint8List payload) {
    _transport.send(BattleFrame(type, payload).encode());
  }

  // ── Identity authentication (BATTLE_AUTH_PLAN.md §3) ────────────────────────

  /// Mutual Ed25519 challenge-response: each side signs the *peer's* fresh
  /// nonce and presents its raw public key, proving both freshness (the
  /// verifier chose the nonce, so a captured signature can't be replayed from
  /// a prior session) and possession (only the private-key holder can sign).
  /// The presented raw key is then hashed via
  /// [Identity.ownerPubkeyHexFromRawKey] to bind it to the circuit-facing
  /// owner_pubkey that spell proofs declare — this is what proof verification
  /// alone cannot do (CLAUDE.md invariant 5: the circuit never proves key
  /// possession).
  ///
  /// Forfeits and throws on: an invalid signature (forged, wrong nonce, or a
  /// raw key that doesn't match what was signed) or the peer presenting our
  /// own identity (self/reflection).
  @override
  Future<AuthenticatedPeer> exchangeIdentityAuth({
    required Identity localIdentity,
    required Uint8List matchId,
  }) async {
    final nonceLocal = CommitRevealEntropy.generateNonce();
    send(BattleMsgType.authChallenge, nonceLocal);
    final noncePeer = (await framesOfType(BattleMsgType.authChallenge).first).payload;

    final tag = utf8.encode(kIdentityAuthSignatureTag);
    final ourSig = await localIdentity.sign([...tag, ...matchId, ...noncePeer]);
    send(
      BattleMsgType.authResponse,
      Uint8List.fromList([...localIdentity.publicKeyBytes, ...ourSig]),
    );
    final responsePayload =
        (await framesOfType(BattleMsgType.authResponse).first).payload;
    if (responsePayload.length < 32 + 64) {
      sendForfeit('auth_malformed_response');
      throw StateError('peer auth response too short — match forfeit');
    }
    final peerRawPubkey = responsePayload.sublist(0, 32);
    final peerSig = responsePayload.sublist(32, 96);

    final sigOk = await Identity.verify(
      message: [...tag, ...matchId, ...nonceLocal],
      signatureBytes: peerSig,
      publicKeyBytes: peerRawPubkey,
    );
    if (!sigOk) {
      sendForfeit('auth_failed');
      throw StateError('peer identity signature invalid — match forfeit');
    }

    final peerOwnerPubkeyHex =
        await Identity.ownerPubkeyHexFromRawKey(peerRawPubkey);
    final myOwnerPubkeyHex = await localIdentity.ownerPubkeyHex();
    if (_hexEq(peerOwnerPubkeyHex, myOwnerPubkeyHex)) {
      sendForfeit('auth_self');
      throw StateError('peer presented our own identity — match forfeit');
    }

    return AuthenticatedPeer(
      rawPubkey: Uint8List.fromList(peerRawPubkey),
      ownerPubkeyHex: peerOwnerPubkeyHex,
    );
  }

  /// Exchanges signed [SpellPermission] grants (BATTLE_AUTH_PLAN.md §5).
  /// [ours] should be the local grants naming the peer as grantee. The
  /// returned list is filtered to only permissions that are currently usable
  /// (valid signature, not expired) AND name [peerOwnerPubkeyHex] as grantee —
  /// a permission that fails either check is silently dropped, not trusted.
  @override
  Future<List<SpellPermission>> exchangeSpellPermissions(
    List<SpellPermission> ours, {
    required String peerOwnerPubkeyHex,
  }) async {
    final payload = Uint8List.fromList(
      utf8.encode(jsonEncode(ours.map((p) => p.toJson()).toList())),
    );
    send(BattleMsgType.spellPermissions, payload);
    final frame = await framesOfType(BattleMsgType.spellPermissions).first;
    final decoded = jsonDecode(utf8.decode(frame.payload)) as List<dynamic>;
    final received = decoded
        .map((j) => SpellPermission.fromJson(j as Map<String, dynamic>))
        .toList();

    final verified = <SpellPermission>[];
    for (final perm in received) {
      if (!_hexEq(perm.granteePubkeyHex, peerOwnerPubkeyHex)) continue;
      if (!await perm.isCurrentlyUsable()) continue;
      verified.add(perm);
    }
    return verified;
  }

  // ── Setup exchanges ─────────────────────────────────────────────────────────

  /// Symmetric matchId establishment (LAN_BATTLE_WIREUP_PLAN.md §3.2 step 1;
  /// DECISION 1). Both sides exchange a fresh 16-byte nonce, then each
  /// independently derives `matchId = SHA-256(sorted(ourNonce, theirNonce))[0:16]`
  /// — neither side unilaterally controls it, and both compute the same value
  /// regardless of arrival order (sorted by byte value before concatenating).
  ///
  /// Must be called on `this` session before [matchId] is meaningfully used
  /// elsewhere (e.g. [exchangeIdentityAuth]'s `matchId` parameter) — this
  /// session is typically constructed with a placeholder `matchId` (e.g. 16
  /// zero bytes) specifically so this exchange can run over its one
  /// persistent frame reader before the real value is known. The `matchId`
  /// this returns should be threaded through as an explicit parameter to
  /// every subsequent call that needs it (`this.matchId` stays the
  /// placeholder — it is inert plumbing, read by nothing internal to this
  /// class).
  Future<Uint8List> exchangeMatchIdNonce(Uint8List ourNonce) async {
    send(BattleMsgType.matchIdNonce, ourNonce);
    final frame = await framesOfType(BattleMsgType.matchIdNonce).first;
    return frame.payload;
  }

  /// Both sides send capabilities simultaneously; we return what we received.
  ///
  /// The lobby uses the peer's [DeviceCapabilities.ramTierCap] to gate
  /// tier-48 in [MatchConfig.tier] negotiation.
  Future<DeviceCapabilities> exchangeCapabilities(DeviceCapabilities ours) async {
    send(BattleMsgType.capabilities, Uint8List.fromList(utf8.encode(jsonEncode(ours.toJson()))));
    final frame = await framesOfType(BattleMsgType.capabilities).first;
    return DeviceCapabilities.fromJson(jsonDecode(utf8.decode(frame.payload)) as Map<String, dynamic>);
  }

  /// Both sides send their [MatchConfig] simultaneously; returns the peer's
  /// config on agreement, null on mismatch (caller should abort the session).
  ///
  /// Agreement check is real (field-by-field comparison); conflict-resolution
  /// UI is out of scope for this pass.
  Future<MatchConfig?> exchangeMatchConfig(MatchConfig ours) async {
    send(BattleMsgType.matchConfig, Uint8List.fromList(utf8.encode(jsonEncode(ours.toJson()))));
    final frame = await framesOfType(BattleMsgType.matchConfig).first;
    final theirs = MatchConfig.fromJson(jsonDecode(utf8.decode(frame.payload)) as Map<String, dynamic>);

    if (!ours.matches(theirs)) {
      send(BattleMsgType.matchConfigReject, Uint8List.fromList(utf8.encode('config mismatch')));
      // TODO(battle): surface conflict-resolution UI; for now abort.
      return null;
    }
    send(BattleMsgType.matchConfigAck, Uint8List(0));
    // Wait for their ack or reject — filter the broadcast stream for either type.
    final ack = await frames
        .where((f) => f.type == BattleMsgType.matchConfigAck || f.type == BattleMsgType.matchConfigReject)
        .first;
    if (ack.type == BattleMsgType.matchConfigReject) return null;
    return theirs;
  }

  /// Host-authoritative variant of [exchangeMatchConfig] (DECISION 3,
  /// LAN_BATTLE_WIREUP_PLAN.md §2): the host authors [config] and the guest
  /// has no separate opinion to assert, so there is nothing to compare — the
  /// guest simply adopts what it receives via [receiveHostMatchConfig].
  /// [exchangeMatchConfig]'s strict mutual-equality check can't express this
  /// (both sides would need to already know the same value *before* the one
  /// round trip that's supposed to convey it); this pair sidesteps that by
  /// only ever having one side originate the value. Reuses the existing
  /// `matchConfig`/`matchConfigAck` wire types — call this from the host,
  /// [receiveHostMatchConfig] from the guest.
  Future<void> sendHostMatchConfig(MatchConfig config) async {
    send(BattleMsgType.matchConfig, Uint8List.fromList(utf8.encode(jsonEncode(config.toJson()))));
    await framesOfType(BattleMsgType.matchConfigAck).first;
  }

  /// See [sendHostMatchConfig]. Call from the guest.
  Future<MatchConfig> receiveHostMatchConfig() async {
    final frame = await framesOfType(BattleMsgType.matchConfig).first;
    final config = MatchConfig.fromJson(jsonDecode(utf8.decode(frame.payload)) as Map<String, dynamic>);
    send(BattleMsgType.matchConfigAck, Uint8List(0));
    return config;
  }

  /// Both sides send their player-chosen wizard name simultaneously.
  /// Unauthenticated — presentation only (battle_screen.dart's status panel
  /// and HUD chip), never fed into cast authorization or the state-hash
  /// lockstep. Returns the peer's name, or '' if they haven't set one.
  Future<String> exchangeWizardName(String ours) async {
    send(BattleMsgType.wizardName, Uint8List.fromList(utf8.encode(ours)));
    final frame = await framesOfType(BattleMsgType.wizardName).first;
    return utf8.decode(frame.payload);
  }

  /// Both sides send their player-chosen avatar id simultaneously.
  /// Unauthenticated — presentation only (which sprite the wizard wears on
  /// the battlefield), never fed into cast authorization or the state-hash
  /// lockstep. Returns the peer's avatar id, or '' if they haven't chosen
  /// one. Copies [exchangeWizardName]'s shape verbatim (send first, then
  /// await the frame) — this repo has already been bitten by a broadcast
  /// stream frame being dropped when a listener attached after the send.
  Future<String> exchangeAvatarId(String ours) async {
    send(BattleMsgType.avatarId, Uint8List.fromList(utf8.encode(ours)));
    final frame = await framesOfType(BattleMsgType.avatarId).first;
    return utf8.decode(frame.payload);
  }

  /// Both sides send their Chapter Merkle root simultaneously.
  /// Returns the peer's root bytes (32 bytes).
  Future<Uint8List> exchangeBookCommitment(Uint8List ourRoot) async {
    send(BattleMsgType.bookCommit, ourRoot);
    final frame = await framesOfType(BattleMsgType.bookCommit).first;
    return frame.payload;
  }

  /// Both sides send their batch leaf hash simultaneously (Option 2).
  ///
  /// [ourHash] is [BookCommitment.hashLeaves] over the local chapter's sorted
  /// commitmentHex values. Returns the peer's 32-byte hash; store it for
  /// verification at [exchangeBookReveal].
  Future<Uint8List> exchangeBookHash(Uint8List ourHash) async {
    send(BattleMsgType.bookHash, ourHash);
    final frame = await framesOfType(BattleMsgType.bookHash).first;
    return frame.payload;
  }

  /// Both sides declare their chapter's leaf count simultaneously
  /// (SPELL_DRAW_WIRING_PLAN.md §3). Minor disclosure (how many spells are in
  /// the chapter) — needed publicly so DrawSchedule can compute
  /// `nextInt(leafCount)` for the *peer's* chapter without ever learning its
  /// contents (only the Merkle root of which is committed via
  /// [exchangeBookCommitment]). Returns the peer's leaf count.
  Future<int> exchangeBookLeafCount(int ourCount) async {
    final payload = ByteData(4)..setUint32(0, ourCount, Endian.big);
    send(BattleMsgType.bookLeafCount, payload.buffer.asUint8List());
    final frame = await framesOfType(BattleMsgType.bookLeafCount).first;
    return ByteData.sublistView(frame.payload).getUint32(0, Endian.big);
  }

  /// Both sides send their Chapter's public artifact loadout simultaneously
  /// (LAN_BATTLE_WIREUP_PLAN.md §3.1/§3.2 step 8). Required — not optional
  /// hardening — because `BattleState.toCanonicalBytes()` hashes each
  /// avatar's full accoutrement list and its mana-gem-derived maxMana/mana;
  /// a peer avatar built from any other loadout diverges the state-hash
  /// lockstep on the very first turn. Unlike the Chapter's *spells* (kept
  /// secret behind [exchangeBookCommitment]'s Merkle root), artifact loadout
  /// is public equipment — safe to exchange in the clear.
  Future<List<ArtifactEntry>> exchangeArtifactLoadout(List<ArtifactEntry> ours) async {
    final payload = Uint8List.fromList(
      utf8.encode(jsonEncode(ours.map((a) => a.toJson()).toList())),
    );
    send(BattleMsgType.artifactLoadout, payload);
    final frame = await framesOfType(BattleMsgType.artifactLoadout).first;
    final decoded = jsonDecode(utf8.decode(frame.payload)) as List<dynamic>;
    return decoded
        .map((j) => ArtifactEntry.fromJson(j as Map<String, dynamic>))
        .toList();
  }

  /// Post-match: both sides reveal their sorted commitmentHex list simultaneously.
  ///
  /// [ourSortedHexes] must be sorted (matching the order used in
  /// [BookCommitment.computeRoot] and [BookCommitment.hashLeaves]).
  /// [expectedPeerHash] is the hash received during [exchangeBookHash].
  ///
  /// Returns the peer's verified commitmentHex list, or null if:
  ///   - The peer's revealed list's SHA-256 does not match [expectedPeerHash].
  ///   - The list contains duplicate commitmentHex values (Kin-stacking).
  ///
  /// Both sends happen simultaneously before verification so neither side can
  /// withhold based on the other's reveal.
  Future<List<String>?> exchangeBookReveal(
    List<String> ourSortedHexes, {
    required Uint8List expectedPeerHash,
  }) async {
    final payload = Uint8List.fromList(
      utf8.encode(jsonEncode(ourSortedHexes)),
    );
    send(BattleMsgType.bookReveal, payload);
    final frame = await framesOfType(BattleMsgType.bookReveal).first;
    final theirHexes =
        (jsonDecode(utf8.decode(frame.payload)) as List<dynamic>).cast<String>();

    // Verify hash matches the commitment made at session start.
    final actualHash = BookCommitment.hashLeaves(theirHexes);
    if (!_constantTimeEqual(actualHash, expectedPeerHash)) return null;

    // Verify no duplicate grid commitments (Kin-stacking detection).
    final seen = <String>{};
    for (final hex in theirHexes) {
      if (!seen.add(hex)) return null;
    }

    return theirHexes;
  }

  static bool _constantTimeEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  // ── Per-turn commit-reveal ──────────────────────────────────────────────────

  /// Commit-reveal entropy exchange (BATTLE_PROTOCOL.md §3).
  ///
  /// Both sides commit simultaneously, then reveal simultaneously. Returns
  /// `(theirNonce, theirCommit)` so the caller can verify via
  /// [CommitRevealEntropy.revealAndCombine] and detect withheld reveals.
  @override
  Future<({Uint8List theirNonce, Uint8List theirCommit})> exchangeNonce({
    required Uint8List ourCommit,
    required Uint8List ourNonce,
  }) async {
    // Commit phase — both send simultaneously.
    send(BattleMsgType.nonceCommit, ourCommit);
    final theirCommitFrame = await framesOfType(BattleMsgType.nonceCommit).first;
    final theirCommit = theirCommitFrame.payload;

    // Reveal phase.
    send(BattleMsgType.nonceReveal, ourNonce);
    final theirRevealFrame = await framesOfType(BattleMsgType.nonceReveal).first;
    return (theirNonce: theirRevealFrame.payload, theirCommit: theirCommit);
  }

  // ── Per-turn movement ───────────────────────────────────────────────────────

  @override
  Future<Uint8List> exchangeMoveCommit(Uint8List ourCommit) async {
    send(BattleMsgType.moveCommit, ourCommit);
    final frame = await framesOfType(BattleMsgType.moveCommit).first;
    return frame.payload;
  }

  @override
  Future<Uint8List> exchangeMoveReveal(Uint8List ourReveal) async {
    send(BattleMsgType.moveReveal, ourReveal);
    final frame = await framesOfType(BattleMsgType.moveReveal).first;
    return frame.payload;
  }

  // ── Phase 0 artifact-activation commit-reveal ───────────────────────────────

  @override
  Future<Uint8List> exchangeArtifactActivationCommit(Uint8List ourCommit) async {
    send(BattleMsgType.artifactCommit, ourCommit);
    final frame = await framesOfType(BattleMsgType.artifactCommit).first;
    return frame.payload;
  }

  @override
  Future<Uint8List> exchangeArtifactActivationReveal(Uint8List ourReveal) async {
    send(BattleMsgType.artifactReveal, ourReveal);
    final frame = await framesOfType(BattleMsgType.artifactReveal).first;
    return frame.payload;
  }

  // ── Resolution-phase melee commit-reveal ────────────────────────────────────

  @override
  Future<Uint8List> exchangeMeleeCommit(Uint8List ourCommit) async {
    send(BattleMsgType.meleeCommit, ourCommit);
    final frame = await framesOfType(BattleMsgType.meleeCommit).first;
    return frame.payload;
  }

  @override
  Future<Uint8List> exchangeMeleeReveal(Uint8List ourReveal) async {
    send(BattleMsgType.meleeReveal, ourReveal);
    final frame = await framesOfType(BattleMsgType.meleeReveal).first;
    return frame.payload;
  }

  // ── Post-resolution free-move commit-reveal ─────────────────────────────────

  @override
  Future<Uint8List> exchangeFreeMoveCommit(Uint8List ourCommit) async {
    send(BattleMsgType.freeMoveCommit, ourCommit);
    final frame = await framesOfType(BattleMsgType.freeMoveCommit).first;
    return frame.payload;
  }

  @override
  Future<Uint8List> exchangeFreeMoveReveal(Uint8List ourReveal) async {
    send(BattleMsgType.freeMoveReveal, ourReveal);
    final frame = await framesOfType(BattleMsgType.freeMoveReveal).first;
    return frame.payload;
  }

  // ── Per-turn action commit-reveal ──────────────────────────────────────────

  /// Both sides commit their action (spell / haymaker / pass) simultaneously.
  /// Returns the peer's action commit (32-byte SHA-256 hash).
  @override
  Future<Uint8List> exchangeActionCommit(Uint8List ourCommit) async {
    send(BattleMsgType.actionCommit, ourCommit);
    final frame = await framesOfType(BattleMsgType.actionCommit).first;
    return frame.payload;
  }

  /// Both sides reveal their action (nonce ‖ action_bytes) simultaneously.
  /// Caller verifies SHA-256(action_bytes ‖ nonce) == received commit.
  @override
  Future<Uint8List> exchangeActionReveal(Uint8List ourReveal) async {
    send(BattleMsgType.actionReveal, ourReveal);
    final frame = await framesOfType(BattleMsgType.actionReveal).first;
    return frame.payload;
  }

  /// Both sides simultaneously declare any pending delayed spells firing this
  /// turn. Payload format: [count:1][commitment:32, q:2, r:2, delay:1, nonce:16
  /// per spell]. Send [0x00] if nothing fires this turn.
  @override
  Future<Uint8List> exchangeDelayedSpellReveals(Uint8List ourReveals) async {
    send(BattleMsgType.delayedSpellReveal, ourReveals);
    final frame = await framesOfType(BattleMsgType.delayedSpellReveal).first;
    return frame.payload;
  }

  // ── Divination scrying pattern (§13b) ──────────────────────────────────────

  @override
  Future<Uint8List> exchangeScryKey(Uint8List ourFrame) async {
    send(BattleMsgType.scryKey, ourFrame);
    final frame = await framesOfType(BattleMsgType.scryKey).first;
    return frame.payload;
  }

  @override
  Future<Uint8List> exchangeScryOpen(Uint8List ourFrame) async {
    send(BattleMsgType.scryOpen, ourFrame);
    final frame = await framesOfType(BattleMsgType.scryOpen).first;
    return frame.payload;
  }

  // ── Divination (Water) spell-list reveal ───────────────────────────────────

  @override
  Future<Uint8List> exchangeSpellRevealKey(Uint8List ourFrame) async {
    send(BattleMsgType.spellRevealKey, ourFrame);
    final frame = await framesOfType(BattleMsgType.spellRevealKey).first;
    return frame.payload;
  }

  @override
  Future<Uint8List> exchangeSpellRevealOpen(Uint8List ourFrame) async {
    send(BattleMsgType.spellRevealOpen, ourFrame);
    final frame = await framesOfType(BattleMsgType.spellRevealOpen).first;
    return frame.payload;
  }

  @override
  Future<Uint8List?> exchangeForcedReveal(Uint8List ourFrame) async {
    send(BattleMsgType.forcedReveal, ourFrame);
    final frame = await framesOfType(BattleMsgType.forcedReveal).first;
    return frame.payload;
  }

  // ── Mid-resolution entropy refresh ─────────────────────────────────────────

  @override
  Future<Uint8List> refreshEntropy(String reason) async {
    final ourNonce = CommitRevealEntropy.generateNonce();
    final ourCommit = await CommitRevealEntropy.commit(ourNonce);

    // Commit phase — simultaneous, same protocol as turn-start nonce exchange.
    send(BattleMsgType.refreshEntropyCommit, ourCommit);
    final theirCommitFrame = await framesOfType(BattleMsgType.refreshEntropyCommit).first;

    // Reveal phase.
    send(BattleMsgType.refreshEntropyReveal, ourNonce);
    final theirRevealFrame = await framesOfType(BattleMsgType.refreshEntropyReveal).first;

    final jointEntropy = await CommitRevealEntropy.revealAndCombine(
      ourNonce: ourNonce,
      theirNonce: theirRevealFrame.payload,
      theirCommit: theirCommitFrame.payload,
    );
    if (jointEntropy == null) {
      sendForfeit('withheld_refresh_reveal:$reason');
      throw StateError('peer withheld entropy refresh ($reason) — match forfeit');
    }
    return jointEntropy;
  }

  // ── Per-turn state hash (lockstep seam) ─────────────────────────────────────

  /// Send our state hash and receive the peer's; returns peer hash.
  ///
  /// Signing is stubbed — the hash exchange is real. See BATTLE_PROTOCOL.md §6.
  @override
  Future<Uint8List> exchangeStateHash(Uint8List ourHash) async {
    // TODO(battle): prepend Ed25519 signature to ourHash before sending;
    //   depends on identity module (lib/identity/identity.dart).
    send(BattleMsgType.stateHash, ourHash);
    final frame = await framesOfType(BattleMsgType.stateHash).first;
    return frame.payload;
  }

  // ── Match control ───────────────────────────────────────────────────────────

  @override
  void sendForfeit(String reason) =>
      send(BattleMsgType.forfeit, Uint8List.fromList(utf8.encode(reason)));


  void sendMatchEnd({required String winningTeamId, required String finalStateHashHex}) {
    final body = jsonEncode({'winningTeamId': winningTeamId, 'finalStateHash': finalStateHashHex});
    send(BattleMsgType.matchEnd, Uint8List.fromList(utf8.encode(body)));
  }

  /// Exchanges our signed [MatchOutcome] for the peer's (MASTER_APPRENTICE_
  /// PLAN.md §4.2). Both sides send simultaneously — safe because, unlike a
  /// wall-clock timestamp, every field of [mine] is a pure function of
  /// state the per-turn lockstep already agreed on (see [MatchOutcome]'s doc
  /// comment). This method only transports the exchange; the caller is
  /// responsible for validating the returned [SignedMatchOutcome] before
  /// trusting it — at minimum: signature valid, its raw pubkey binds to the
  /// ALREADY-AUTHENTICATED peer identity (from [exchangeIdentityAuth], never
  /// a bare claim here), its `outcome` fields equal [mine]'s, and its
  /// `signerPubkeyHex` names the OTHER party to the match (not our own).
  /// [MatchOutcomeRecord.isFullyValid] checks the signature/party shape of
  /// the combined pair; matching field-for-field against [mine] is the
  /// caller's job since this method has no opinion on what "ours" should be.
  Future<SignedMatchOutcome> exchangeMatchOutcome(SignedMatchOutcome mine) async {
    send(
      BattleMsgType.matchResultSig,
      Uint8List.fromList(utf8.encode(jsonEncode(mine.toJson()))),
    );
    final frame = await framesOfType(BattleMsgType.matchResultSig).first;
    return SignedMatchOutcome.fromJson(
      jsonDecode(utf8.decode(frame.payload)) as Map<String, dynamic>,
    );
  }

  Future<void> close() async {
    await _sub.cancel();
    await _reader.close();
  }
}
