// SPDX-License-Identifier: GPL-3.0-or-later
//
// minion_terrain_test.dart — end-to-end (real TurnLoop resolution,
// SoloBattleSession) tests for minion terrain parity with wizards:
// FloorIsLava damages a minion for every tile entered (not just standing on
// it at end of turn), SlowTile costs exactly 2 movement, flying minions are
// exempt from both, and a ConveyorTile pushes a minion one further after its
// voluntary move lands on it.
//
// Geometry mirrors summon_cast_test.dart's "closes distance" test: a minion
// on the q=0 column moving toward a far dummy on the same column always
// takes its first greedy step straight down the column (verified there),
// so placing a terrain tile at that exact first-step hex gives a
// deterministic single-step scenario.

import 'package:test/test.dart';
import 'package:rune_duel/battle/engine/turn_loop.dart';
import 'package:rune_duel/battle/models/battle_state.dart';
import 'package:rune_duel/battle/models/effect_kind.dart' show SpellAffinity;
import 'package:rune_duel/battle/models/hex_battlefield.dart' show Battlefield, hexDistance;
import 'package:rune_duel/battle/models/match_config.dart';
import 'package:rune_duel/battle/models/minion.dart';
import 'package:rune_duel/battle/models/terrain.dart';
import 'package:rune_duel/battle/models/wizard_avatar.dart';
import 'package:rune_duel/battle/networking/solo_battle_session.dart';
import 'package:rune_duel/engine/hex_grid.dart';

({BattleState state, TurnLoop loop, Minion minion}) _setup({
  required Map<HexCoord, TileEffect> tileEffects,
  int moveSpeed = 1,
  Set<SummonAbility> abilities = const {},
}) {
  const localId = 'local';
  const dummyId = 'dummy';
  const localPos = HexCoord(0, 5);
  const dummyPos = HexCoord(0, -5);
  const minionPos = HexCoord(0, 3);
  const radius = 8;

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

  final minion = Minion(
    id: 'test_minion',
    ownerId: localId,
    teamId: 'solo',
    position: minionPos,
    affinity: SpellAffinity.fire,
    stats: MinionStats(maxHp: 20, damage: 1, moveSpeed: moveSpeed, attackRange: 1),
    elementSequence: const [],
    abilities: abilities,
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
  state.minions.add(minion);

  final loop = TurnLoop(state: state, session: SoloBattleSession(state: state), localPlayerId: localId);
  return (state: state, loop: loop, minion: minion);
}

void main() {
  group('minion terrain parity', () {
    test(
        'FloorIsLava damages a minion both on entry and again at end of turn '
        'if it is still standing there', () async {
      const lavaTile = HexCoord(0, 2); // first greedy step from (0,3) toward (0,-5)
      final ctx = _setup(tileEffects: {lavaTile: const FloorIsLava(damage: 3)});
      final startHp = ctx.minion.hp;

      await ctx.loop.runTurn(TurnInput(action: PassAction()));

      expect(ctx.minion.position, lavaTile);
      // moveSpeed 1 means the minion's move ends on the lava tile, so it eats
      // both the per-step entry damage AND the existing end-of-turn
      // "standing on lava" sweep -- 3 + 3, per Soren's explicit correction
      // (both, not either/or) rather than the initial single-hit read.
      expect(ctx.minion.hp, startHp - 6);
    });

    test('SlowTile costs exactly 2 movement (not 1, not additive to a base 1)', () async {
      const slowTile = HexCoord(0, 2);
      final ctx = _setup(
        tileEffects: {slowTile: const SlowTile(extraMoveCost: 2)},
        moveSpeed: 2, // would normally cover 2 tiles this turn
      );

      await ctx.loop.runTurn(TurnInput(action: PassAction()));

      // Budget of 2 fully consumed entering the one SlowTile tile -- the
      // minion should NOT have taken a second step.
      expect(ctx.minion.position, slowTile);
    });

    test('flying minions are exempt from FloorIsLava damage', () async {
      const lavaTile = HexCoord(0, 2);
      final ctx = _setup(
        tileEffects: {lavaTile: const FloorIsLava(damage: 3)},
        abilities: {SummonAbility.flying},
      );
      final startHp = ctx.minion.hp;

      await ctx.loop.runTurn(TurnInput(action: PassAction()));

      expect(ctx.minion.position, lavaTile);
      expect(ctx.minion.hp, startHp);
    });

    test('a ConveyorTile pushes a minion one further after it lands on it', () async {
      const conveyorTile = HexCoord(0, 2);
      const pushedTo = HexCoord(0, 1); // one further toward the dummy
      final ctx = _setup(tileEffects: {
        conveyorTile: const ConveyorTile(direction: HexCoord(0, -1)),
      });

      await ctx.loop.runTurn(TurnInput(action: PassAction()));

      expect(ctx.minion.position, pushedTo);
      expect(ctx.loop.lastConveyorChainEvents, hasLength(1));
      expect(ctx.loop.lastConveyorChainEvents.single.entityId, 'test_minion');
    });

    test('a mid-walk push (not the final step) still lets the minion keep '
        'moving with its remaining budget afterward', () async {
      const conveyorTile = HexCoord(0, 2); // first greedy step, not the last
      const pushedTo = HexCoord(1, 2); // sideways, off the direct path to the dummy
      final ctx = _setup(
        tileEffects: {conveyorTile: const ConveyorTile(direction: HexCoord(1, 0))},
        moveSpeed: 2,
      );
      final dummyPos = ctx.state.avatars.firstWhere((a) => a.playerId == 'dummy').position;
      final distanceAtPushedTile = hexDistance(pushedTo, dummyPos);

      await ctx.loop.runTurn(TurnInput(action: PassAction()));

      expect(ctx.loop.lastConveyorChainEvents, hasLength(1));
      // The minion should have used its second (post-push) movement point to
      // keep closing on the dummy from the pushed tile, not just stop there.
      expect(ctx.minion.distanceTo(dummyPos), lessThan(distanceAtPushedTile));
      expect(ctx.minion.position, isNot(conveyorTile));
      expect(ctx.minion.position, isNot(pushedTo));
    });

    test('flying minions are exempt from ConveyorTile pushes', () async {
      const conveyorTile = HexCoord(0, 2);
      final ctx = _setup(
        tileEffects: {conveyorTile: const ConveyorTile(direction: HexCoord(0, -1))},
        abilities: {SummonAbility.flying},
      );

      await ctx.loop.runTurn(TurnInput(action: PassAction()));

      // Landed on the conveyor tile but was not pushed further.
      expect(ctx.minion.position, conveyorTile);
      expect(ctx.loop.lastConveyorChainEvents, isEmpty);
    });

    test('a conveyor summoned directly under a stationary minion still pushes '
        'it at end of turn', () async {
      // moveSpeed 0 means the minion never voluntarily steps anywhere this
      // turn, so it never "enters" the conveyor sitting under it -- only the
      // end-of-turn sweep can move it.
      const minionTile = HexCoord(0, 3);
      const pushedTo = HexCoord(0, 2);
      final ctx = _setup(
        tileEffects: {minionTile: const ConveyorTile(direction: HexCoord(0, -1))},
        moveSpeed: 0,
      );

      await ctx.loop.runTurn(TurnInput(action: PassAction()));

      expect(ctx.minion.position, pushedTo);
      expect(ctx.loop.lastConveyorChainEvents, hasLength(1));
      expect(ctx.loop.lastConveyorChainEvents.single.entityId, 'test_minion');
    });
  });
}
