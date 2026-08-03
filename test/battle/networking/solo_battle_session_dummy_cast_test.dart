// SPDX-License-Identifier: GPL-3.0-or-later
//
// solo_battle_session_dummy_cast_test.dart — Spell Test Lab: verifies
// SoloBattleSession.dummyAutoCast actually makes the dummy cast (not pass),
// end-to-end through TurnLoop's real commit-reveal + resolution pipeline —
// the encode/decode wire format is hand-written in SoloBattleSession, so this
// is exactly the seam most likely to silently break (CLAUDE.md: "boundary,
// not the math").

import 'package:test/test.dart';
import 'package:rune_duel/battle/engine/turn_loop.dart';
import 'package:rune_duel/battle/models/battle_state.dart';
import 'package:rune_duel/battle/models/hex_battlefield.dart' show Battlefield;
import 'package:rune_duel/battle/models/match_config.dart';
import 'package:rune_duel/battle/models/wizard_avatar.dart';
import 'package:rune_duel/battle/networking/solo_battle_session.dart';
import 'package:rune_duel/engine/hex_grid.dart';

void main() {
  test('dummyAutoCast hits the local player with a Firey Blast every turn', () async {
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

    expect(local.hp, 24);
    await loop.runTurn(TurnInput(action: PassAction()));
    // Fire-Fire (damage, non-potent) = 4 direct damage — effect_resolver.dart.
    expect(local.hp, 20, reason: 'dummy should have cast Firey Blast for free and hit the local player');

    await loop.runTurn(TurnInput(action: PassAction()));
    expect(local.hp, 16, reason: 'the dummy casts every turn, not just once');
  });

  test('regular SoloBattleSession (dummyAutoCast off) never casts — dummy just passes', () async {
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
      session: SoloBattleSession(state: state),
      localPlayerId: localId,
    );

    await loop.runTurn(TurnInput(action: PassAction()));
    expect(local.hp, 24, reason: 'regular Solo Practice dummy must stay passive');
  });
}
