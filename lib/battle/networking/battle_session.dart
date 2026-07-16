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

import '../../protocol/transport.dart';
import '../engine/book_commitment.dart';
import '../engine/commit_reveal.dart';
import '../models/match_config.dart';
import 'battle_wire.dart';
import 'match_discovery.dart';

// ── TurnLoop exchange interface ───────────────────────────────────────────────

/// Abstract interface for the per-turn commit-reveal exchanges that [TurnLoop]
/// needs. Implemented by [BattleSession] (network) and [SoloBattleSession]
/// (local solo stub).
abstract class BattleTurnSession {
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

  /// Resolution-phase melee commit-reveal: after movement has resolved (so
  /// both final positions are known), each player secretly commits an
  /// optional adjacent melee target, then both reveal simultaneously. Mirrors
  /// [exchangeMoveCommit]/[exchangeMoveReveal] exactly. Independent of the
  /// main-phase action — a player may cast a spell AND melee the same turn.
  Future<Uint8List> exchangeMeleeCommit(Uint8List ourCommit);
  Future<Uint8List> exchangeMeleeReveal(Uint8List ourReveal);

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

  /// All incoming battle frames, broadcast.
  Stream<BattleFrame> get frames => _reader.frames;

  /// Filtered view: only frames of [type].
  Stream<BattleFrame> framesOfType(BattleMsgType type) =>
      frames.where((f) => f.type == type);

  void send(BattleMsgType type, Uint8List payload) {
    _transport.send(BattleFrame(type, payload).encode());
  }

  // ── Setup exchanges ─────────────────────────────────────────────────────────

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

  Future<void> close() async {
    await _sub.cancel();
    await _reader.close();
  }
}
