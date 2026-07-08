// SPDX-License-Identifier: GPL-3.0-or-later
//
// solo_battle_session.dart — BattleTurnSession stub for single-player practice.
//
// There is no peer, so all commit-reveal exchanges are self-consistent fiction:
// the "peer" always passes, stays put, and echoes back the state hash so the
// TurnLoop's verification steps pass without network I/O.
//
// Test-lab exception: when [dummyAutoCast] is set (Spell Test Lab only —
// regular Solo Practice never sets it, so the dummy there is unaffected), the
// "peer" (target dummy) casts [dummyCastFormula] at [dummyCastTarget] every
// turn instead of passing. This hand-encodes TurnLoop's [0x01] spell-action
// wire format (see the wire spec comment atop turn_loop.dart) because
// TurnLoop._encodeAction is private to that file — keep the two in sync if
// the wire format ever changes. No proof tail or sorcerer suffix is emitted:
// solo mode's TurnLoop never verifies peer proofs (verifyProof is null) and
// the Test Lab never enables sorcerer mode.

import 'dart:convert' show utf8;
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:rune_duel/engine/hex_grid.dart';

import '../engine/commit_reveal.dart';
import 'battle_session.dart';

class SoloBattleSession implements BattleTurnSession {
  SoloBattleSession({
    this.dummyAutoCast = false,
    this.dummyCastTarget,
    this.dummyCastFormula = const ['fire', 'fire', 'fire'],
  });

  /// Spell Test Lab only: when true and [dummyCastTarget] is non-null, the
  /// dummy casts [dummyCastFormula] at that tile every turn instead of
  /// passing.
  final bool dummyAutoCast;
  final HexCoord? dummyCastTarget;
  final List<String> dummyCastFormula;

  /// Sentinel commitment for the scripted dummy cast. Never proof-verified in
  /// solo mode, so this only needs to be 32 bytes — not a real Poseidon2 grid
  /// commitment (CLAUDE.md invariant 1: never reimplement that in Dart).
  static final Uint8List _dummyCommitment = Uint8List.fromList(List.filled(32, 0xFE));

  // Scratch storage for one-turn peer data; refreshed each call.
  Uint8List _peerActionNonce = Uint8List(16);
  Uint8List _peerActionBytes = Uint8List.fromList([0x00]);
  Uint8List _peerMoveNonce = Uint8List(16);
  Uint8List _peerMoveBytes = Uint8List.fromList([0x00]); // empty path: count=0

  // ── Entropy ─────────────────────────────────────────────────────────────────

  @override
  Future<({Uint8List theirNonce, Uint8List theirCommit})> exchangeNonce({
    required Uint8List ourCommit,
    required Uint8List ourNonce,
  }) async {
    final nonce = CommitRevealEntropy.generateNonce();
    final commitBytes = await CommitRevealEntropy.commit(nonce);
    return (theirNonce: nonce, theirCommit: commitBytes);
  }

  // ── Action commit-reveal ─────────────────────────────────────────────────────

  @override
  Future<Uint8List> exchangeActionCommit(Uint8List ourCommit) async {
    // Peer: PassAction = [0x00], nonce = 16 zero bytes — unless the Test Lab
    // has scripted the dummy to cast this turn.
    // Commit format matches _verifyReveal: SHA-256(actionBytes ‖ nonce16).
    final target = dummyCastTarget;
    _peerActionNonce = Uint8List(16);
    _peerActionBytes = (dummyAutoCast && target != null)
        ? _encodeDummySpellCast(target, dummyCastFormula)
        : Uint8List.fromList([0x00]);
    final hash = await Sha256().hash(
      Uint8List.fromList([..._peerActionBytes, ..._peerActionNonce]),
    );
    return Uint8List.fromList(hash.bytes);
  }

  @override
  Future<Uint8List> exchangeActionReveal(Uint8List ourReveal) async {
    // Reveal format: nonce(16) ‖ actionBytes — matches _verifyReveal.
    return Uint8List.fromList([..._peerActionNonce, ..._peerActionBytes]);
  }

  /// Encodes TurnLoop's [0x01] spell-cast wire format for the scripted dummy
  /// cast: [0x01][commit:32][t:2][q:2][r:2][formula_len:2][formula_utf8:N].
  static Uint8List _encodeDummySpellCast(HexCoord target, List<String> formula) {
    final buf = BytesBuilder();
    buf.addByte(0x01);
    buf.add(_dummyCommitment);
    buf.add(_be2(1)); // t: arbitrary — unused (no cert/proof path in solo mode)
    buf.add(_encodeCoord(target));
    final formulaBytes = utf8.encode(formula.join(','));
    buf.add(_be2(formulaBytes.length));
    buf.add(formulaBytes);
    return buf.toBytes();
  }

  static Uint8List _be2(int v) => Uint8List(2)
    ..[0] = (v >> 8) & 0xFF
    ..[1] = v & 0xFF;

  static Uint8List _encodeCoord(HexCoord h) => Uint8List(4)
    ..[0] = (h.q >> 8) & 0xFF
    ..[1] = h.q & 0xFF
    ..[2] = (h.r >> 8) & 0xFF
    ..[3] = h.r & 0xFF;

  // ── Move commit-reveal ───────────────────────────────────────────────────────

  @override
  Future<Uint8List> exchangeMoveCommit(Uint8List ourCommit) async {
    // Peer stays put: empty path (count=0).
    _peerMoveNonce = Uint8List(16);
    _peerMoveBytes = Uint8List.fromList([0x00]);
    final hash = await Sha256().hash(
      Uint8List.fromList([..._peerMoveBytes, ..._peerMoveNonce]),
    );
    return Uint8List.fromList(hash.bytes);
  }

  @override
  Future<Uint8List> exchangeMoveReveal(Uint8List ourReveal) async {
    return Uint8List.fromList([..._peerMoveNonce, ..._peerMoveBytes]);
  }

  // ── Delayed spells ───────────────────────────────────────────────────────────

  @override
  Future<Uint8List> exchangeDelayedSpellReveals(Uint8List ourReveals) async {
    return Uint8List.fromList([0x00]); // peer fires nothing
  }

  // ── State hash ───────────────────────────────────────────────────────────────

  @override
  Future<Uint8List> exchangeStateHash(Uint8List ourHash) async {
    return ourHash; // no peer to disagree; echo back so equality check passes
  }

  // ── Entropy refresh ──────────────────────────────────────────────────────────

  @override
  Future<Uint8List> refreshEntropy(String reason) async {
    // Solo: no peer to coordinate with. Derive fresh entropy from a new
    // secure nonce so each refresh call produces a distinct seed.
    final nonce = CommitRevealEntropy.generateNonce();
    final commit = await CommitRevealEntropy.commit(nonce);
    return (await CommitRevealEntropy.revealAndCombine(
      ourNonce: Uint8List(32), // zeros XOR nonce = nonce
      theirNonce: nonce,
      theirCommit: commit,
    ))!;
  }

  // ── Control ──────────────────────────────────────────────────────────────────

  @override
  void sendForfeit(String reason) {
    // no-op — no peer to forfeit to
  }
}
