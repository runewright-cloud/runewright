// SPDX-License-Identifier: GPL-3.0-or-later
//
// components_done_test.dart — BattleSession's sequential-casting pacing
// signal (docs/SPELL_COMPONENTS_PLAN.md §5.3).
//
// Two real BattleSession instances over InMemoryTransport, no mocks — the same
// wire-level approach as peer_forfeit_test.dart, and for the same reason: the
// bug worth catching lives in the arrival ORDER, which a mock would let us
// choose rather than observe.
//
// The property under test is the latch. The leader by definition finishes
// performing before the trailing player's screen asks whether it may act, so
// "the frame landed before anyone was waiting" is the ordinary case here, not
// the exotic one. A broadcast stream would drop it and lock the trailing
// player out for the rest of the turn.

import 'dart:async' show unawaited;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/battle/networking/battle_session.dart';
import 'package:rune_duel/protocol/in_memory_transport.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final matchId = Uint8List.fromList(List.generate(16, (i) => i));

  /// True once [future] has completed, after draining pending microtasks and
  /// letting the in-memory transport deliver.
  Future<bool> settled(Future<void> future) async {
    var done = false;
    unawaited(future.then((_) => done = true));
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    return done;
  }

  test('a signal that arrives before anyone waits is latched', () async {
    final (transportA, transportB) = InMemoryTransport.pair();
    final sessionA = BattleSession(transportA, matchId);
    final sessionB = BattleSession(transportB, matchId);

    sessionA.sendComponentsDone(3);
    await Future<void>.delayed(Duration.zero);

    expect(await settled(sessionB.peerComponentsDone(3)), isTrue);

    await transportA.disconnect();
    await transportB.disconnect();
  });

  test('a waiter registered first is completed when the signal lands',
      () async {
    final (transportA, transportB) = InMemoryTransport.pair();
    final sessionA = BattleSession(transportA, matchId);
    final sessionB = BattleSession(transportB, matchId);

    final gate = sessionB.peerComponentsDone(1);
    expect(await settled(gate), isFalse);

    sessionA.sendComponentsDone(1);
    expect(await settled(gate), isTrue);

    await transportA.disconnect();
    await transportB.disconnect();
  });

  test('a signal for one turn does not satisfy another turn\'s wait', () async {
    // Why the receiving side records a SET of turns rather than a latest-turn
    // counter: this signal is not part of the lockstep sequence, so nothing
    // keeps the two sides' turn numbers in step at the moment it arrives.
    final (transportA, transportB) = InMemoryTransport.pair();
    final sessionA = BattleSession(transportA, matchId);
    final sessionB = BattleSession(transportB, matchId);

    sessionA.sendComponentsDone(2);
    await Future<void>.delayed(Duration.zero);

    expect(await settled(sessionB.peerComponentsDone(3)), isFalse);
    expect(await settled(sessionB.peerComponentsDone(2)), isTrue);

    await transportA.disconnect();
    await transportB.disconnect();
  });

  test('several turns\' signals are all remembered', () async {
    final (transportA, transportB) = InMemoryTransport.pair();
    final sessionA = BattleSession(transportA, matchId);
    final sessionB = BattleSession(transportB, matchId);

    for (final turn in [1, 2, 3]) {
      sessionA.sendComponentsDone(turn);
    }
    await Future<void>.delayed(Duration.zero);

    for (final turn in [1, 2, 3]) {
      expect(
        await settled(sessionB.peerComponentsDone(turn)),
        isTrue,
        reason: 'turn $turn was announced and must stay announced',
      );
    }

    await transportA.disconnect();
    await transportB.disconnect();
  });

  test('the turn number survives past one byte', () async {
    // The payload is a big-endian uint32, and the decode has to read all four
    // bytes. A truncating reader would satisfy the wrong turn's wait — which
    // is a hang for one player and an out-of-order cast for the other.
    //
    // Checked through the public latch rather than by reading the frame:
    // BattleSession's constructor-time pump claims every componentsDone frame
    // (BattleFrameReader hands each frame to exactly one waiter), so a second
    // listener would simply never fire.
    final (transportA, transportB) = InMemoryTransport.pair();
    final sessionA = BattleSession(transportA, matchId);
    final sessionB = BattleSession(transportB, matchId);

    sessionA.sendComponentsDone(0x01020304);
    await Future<void>.delayed(Duration.zero);

    expect(await settled(sessionB.peerComponentsDone(0x01020304)), isTrue);
    expect(
      await settled(sessionB.peerComponentsDone(0x04)),
      isFalse,
      reason: 'the low byte alone must not satisfy the wait',
    );

    await transportA.disconnect();
    await transportB.disconnect();
  });
}
