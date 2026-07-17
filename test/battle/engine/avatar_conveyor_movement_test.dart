// SPDX-License-Identifier: GPL-3.0-or-later
//
// avatar_conveyor_movement_test.dart — end-to-end (real TurnLoop resolution,
// SoloBattleSession) regression test for the bug Soren found by hand: a
// conveyor tile only pushed a wizard if it happened to be the *last* planned
// step of their move. It must trigger immediately on entry regardless of
// position in the declared path, and the wizard must keep using any
// remaining movement budget afterward.

import 'package:test/test.dart';
import 'package:rune_duel/battle/engine/turn_loop.dart';
import 'package:rune_duel/battle/models/battle_state.dart';
import 'package:rune_duel/battle/models/hex_battlefield.dart' show Battlefield;
import 'package:rune_duel/battle/models/match_config.dart';
import 'package:rune_duel/battle/models/terrain.dart';
import 'package:rune_duel/battle/models/wizard_avatar.dart';
import 'package:rune_duel/battle/networking/solo_battle_session.dart';
import 'package:rune_duel/engine/hex_grid.dart';

({BattleState state, TurnLoop loop, WizardAvatar local})
    _setup(Map<HexCoord, TileEffect> tileEffects, {int radius = 6}) {
  const localId = 'local';
  const dummyId = 'dummy';
  const localPos = HexCoord(0, 0);
  const dummyPos = HexCoord(0, 5);

  final battlefield = Battlefield(radius: radius);
  battlefield.occupancy[localId] = localPos;
  battlefield.occupancy[dummyId] = dummyPos;

  final local = WizardAvatar(
    playerId: localId, ownerPubkeyHex: '0x${'0' * 64}', hp: 24, mana: 100,
    maxMana: 100, position: localPos, teamId: 'solo', baseSpellRange: 3,
  );
  final dummy = WizardAvatar(
    playerId: dummyId, ownerPubkeyHex: '0x${'0' * 64}', hp: 24, mana: 100,
    maxMana: 100, position: dummyPos, teamId: 'foe', baseSpellRange: 3,
  );

  final state = BattleState(
    config: MatchConfig(playerHp: 24, gridRadius: radius, maxPlayers: 2),
    avatars: [local, dummy],
    teams: [
      Team(id: 'solo', playerIds: const [localId]),
      Team(id: 'foe', playerIds: const [dummyId]),
    ],
    battlefield: battlefield,
    tileEffects: tileEffects,
  );

  final loop = TurnLoop(state: state, session: SoloBattleSession(state: state), localPlayerId: localId);
  return (state: state, loop: loop, local: local);
}

void main() {
  group('avatar conveyor push (mid-walk, not just the final planned tile)', () {
    test('triggers immediately on entry and can cut a multi-step path short', () async {
      // Declared path: (0,0) -> (1,0) -> (2,0). The conveyor sits at the
      // FIRST step, not the last, and pushes away from the rest of the
      // declared path (not adjacent to (2,0)) -- under the old final-tile-only
      // bug this conveyor would never have fired at all.
      const conveyorTile = HexCoord(1, 0);
      final ctx = _setup({
        conveyorTile: const ConveyorTile(direction: HexCoord(-1, 0)), // pushes back toward origin
      });

      await ctx.loop.runTurn(TurnInput(
        action: PassAction(),
        movePath: const [HexCoord(1, 0), HexCoord(2, 0)],
      ));

      // Pushed to (0,0) after entering (1,0); (2,0) is not adjacent to (0,0)
      // so the remaining declared step is simply unreachable and movement
      // stops there, with 1 movement point left unspent.
      expect(ctx.local.position, const HexCoord(0, 0));
      expect(ctx.loop.lastConveyorChainEvents, hasLength(1));
      expect(ctx.loop.lastConveyorChainEvents.single.entityId, 'local');
      expect(ctx.loop.lastConveyorChainEvents.single.path, [conveyorTile, const HexCoord(0, 0)]);
    });

    test('the wizard keeps using remaining movement budget after the push', () async {
      // Same declared path, but this conveyor pushes toward a tile that IS
      // still adjacent to the second declared step -- the wizard should
      // continue on to (2,0) using their last movement point instead of
      // stopping at the pushed tile.
      const conveyorTile = HexCoord(1, 0);
      const pushedTo = HexCoord(1, 1);
      final ctx = _setup({
        conveyorTile: const ConveyorTile(direction: HexCoord(0, 1)),
      });

      await ctx.loop.runTurn(TurnInput(
        action: PassAction(),
        movePath: const [HexCoord(1, 0), HexCoord(2, 0)],
      ));

      expect(ctx.local.position, const HexCoord(2, 0));
      expect(ctx.loop.lastConveyorChainEvents, hasLength(1));
      expect(ctx.loop.lastConveyorChainEvents.single.path, [conveyorTile, pushedTo]);
    });

    test('a push mid-walk still charges lava/slow tiles entered along the way', () async {
      const lavaTile = HexCoord(1, 0);
      final ctx = _setup({
        lavaTile: const FloorIsLava(damage: 4),
      });
      final startHp = ctx.local.hp;

      await ctx.loop.runTurn(TurnInput(
        action: PassAction(),
        movePath: const [HexCoord(1, 0), HexCoord(2, 0)],
      ));

      expect(ctx.local.position, const HexCoord(2, 0));
      expect(ctx.local.hp, startHp - 4);
    });
  });

  group('end-of-turn conveyor sweep (a conveyor that never sees an "entry")', () {
    test('a conveyor summoned directly under a stationary wizard still pushes them', () async {
      // The wizard starts on (0,0) and never moves this turn -- so nothing
      // ever "enters" this tile. Without the end-of-turn sweep this
      // conveyor would silently do nothing.
      const wizardTile = HexCoord(0, 0);
      const pushedTo = HexCoord(1, 0);
      final ctx = _setup({
        wizardTile: const ConveyorTile(direction: HexCoord(1, 0)),
      });

      await ctx.loop.runTurn(TurnInput(action: PassAction()));

      expect(ctx.local.position, pushedTo);
      expect(ctx.loop.lastConveyorChainEvents, hasLength(1));
      expect(ctx.loop.lastConveyorChainEvents.single.path, [wizardTile, pushedTo]);
    });

    test('a push that fails (blocked) keeps trying on the following turn', () async {
      const wizardTile = HexCoord(0, 0);
      const wall = HexCoord(1, 0);
      final ctx = _setup({
        wizardTile: const ConveyorTile(direction: HexCoord(1, 0)),
        wall: const ImpassableTile(),
      });

      await ctx.loop.runTurn(TurnInput(action: PassAction()));

      // Blocked immediately -- stays put, but the sweep still ran (an event
      // fires only when the entity actually moved at least one tile, so
      // none is expected here).
      expect(ctx.local.position, wizardTile);
      expect(ctx.loop.lastConveyorChainEvents, isEmpty);
    });
  });
}
