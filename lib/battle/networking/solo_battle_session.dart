// SPDX-License-Identifier: GPL-3.0-or-later
//
// solo_battle_session.dart — BattleTurnSession stub for single-player practice.
//
// There is no peer, so all commit-reveal exchanges are self-consistent fiction:
// the "peer" always passes, stays put, and echoes back the state hash so the
// TurnLoop's verification steps pass without network I/O.
//
// dummyAutoCast exception: when [dummyAutoCast] is set (both Solo Practice
// and the Spell Test Lab do), the "peer" (target dummy) casts
// [dummyCastFormula] at [dummyCastTarget] every turn instead of passing.
// This hand-encodes TurnLoop's [0x01] spell-action wire format (see the wire
// spec comment atop turn_loop.dart) because TurnLoop._encodeAction is
// private to that file — keep the two in sync if the wire format ever
// changes. No proof tail or sorcerer suffix is emitted: solo mode's TurnLoop
// never verifies peer proofs (verifyProof is null) and neither solo surface
// enables sorcerer mode.
//
// The scrying pattern (§13b) is the one exchange where the dummy's fictional
// answer must be a *real* cryptographic opening, not a constant stub: if the
// local player casts Airy Scrying Pool on the dummy, TurnLoop expects
// exchangeScryOpen to hand back an AEAD-encrypted opening of the dummy's
// actual committed target, addressed to the ephemeral key TurnLoop sent via
// exchangeScryKey — see exchangeScryOpen below. Everything else about the
// dummy (it never scries the local player) stays a constant [0x00].

import 'dart:convert' show utf8;
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:rune_duel/engine/hex_grid.dart';

import '../../identity/identity.dart';
import '../../spells/spell_permission.dart';
import '../engine/commit_reveal.dart';
import '../models/battle_state.dart';
import 'battle_session.dart';

class SoloBattleSession implements BattleTurnSession {
  SoloBattleSession({
    required this.state,
    this.dummyAutoCast = false,
    this.dummyCastTarget,
    this.dummyCastFormula = const ['fire', 'fire', 'fire'],
  });

  /// Shared reference to the same [BattleState] the owning [TurnLoop] reads
  /// from — needed so [exchangeScryOpen] can derive the same per-turn HKDF
  /// info tag ([TurnLoop._scryHkdfInfo]) the loop will independently
  /// recompute when decrypting our reply. Solo sessions never set a
  /// [TurnLoop.matchId] (see that field's doc comment), so the tag here
  /// omits it to match.
  final BattleState state;

  /// When true and [dummyCastTarget] is non-null, the dummy casts
  /// [dummyCastFormula] at that tile every turn instead of passing.
  final bool dummyAutoCast;
  final HexCoord? dummyCastTarget;
  final List<String> dummyCastFormula;

  /// Sentinel commitment for the scripted dummy cast. Never proof-verified in
  /// solo mode, so this only needs to be 32 bytes — not a real Poseidon2 grid
  /// commitment (CLAUDE.md invariant 1: never reimplement that in Dart).
  static final Uint8List _dummyCommitment = Uint8List.fromList(List.filled(32, 0xFE));

  // Scratch storage for one-turn peer data; refreshed each call.
  Uint8List _peerActionSaltA = Uint8List(16);
  Uint8List _peerActionSaltB = Uint8List(16);
  Uint8List _peerActionBytes = Uint8List.fromList([0x00]);
  Uint8List _peerMoveNonce = Uint8List(16);
  Uint8List _peerMoveBytes =
      Uint8List.fromList([0x00, 0x00, 0x00]); // not dashing, not meditating, count=0
  Uint8List _peerMeleeNonce = Uint8List(16);
  Uint8List _peerMeleeBytes = Uint8List.fromList([0x00]); // no melee target
  Uint8List _peerArtifactNonce = Uint8List(16);
  Uint8List _peerArtifactBytes = Uint8List.fromList([0x00]); // no activation
  Uint8List _peerFreeMoveNonce = Uint8List(16);
  Uint8List _peerFreeMoveBytes = Uint8List.fromList([0x00]); // no free move

  // ── Identity authentication (BATTLE_AUTH_PLAN.md §3) ────────────────────────
  //
  // There is no real peer to authenticate in solo/practice play, so both
  // exchanges are stubs: no signature is checked or produced, and the
  // sentinel AuthenticatedPeer.none carries an empty owner_pubkey that can
  // never match a real spell's owner (TurnLoop skips cast-authorization and
  // state-hash-signing checks when the authenticated peer is this sentinel).

  @override
  Future<AuthenticatedPeer> exchangeIdentityAuth({
    required Identity localIdentity,
    required Uint8List matchId,
  }) async => AuthenticatedPeer.none;

  @override
  Future<List<SpellPermission>> exchangeSpellPermissions(
    List<SpellPermission> ours, {
    required String peerOwnerPubkeyHex,
  }) async => const <SpellPermission>[];

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
    // Peer: PassAction = [0x00], salts = 16 zero bytes each — unless the Test
    // Lab has scripted the dummy to cast this turn.
    // Commit format matches TurnLoop._splitActionCommit (keep in sync — see
    // that method's doc comment for the split-leaf/salted-Merkle scheme):
    // SHA-256( H(remainder ‖ saltA) ‖ H(target ‖ saltB) ).
    final target = dummyCastTarget;
    _peerActionSaltA = Uint8List(16);
    _peerActionSaltB = Uint8List(16);
    _peerActionBytes = (dummyAutoCast && target != null)
        ? _encodeDummySpellCast(target, dummyCastFormula)
        : Uint8List.fromList([0x00]);
    return _splitActionCommit(_peerActionBytes, _peerActionSaltA, _peerActionSaltB);
  }

  @override
  Future<Uint8List> exchangeActionReveal(Uint8List ourReveal) async {
    // Reveal format: saltA(16) ‖ saltB(16) ‖ actionBytes — matches
    // TurnLoop._verifyActionReveal.
    return Uint8List.fromList(
        [..._peerActionSaltA, ..._peerActionSaltB, ..._peerActionBytes]);
  }

  // ── Divination scrying pattern (§13b) ────────────────────────────────────
  //
  // The dummy never casts a Divination spell, so the "dummy scries us"
  // direction is always "no active scry this turn." The "we scry the dummy"
  // direction is real: if the local player has an active outgoing
  // DivinationLink on the dummy, TurnLoop sends its ephemeral X25519 pubkey
  // via exchangeScryKey, then expects exchangeScryOpen to answer with an
  // AEAD-encrypted opening of the dummy's actually-committed target —
  // mirroring TurnLoop._exchangeScryOpenings' "incomingLink != null" branch,
  // but keyed off the dummy's real action/salts tracked above instead of a
  // second player's.

  Uint8List _ourScryKeyFrame = Uint8List.fromList([0x00]);

  @override
  Future<Uint8List> exchangeScryKey(Uint8List ourFrame) async {
    _ourScryKeyFrame = ourFrame; // remembered for exchangeScryOpen, below
    return Uint8List.fromList([0x00]);
  }

  @override
  Future<Uint8List> exchangeScryOpen(Uint8List ourFrame) async {
    final keyFrame = _ourScryKeyFrame;
    if (keyFrame.length != 33 || keyFrame[0] != 0x01) {
      return Uint8List.fromList([0x00]); // not scrying the dummy this turn
    }
    final x25519 = X25519();
    final peerEkPub = SimplePublicKey(keyFrame.sublist(1), type: KeyPairType.x25519);
    final vk = await x25519.newKeyPair();
    final vkPub = await vk.extractPublicKey();
    final shared = await x25519.sharedSecretKey(keyPair: vk, remotePublicKey: peerEkPub);
    final derived = await Hkdf(hmac: Hmac.sha256(), outputLength: 32)
        .deriveKey(secretKey: shared, info: _scryHkdfInfo());

    final (targetBytes, remainder) = _splitActionTarget(_peerActionBytes);
    final leafA = await _leafHash(remainder, _peerActionSaltA);
    final opening =
        Uint8List.fromList([...targetBytes, ..._peerActionSaltB, ...leafA]);
    final cipher = Xchacha20.poly1305Aead();
    final nonce = cipher.newNonce();
    final box = await cipher.encrypt(opening, secretKey: derived, nonce: nonce);
    return Uint8List.fromList([0x01, ...vkPub.bytes, ...box.concatenation()]);
  }

  /// Duplicates TurnLoop._scryHkdfInfo (private to that file, and matchId is
  /// always null for solo sessions — see [state]'s doc comment) — keep in
  /// sync if that derivation ever changes.
  Uint8List _scryHkdfInfo() => Uint8List.fromList([
        ...utf8.encode('RWSCRY1'),
        ..._be4(state.turnNumber),
      ]);

  // ── Divination (Water) spell-list reveal ─────────────────────────────────
  //
  // Unlike the Air scry pattern, the dummy has no modeled chapter — only a
  // single scripted [dummyCastFormula], not a spell list — and solo mode's
  // TurnLoop never carries a peerBookRoot to verify a reveal against (see
  // battle_screen.dart's peerBookRoot, always null for solo/practice
  // sessions). Both directions are honest stubs: the dummy never has spells
  // to reveal, so casting Watery Scrying Pool on it in solo practice shows
  // an empty reveal, same as "the dummy never melees" below.

  @override
  Future<Uint8List> exchangeSpellRevealKey(Uint8List ourFrame) async =>
      Uint8List.fromList([0x00]);

  @override
  Future<Uint8List> exchangeSpellRevealOpen(Uint8List ourFrame) async =>
      Uint8List.fromList([0x00]);

  /// No peer exists in solo/practice, so there is nothing to reveal and
  /// nothing to await. Null tells ForcedCast to resolve only the local
  /// player's picks — see that method's doc comment.
  @override
  Future<Uint8List?> exchangeForcedReveal(Uint8List ourFrame) async => null;

  static Uint8List _be4(int v) => Uint8List(4)
    ..[0] = (v >> 24) & 0xFF
    ..[1] = (v >> 16) & 0xFF
    ..[2] = (v >> 8) & 0xFF
    ..[3] = v & 0xFF;

  /// Duplicates TurnLoop._leafHash (private to that file) — keep in sync.
  static Future<Uint8List> _leafHash(Uint8List data, Uint8List salt) async {
    final h = await Sha256().hash(Uint8List.fromList([...data, ...salt]));
    return Uint8List.fromList(h.bytes);
  }

  /// Duplicates TurnLoop._splitActionTarget (private to that file) — keep in
  /// sync if the split-leaf scheme ever changes. [_splitActionCommit] below
  /// reimplements this inline for historical reasons; both must agree.
  static (Uint8List target, Uint8List remainder) _splitActionTarget(
      Uint8List actionBytes) {
    if (actionBytes.isEmpty) return (Uint8List(0), actionBytes);
    int? targetOffset;
    switch (actionBytes[0]) {
      case 0x01: targetOffset = 1 + 32 + 2;
    }
    if (targetOffset == null || actionBytes.length < targetOffset + 4) {
      return (Uint8List(0), actionBytes);
    }
    final target = actionBytes.sublist(targetOffset, targetOffset + 4);
    final remainder = Uint8List.fromList([
      ...actionBytes.sublist(0, targetOffset),
      ...actionBytes.sublist(targetOffset + 4),
    ]);
    return (Uint8List.fromList(target), remainder);
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

  /// Duplicates TurnLoop._splitActionCommit (private to that file) — keep in
  /// sync if the split-leaf scheme ever changes.
  static Future<Uint8List> _splitActionCommit(
      Uint8List actionBytes, Uint8List saltA, Uint8List saltB) async {
    int? targetOffset;
    if (actionBytes.isNotEmpty) {
      switch (actionBytes[0]) {
        case 0x01: targetOffset = 1 + 32 + 2;
        case 0x02: targetOffset = 1;
      }
    }
    final Uint8List target;
    final Uint8List remainder;
    if (targetOffset == null || actionBytes.length < targetOffset + 4) {
      target = Uint8List(0);
      remainder = actionBytes;
    } else {
      target = actionBytes.sublist(targetOffset, targetOffset + 4);
      remainder = Uint8List.fromList([
        ...actionBytes.sublist(0, targetOffset),
        ...actionBytes.sublist(targetOffset + 4),
      ]);
    }
    final leafA = await Sha256().hash(Uint8List.fromList([...remainder, ...saltA]));
    final leafB = await Sha256().hash(Uint8List.fromList([...target, ...saltB]));
    final root = await Sha256().hash(Uint8List.fromList([...leafA.bytes, ...leafB.bytes]));
    return Uint8List.fromList(root.bytes);
  }

  // ── Move commit-reveal ───────────────────────────────────────────────────────

  @override
  Future<Uint8List> exchangeMoveCommit(Uint8List ourCommit) async {
    // Peer stays put: not dashing, not meditating, empty path (count=0).
    // Matches TurnLoop._encodeMovePayload's [isDashing:1][meditateInMove:1]
    // [count:1] shape — keep in sync if that format ever changes.
    _peerMoveNonce = Uint8List(16);
    _peerMoveBytes = Uint8List.fromList([0x00, 0x00, 0x00]);
    final hash = await Sha256().hash(
      Uint8List.fromList([..._peerMoveBytes, ..._peerMoveNonce]),
    );
    return Uint8List.fromList(hash.bytes);
  }

  @override
  Future<Uint8List> exchangeMoveReveal(Uint8List ourReveal) async {
    return Uint8List.fromList([..._peerMoveNonce, ..._peerMoveBytes]);
  }

  // ── Phase 0 artifact-activation commit-reveal ───────────────────────────────
  //
  // The dummy carries no loadout, so it never spends an artifact.

  @override
  Future<Uint8List> exchangeArtifactActivationCommit(Uint8List ourCommit) async {
    _peerArtifactNonce = Uint8List(16);
    _peerArtifactBytes = Uint8List.fromList([0x00]);
    final hash = await Sha256().hash(
      Uint8List.fromList([..._peerArtifactBytes, ..._peerArtifactNonce]),
    );
    return Uint8List.fromList(hash.bytes);
  }

  @override
  Future<Uint8List> exchangeArtifactActivationReveal(Uint8List ourReveal) async {
    return Uint8List.fromList([..._peerArtifactNonce, ..._peerArtifactBytes]);
  }

  // ── Resolution-phase melee commit-reveal ────────────────────────────────────
  //
  // The dummy never melees.

  @override
  Future<Uint8List> exchangeMeleeCommit(Uint8List ourCommit) async {
    _peerMeleeNonce = Uint8List(16);
    _peerMeleeBytes = Uint8List.fromList([0x00]);
    final hash = await Sha256().hash(
      Uint8List.fromList([..._peerMeleeBytes, ..._peerMeleeNonce]),
    );
    return Uint8List.fromList(hash.bytes);
  }

  @override
  Future<Uint8List> exchangeMeleeReveal(Uint8List ourReveal) async {
    return Uint8List.fromList([..._peerMeleeNonce, ..._peerMeleeBytes]);
  }

  // ── Post-resolution free-move commit-reveal ─────────────────────────────────
  //
  // The dummy never holds an Air barrier, so it never earns a burst step; it
  // can be handed a Boost (cast a Watery Boost at it and the grant lands), but
  // like melee it always declines. [0x00] is TurnLoop._encodePath's empty path
  // — a zero-length run, i.e. "stand fast".

  @override
  Future<Uint8List> exchangeFreeMoveCommit(Uint8List ourCommit) async {
    _peerFreeMoveNonce = Uint8List(16);
    _peerFreeMoveBytes = Uint8List.fromList([0x00]);
    final hash = await Sha256().hash(
      Uint8List.fromList([..._peerFreeMoveBytes, ..._peerFreeMoveNonce]),
    );
    return Uint8List.fromList(hash.bytes);
  }

  @override
  Future<Uint8List> exchangeFreeMoveReveal(Uint8List ourReveal) async {
    return Uint8List.fromList([..._peerFreeMoveNonce, ..._peerFreeMoveBytes]);
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
