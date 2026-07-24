// SPDX-License-Identifier: GPL-3.0-or-later
//
// solo_battle_session_scry_test.dart — regression test for the bug where
// SoloBattleSession.exchangeScryOpen always answered "no reveal" even when
// the local player had an active outgoing DivinationLink (Airy Scrying
// Pool) on the dummy. TurnLoop.beginTurn must return the dummy's real
// committed target tile in that case, exactly as it would against a real
// peer via BattleSession — see turn_loop.dart's _exchangeScryOpenings.

import 'package:test/test.dart';
import 'package:rune_duel/battle/engine/turn_loop.dart';
import 'package:rune_duel/battle/models/battle_state.dart';
import 'package:rune_duel/battle/models/divination_link.dart';
import 'package:rune_duel/battle/models/hex_battlefield.dart' show Battlefield;
import 'package:rune_duel/battle/models/match_config.dart';
import 'package:rune_duel/battle/models/wizard_avatar.dart';
import 'package:rune_duel/battle/networking/solo_battle_session.dart';
import 'package:rune_duel/engine/hex_grid.dart';

void main() {
  test('an active outgoing DivinationLink on the dummy reveals its real committed target', () async {
    const localId = 'local';
    const dummyId = 'dummy';
    final localPos = HexCoord(0, 2);
    final dummyPos = HexCoord(0, -2);

    final battlefield = Battlefield(radius: 4);
    battlefield.occupancy[localId] = localPos;
    battlefield.occupancy[dummyId] = dummyPos;

    final local = WizardAvatar(
      playerId: localId,
      ownerPubkeyHex: '0x${'0' * 64}',
      hp: 24,
      mana: 100,
      maxMana: 100,
      position: localPos,
      teamId: 'solo',
      baseSpellRange: 3,
    );
    final dummy = WizardAvatar(
      playerId: dummyId,
      ownerPubkeyHex: '0x${'0' * 64}',
      hp: 24,
      mana: 100,
      maxMana: 100,
      position: dummyPos,
      teamId: 'foe',
      baseSpellRange: 3,
    );

    final state = BattleState(
      config: const MatchConfig(playerHp: 24, gridRadius: 4, maxPlayers: 2),
      avatars: [local, dummy],
      teams: [
        Team(id: 'solo', playerIds: [localId]),
        Team(id: 'foe', playerIds: [dummyId]),
      ],
      battlefield: battlefield,
      divinationLinks: [
        DivinationLink(
          id: 'link_1',
          casterId: localId,
          targetId: dummyId,
          remainingTurns: 2,
          flavor: DivinationFlavor.targetTile,
        ),
      ],
    );

    final loop = TurnLoop(
      state: state,
      session: SoloBattleSession(state: state, dummyAutoCast: true, dummyCastTarget: localPos),
      localPlayerId: localId,
    );

    final revealed = await loop.beginTurn(PassAction());
    expect(revealed, localPos,
        reason: 'beginTurn should surface the dummy\'s real Firey Blast target '
            'so the UI can render the scry-reveal indicator (matches what a '
            'real networked peer would open via BattleSession)');
  });

  test('no reveal when there is no active outgoing DivinationLink', () async {
    const localId = 'local';
    const dummyId = 'dummy';
    final localPos = HexCoord(0, 2);
    final dummyPos = HexCoord(0, -2);

    final battlefield = Battlefield(radius: 4);
    battlefield.occupancy[localId] = localPos;
    battlefield.occupancy[dummyId] = dummyPos;

    final local = WizardAvatar(
      playerId: localId,
      ownerPubkeyHex: '0x${'0' * 64}',
      hp: 24,
      mana: 100,
      maxMana: 100,
      position: localPos,
      teamId: 'solo',
      baseSpellRange: 3,
    );
    final dummy = WizardAvatar(
      playerId: dummyId,
      ownerPubkeyHex: '0x${'0' * 64}',
      hp: 24,
      mana: 100,
      maxMana: 100,
      position: dummyPos,
      teamId: 'foe',
      baseSpellRange: 3,
    );

    final state = BattleState(
      config: const MatchConfig(playerHp: 24, gridRadius: 4, maxPlayers: 2),
      avatars: [local, dummy],
      teams: [
        Team(id: 'solo', playerIds: [localId]),
        Team(id: 'foe', playerIds: [dummyId]),
      ],
      battlefield: battlefield,
    );

    final loop = TurnLoop(
      state: state,
      session: SoloBattleSession(state: state, dummyAutoCast: true, dummyCastTarget: localPos),
      localPlayerId: localId,
    );

    final revealed = await loop.beginTurn(PassAction());
    expect(revealed, isNull, reason: 'no scry link means no reveal, same as against a real peer');
  });
}
