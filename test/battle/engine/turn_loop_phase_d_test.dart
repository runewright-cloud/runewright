// SPDX-License-Identifier: GPL-3.0-or-later
//
// turn_loop_phase_d_test.dart — Phase D: per-turn signed state hash
// (BATTLE_AUTH_PLAN.md §6, LAN_BATTLE_WIREUP_PLAN.md §4 item 4). Covers the
// two properties that matter: a validly signed hash round-trips through a
// real turn with no complaint, and a tampered signature forfeits + throws
// rather than silently accepting (CLAUDE.md fail-closed quality bar).
//
// The tampering test needs to corrupt only the state-hash exchange while
// every other exchange in the turn proceeds honestly — _TamperingSession
// wraps a real BattleSession and forwards everything except
// exchangeStateHash, which it flips a bit in after the real exchange
// completes (so the underlying commit-reveal machinery is untouched; only
// the final signed payload is corrupted, exactly modeling a
// bit-flipped-in-transit or forged peer response).

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/battle/engine/turn_loop.dart';
import 'package:rune_duel/battle/models/battle_state.dart';
import 'package:rune_duel/battle/models/hex_battlefield.dart' show Battlefield;
import 'package:rune_duel/battle/models/match_config.dart';
import 'package:rune_duel/battle/models/wizard_avatar.dart';
import 'package:rune_duel/battle/networking/battle_session.dart';
import 'package:rune_duel/engine/hex_grid.dart';
import 'package:rune_duel/identity/identity.dart';
import 'package:rune_duel/protocol/in_memory_transport.dart';
import 'package:rune_duel/spells/spell_permission.dart';
import 'package:rune_duel/src/rust/frb_generated.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await RustLib.init();
  });

  BattleState makeState() {
    final battlefield = Battlefield();
    const posA = HexCoord(0, 0);
    const posB = HexCoord(2, -2);
    battlefield.occupancy['player_a'] = posA;
    battlefield.occupancy['player_b'] = posB;
    return BattleState(
      config: const MatchConfig(),
      avatars: [
        WizardAvatar(
          playerId: 'player_a',
          ownerPubkeyHex: '0x${'00' * 32}',
          hp: 24,
          mana: 100,
          maxMana: 100,
          position: posA,
          teamId: 'team_a',
          baseSpellRange: 3,
        ),
        WizardAvatar(
          playerId: 'player_b',
          ownerPubkeyHex: '0x${'00' * 32}',
          hp: 24,
          mana: 100,
          maxMana: 100,
          position: posB,
          teamId: 'team_b',
          baseSpellRange: 3,
        ),
      ],
      teams: [
        const Team(id: 'team_a', playerIds: ['player_a']),
        const Team(id: 'team_b', playerIds: ['player_b']),
      ],
      battlefield: battlefield,
    );
  }

  test('a validly signed state hash round-trips through a real turn with no '
      'complaint', () async {
    final identityA = await Identity.ephemeral();
    final identityB = await Identity.ephemeral();
    final rawPubkeyA = identityA.publicKeyBytes;
    final rawPubkeyB = identityB.publicKeyBytes;
    final matchId = Uint8List.fromList(List.generate(16, (i) => i));
    final (transportA, transportB) = InMemoryTransport.pair();
    final sessionA = BattleSession(transportA, matchId);
    final sessionB = BattleSession(transportB, matchId);

    final stateA = makeState();
    final stateB = makeState();
    final loopA = TurnLoop(
      state: stateA,
      session: sessionA,
      localPlayerId: 'player_a',
      matchId: matchId,
      signMessage: identityA.sign,
      peerRawPubkey: rawPubkeyB,
    );
    final loopB = TurnLoop(
      state: stateB,
      session: sessionB,
      localPlayerId: 'player_b',
      matchId: matchId,
      signMessage: identityB.sign,
      peerRawPubkey: rawPubkeyA,
    );

    await Future.wait([
      loopA.runTurn(TurnInput(action: PassAction())),
      loopB.runTurn(TurnInput(action: PassAction())),
    ]);

    expect(stateA.toCanonicalBytes(), equals(stateB.toCanonicalBytes()));

    await transportA.disconnect();
    await transportB.disconnect();
  });

  test(
      'a tampered state-hash signature forfeits and throws — never silently '
      'accepted', () async {
    final identityA = await Identity.ephemeral();
    final identityB = await Identity.ephemeral();
    final matchId = Uint8List.fromList(List.generate(16, (i) => i));
    final (transportA, transportB) = InMemoryTransport.pair();
    final sessionA = BattleSession(transportA, matchId);
    final sessionB = BattleSession(transportB, matchId);

    // Wrap A's OWN session: exchangeStateHash's return value is what A
    // perceives it received from B, so tampering it here corrupts A's view
    // of B's (genuinely honest) signed reply — modeling either an in-
    // transit bit-flip or a dishonest peer, either way something A's own
    // verification must catch. B's session is untouched and never sees
    // anything wrong (it receives A's genuine hash), so B's runTurn
    // completes normally; only A's throws.
    final tamperingSessionForA = _TamperingSession(sessionA);

    final stateA = makeState();
    final stateB = makeState();
    final loopA = TurnLoop(
      state: stateA,
      session: tamperingSessionForA,
      localPlayerId: 'player_a',
      matchId: matchId,
      signMessage: identityA.sign,
      peerRawPubkey: identityB.publicKeyBytes,
    );
    final loopB = TurnLoop(
      state: stateB,
      session: sessionB,
      localPlayerId: 'player_b',
      matchId: matchId,
      signMessage: identityB.sign,
      peerRawPubkey: identityA.publicKeyBytes,
    );

    await expectLater(
      Future.wait([
        loopA.runTurn(TurnInput(action: PassAction())),
        loopB.runTurn(TurnInput(action: PassAction())),
      ]),
      throwsA(isA<StateError>()),
    );

    await transportA.disconnect();
    await transportB.disconnect();
  });
}

/// Forwards every [BattleTurnSession] method to [_inner] (a real
/// [BattleSession]) except [exchangeStateHash]. That method's return value
/// is what the caller (TurnLoop) perceives as "the peer's bytes" — the
/// underlying `_inner.exchangeStateHash(ourHash)` call still genuinely
/// sends `ourHash` out and reads the peer's real reply, so wrapping the
/// *sending* side's session corrupts only that side's own perception of
/// what it received, without touching what actually goes out on the wire.
/// Flips a bit inside the signature portion (byte 40, well past the
/// 32-byte hash) so only the signature is corrupted, not the hash itself —
/// proving the forfeit comes from signature verification, not the pre-
/// existing hash-mismatch path.
class _TamperingSession implements BattleTurnSession {
  _TamperingSession(this._inner);
  final BattleTurnSession _inner;

  @override
  Future<Uint8List> exchangeStateHash(Uint8List ourHash) async {
    final peerBytes = await _inner.exchangeStateHash(ourHash);
    if (peerBytes.length < 96) return peerBytes;
    final tampered = Uint8List.fromList(peerBytes);
    tampered[40] ^= 0xFF;
    return tampered;
  }

  @override
  Future<AuthenticatedPeer> exchangeIdentityAuth({
    required Identity localIdentity,
    required Uint8List matchId,
  }) =>
      _inner.exchangeIdentityAuth(localIdentity: localIdentity, matchId: matchId);

  @override
  Future<List<SpellPermission>> exchangeSpellPermissions(
    List<SpellPermission> ours, {
    required String peerOwnerPubkeyHex,
  }) =>
      _inner.exchangeSpellPermissions(ours, peerOwnerPubkeyHex: peerOwnerPubkeyHex);

  @override
  Future<({Uint8List theirNonce, Uint8List theirCommit})> exchangeNonce({
    required Uint8List ourCommit,
    required Uint8List ourNonce,
  }) =>
      _inner.exchangeNonce(ourCommit: ourCommit, ourNonce: ourNonce);

  @override
  Future<Uint8List> exchangeActionCommit(Uint8List ourCommit) =>
      _inner.exchangeActionCommit(ourCommit);

  @override
  Future<Uint8List> exchangeActionReveal(Uint8List ourReveal) =>
      _inner.exchangeActionReveal(ourReveal);

  @override
  Future<Uint8List> exchangeMoveCommit(Uint8List ourCommit) =>
      _inner.exchangeMoveCommit(ourCommit);

  @override
  Future<Uint8List> exchangeMoveReveal(Uint8List ourReveal) =>
      _inner.exchangeMoveReveal(ourReveal);

  @override
  Future<Uint8List> exchangeDelayedSpellReveals(Uint8List ourReveals) =>
      _inner.exchangeDelayedSpellReveals(ourReveals);

  @override
  Future<Uint8List> exchangeArtifactActivationCommit(Uint8List ourCommit) =>
      _inner.exchangeArtifactActivationCommit(ourCommit);

  @override
  Future<Uint8List> exchangeArtifactActivationReveal(Uint8List ourReveal) =>
      _inner.exchangeArtifactActivationReveal(ourReveal);

  @override
  Future<Uint8List> exchangeMeleeCommit(Uint8List ourCommit) =>
      _inner.exchangeMeleeCommit(ourCommit);

  @override
  Future<Uint8List> exchangeMeleeReveal(Uint8List ourReveal) =>
      _inner.exchangeMeleeReveal(ourReveal);

  @override
  Future<Uint8List> exchangeFreeMoveCommit(Uint8List ourCommit) =>
      _inner.exchangeFreeMoveCommit(ourCommit);

  @override
  Future<Uint8List> exchangeFreeMoveReveal(Uint8List ourReveal) =>
      _inner.exchangeFreeMoveReveal(ourReveal);

  @override
  Future<Uint8List> exchangeScryKey(Uint8List ourFrame) => _inner.exchangeScryKey(ourFrame);

  @override
  Future<Uint8List> exchangeScryOpen(Uint8List ourFrame) => _inner.exchangeScryOpen(ourFrame);

  @override
  Future<Uint8List> exchangeSpellRevealKey(Uint8List ourFrame) =>
      _inner.exchangeSpellRevealKey(ourFrame);

  @override
  Future<Uint8List> exchangeSpellRevealOpen(Uint8List ourFrame) =>
      _inner.exchangeSpellRevealOpen(ourFrame);

  @override
  Future<Uint8List?> exchangeForcedReveal(Uint8List ourFrame) =>
      _inner.exchangeForcedReveal(ourFrame);

  @override
  Future<Uint8List> refreshEntropy(String reason) => _inner.refreshEntropy(reason);

  @override
  void sendForfeit(String reason) => _inner.sendForfeit(reason);
}
