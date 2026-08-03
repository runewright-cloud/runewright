// SPDX-License-Identifier: GPL-3.0-or-later
//
// turn_loop_win_condition_test.dart — guards TurnLoop.runTurn's return
// value (docs/MASTER_APPRENTICE_PLAN.md §4.4). Before this plan, nothing
// consumed WinCheckResult: battle_screen.dart discarded it outright. This
// test exists so a future refactor of runTurn's tail can't silently stop
// returning it without a test noticing — battle_screen.dart's whole
// match-end path (_handleMatchEnd, the signed MatchOutcome exchange) is
// built on this return value actually firing when a side is defeated.
//
// Uses the same TurnSessionPair fixture as turn_loop_determinism_test.dart:
// two independently-driven TurnLoop instances, no network I/O, real
// commit-reveal lockstep.

import 'package:test/test.dart';
import 'package:rune_duel/battle/engine/turn_loop.dart';
import 'package:rune_duel/battle/models/battle_state.dart';
import 'package:rune_duel/battle/models/hex_battlefield.dart' show Battlefield;
import 'package:rune_duel/battle/models/match_config.dart';
import 'package:rune_duel/battle/models/wizard_avatar.dart';
import 'package:rune_duel/engine/hex_grid.dart';

import 'turn_session_pair.dart';

BattleState _makeStateWithDefeatedB() {
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
        ownerPubkeyHex: '0x${'11' * 32}',
        hp: 0, // already defeated -- checkWinCondition reads isAlive live.
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

void main() {
  group('TurnLoop.runTurn win-condition return value', () {
    test('returns isOver + the surviving team once one side has 0 hp', () async {
      final state1 = _makeStateWithDefeatedB();
      final state2 = _makeStateWithDefeatedB();

      final pair = TurnSessionPair();
      final loop1 = TurnLoop(state: state1, session: pair.sessionA, localPlayerId: 'player_a');
      final loop2 = TurnLoop(state: state2, session: pair.sessionB, localPlayerId: 'player_b');

      final input = TurnInput(action: PassAction());
      final results = await Future.wait([loop1.runTurn(input), loop2.runTurn(input)]);

      for (final win in results) {
        expect(win, isNotNull, reason: 'runTurn must report the win condition, not discard it');
        expect(win!.isOver, isTrue);
        expect(win.winningTeamId, equals('team_a'));
      }
    });

    test('returns null while both sides are still alive', () async {
      final battlefield = Battlefield();
      const posA = HexCoord(0, 0);
      const posB = HexCoord(2, -2);
      battlefield.occupancy['player_a'] = posA;
      battlefield.occupancy['player_b'] = posB;
      BattleState alive() => BattleState(
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
                ownerPubkeyHex: '0x${'11' * 32}',
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

      final pair = TurnSessionPair();
      final loop1 = TurnLoop(state: alive(), session: pair.sessionA, localPlayerId: 'player_a');
      final loop2 = TurnLoop(state: alive(), session: pair.sessionB, localPlayerId: 'player_b');

      final input = TurnInput(action: PassAction());
      final results = await Future.wait([loop1.runTurn(input), loop2.runTurn(input)]);

      for (final win in results) {
        expect(win, isNull);
      }
    });
  });
}
