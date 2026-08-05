// SPDX-License-Identifier: GPL-3.0-or-later
//
// peer_forfeit_test.dart — BattleSession.peerForfeit, the receive side of
// sendForfeit.
//
// Regression: BattleMsgType.forfeit (0x40) was write-only. Every forfeit
// condition in the engine is one-sided — the device that detects it throws out
// of runTurn and stops — so with nothing listening for the frame, the peer
// (which sees nothing wrong) sat waiting on an exchange the other device had
// already abandoned. That is what a real LAN test shows as a "desync": one
// device dead with an error dialog, one still in the match.
//
// Two real BattleSession instances over InMemoryTransport, no mocks — the same
// wire-level approach as battle_session_avatar_id_test.dart.

import 'dart:async' show unawaited;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/battle/networking/battle_session.dart';
import 'package:rune_duel/protocol/in_memory_transport.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final matchId = Uint8List.fromList(List.generate(16, (i) => i));

  test('a forfeit sent by one side completes the other side\'s peerForfeit',
      () async {
    final (transportA, transportB) = InMemoryTransport.pair();
    final sessionA = BattleSession(transportA, matchId);
    final sessionB = BattleSession(transportB, matchId);

    // B is listening before A sends — the ordinary case, where the battle
    // screen subscribed at initState and the violation happens mid-match.
    final heard = sessionB.peerForfeit;
    sessionA.sendForfeit('unauthorized_spell:0xabc');

    expect(await heard, 'unauthorized_spell:0xabc');

    await transportA.disconnect();
    await transportB.disconnect();
  });

  test('a forfeit that arrives before anyone subscribes is not dropped',
      () async {
    final (transportA, transportB) = InMemoryTransport.pair();
    final sessionA = BattleSession(transportA, matchId);
    final sessionB = BattleSession(transportB, matchId);

    // The frame lands first; B only reads peerForfeit afterwards. This is the
    // ordering that made the bug survivable-looking in manual testing — a
    // forfeit during the handshake, before the battle screen even exists.
    // BattleFrameReader.framesOfType is queue-backed, so the frame is held.
    sessionA.sendForfeit('battle_protocol_mismatch');
    await Future<void>.delayed(Duration.zero);

    expect(await sessionB.peerForfeit, 'battle_protocol_mismatch');

    await transportA.disconnect();
    await transportB.disconnect();
  });

  test('peerForfeit does not complete when no forfeit is sent', () async {
    final (transportA, transportB) = InMemoryTransport.pair();
    final sessionA = BattleSession(transportA, matchId);
    final sessionB = BattleSession(transportB, matchId);

    var completed = false;
    unawaited(sessionB.peerForfeit.then((_) => completed = true));

    // An unrelated exchange must not be mistaken for a forfeit.
    await Future.wait([
      sessionA.exchangeAvatarId('fighter_f_01'),
      sessionB.exchangeAvatarId('mage_m_01'),
    ]);
    await Future<void>.delayed(Duration.zero);

    expect(completed, isFalse);

    await transportA.disconnect();
    await transportB.disconnect();
  });
}
