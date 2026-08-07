// SPDX-License-Identifier: GPL-3.0-or-later
//
// peer_connection_lost_test.dart — BattleSession.peerConnectionLost.
//
// Regression: BattleSession listened to the transport with no onDone and no
// onError, so a peer that vanished WITHOUT forfeiting told this device
// nothing at all. peerForfeit only covers the case where the other device is
// alive, diagnosed a problem, and had time to send a frame about it; it
// cannot cover the ordinary field failures — app backgrounded, screen locked
// until TCP resets, wizard walks out of Wi-Fi range, process killed. In all
// of those the surviving device stayed blocked forever on an exchange whose
// answer was never coming: no error, no message, force-quit the only way out.
//
// The first test runs over real localhost TCP rather than the in-memory
// loopback, because the property under test is precisely that a dart:io
// Socket's read stream completes when the far end goes away — the very thing
// the in-memory double would be assuming rather than demonstrating.

import 'dart:async' show unawaited;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/battle/networking/battle_session.dart';
import 'package:rune_duel/protocol/in_memory_transport.dart';
import 'package:rune_duel/protocol/lan_socket_transport.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final matchId = Uint8List.fromList(List.generate(16, (i) => i));

  test('a peer whose socket dies without forfeiting completes '
      'peerConnectionLost', () async {
    final listener = await LanSocketTransport.bind();
    final connecting = LanSocketTransport.connectTo('127.0.0.1', listener.port);
    final transportA = await listener.acceptOnce();
    final transportB = await connecting;

    final sessionA = BattleSession(transportA, matchId);
    final sessionB = BattleSession(transportB, matchId);

    var forfeited = false;
    unawaited(sessionA.peerForfeit.then((_) => forfeited = true));

    // B goes away the way a real device does: the socket drops, with no
    // forfeit frame ahead of it.
    await transportB.disconnect();

    expect(await sessionA.peerConnectionLost, isNotEmpty);
    // The distinction the two error screens rest on: nobody forfeited here,
    // so the player must not be told the other device ended the duel.
    expect(forfeited, isFalse);

    await sessionA.close();
    await sessionB.close();
    await transportA.disconnect();
  });

  test('a live connection never reports itself lost', () async {
    final (transportA, transportB) = InMemoryTransport.pair();
    final sessionA = BattleSession(transportA, matchId);
    final sessionB = BattleSession(transportB, matchId);

    var lost = false;
    unawaited(sessionA.peerConnectionLost.then((_) => lost = true));

    // Ordinary traffic must not read as a drop.
    await Future.wait([
      sessionA.exchangeAvatarId('fighter_f_01'),
      sessionB.exchangeAvatarId('mage_m_01'),
    ]);
    await Future<void>.delayed(Duration.zero);

    expect(lost, isFalse);

    await transportA.disconnect();
    await transportB.disconnect();
  });

  test('closing our own session is not a lost connection', () async {
    // close() cancels the subscription, and a cancelled subscription never
    // fires onDone. This is what keeps a normal match teardown — where both
    // sides close — from throwing a connection-lost error over the top of the
    // result screen.
    final (transportA, transportB) = InMemoryTransport.pair();
    final sessionA = BattleSession(transportA, matchId);
    final sessionB = BattleSession(transportB, matchId);

    var lost = false;
    unawaited(sessionA.peerConnectionLost.then((_) => lost = true));

    await sessionA.close();
    await Future<void>.delayed(Duration.zero);

    expect(lost, isFalse);

    await sessionB.close();
    await transportA.disconnect();
    await transportB.disconnect();
  });

  test('a drop releases anyone blocked on the sequential-components gate',
      () async {
    // The components gate waits on a frame that rides the same socket, so a
    // drop means that frame can never arrive. Before this, the trailing
    // player's controls stayed locked even once the duel was visibly over.
    final (transportA, transportB) = InMemoryTransport.pair();
    final sessionA = BattleSession(transportA, matchId);
    final sessionB = BattleSession(transportB, matchId);

    var released = false;
    unawaited(sessionA.peerComponentsDone(3).then((_) => released = true));
    await Future<void>.delayed(Duration.zero);
    expect(released, isFalse, reason: 'nothing has happened yet');

    await transportA.disconnect();
    await Future<void>.delayed(Duration.zero);

    expect(released, isTrue);

    await sessionB.close();
    await transportB.disconnect();
  });
}
