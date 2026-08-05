// SPDX-License-Identifier: GPL-3.0-or-later
//
// battle_session_avatar_id_test.dart — BattleSession.exchangeAvatarId
// (docs/AVATAR_PICKER_PLAN.md §5.2): both sides send their locally-chosen
// avatar id and must receive the OTHER side's, not their own echoed back or a
// stub. Two real BattleSession instances paired over InMemoryTransport (no
// mocks) — same "protocol first" approach as auth_handshake_test.dart.
//
// duel_setup_test.dart covers this exchange as part of the full handshake,
// but can't drive host and guest to genuinely different avatar ids there:
// Identity's avatar-id storage is a single process-global fake in tests (see
// fake_secure_storage.dart), so both roles necessarily read the same saved
// value in one test process. This file tests the actual regression risk —
// that exchangeAvatarId is genuinely bidirectional — directly at the wire
// level, where two independent literal strings can be driven per side.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/battle/networking/battle_session.dart';
import 'package:rune_duel/protocol/in_memory_transport.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final matchId = Uint8List.fromList(List.generate(16, (i) => i));

  test('each side receives the OTHER side\'s avatar id, not its own', () async {
    final (transportA, transportB) = InMemoryTransport.pair();
    final sessionA = BattleSession(transportA, matchId);
    final sessionB = BattleSession(transportB, matchId);

    final results = await Future.wait([
      sessionA.exchangeAvatarId('fighter_f_01'),
      sessionB.exchangeAvatarId('mage_m_01'),
    ]);

    expect(results[0], 'mage_m_01');
    expect(results[1], 'fighter_f_01');

    await transportA.disconnect();
    await transportB.disconnect();
  });

  test('an unset side sends the empty string, not a placeholder', () async {
    final (transportA, transportB) = InMemoryTransport.pair();
    final sessionA = BattleSession(transportA, matchId);
    final sessionB = BattleSession(transportB, matchId);

    final results = await Future.wait([
      sessionA.exchangeAvatarId(''),
      sessionB.exchangeAvatarId('healer_f_01'),
    ]);

    expect(results[0], 'healer_f_01');
    expect(results[1], '');

    await transportA.disconnect();
    await transportB.disconnect();
  });
}
