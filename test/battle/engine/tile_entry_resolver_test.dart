// SPDX-License-Identifier: GPL-3.0-or-later
//
// tile_entry_resolver_test.dart — direct unit tests for resolveTileEntry:
// straight conveyor chains, cascading pushes, lava-on-entry, flying
// exemption, and the closed-loop mechanic (exit search, extra-tile damage
// scaling, and the fully-blocked death spiral).

import 'dart:math';

import 'package:test/test.dart';
import 'package:rune_duel/battle/engine/tile_entry_resolver.dart';
import 'package:rune_duel/battle/models/battle_state.dart';
import 'package:rune_duel/battle/models/hex_battlefield.dart' show Battlefield;
import 'package:rune_duel/battle/models/match_config.dart';
import 'package:rune_duel/battle/models/terrain.dart';
import 'package:rune_duel/battle/models/wizard_avatar.dart';
import 'package:rune_duel/engine/hex_grid.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

const List<HexCoord> _dirs = [
  HexCoord(1, 0), HexCoord(1, -1), HexCoord(0, -1),
  HexCoord(-1, 0), HexCoord(-1, 1), HexCoord(0, 1),
];

HexCoord _add(HexCoord a, HexCoord b) => HexCoord(a.q + b.q, a.r + b.r);

List<HexCoord> _neighbors(HexCoord h) => _dirs.map((d) => _add(h, d)).toList();

BattleState _state({Map<HexCoord, TileEffect> tileEffects = const {}, int radius = 6}) {
  return BattleState(
    config: MatchConfig(gridRadius: radius),
    avatars: <WizardAvatar>[],
    teams: const [],
    battlefield: Battlefield(radius: radius),
    tileEffects: Map.of(tileEffects),
  );
}

WizardAvatar _avatar(String id, HexCoord pos, int hp) => WizardAvatar(
      playerId: id,
      ownerPubkeyHex: '0x${'0' * 64}',
      hp: hp,
      mana: 100,
      maxMana: 100,
      position: pos,
      teamId: 'x',
      baseSpellRange: 3,
    );

/// A 2-tile loop (a <-> b) with every non-loop neighbor of both tiles blocked
/// impassable except [openExitTiles], which are left free for the caller to
/// place blocking entities on.
({HexCoord a, HexCoord b, List<HexCoord> loop, Map<HexCoord, TileEffect> tileEffects})
    _twoTileLoop({List<HexCoord> openExitTiles = const []}) {
  const a = HexCoord(0, 0);
  const b = HexCoord(1, 0);
  final loop = [a, b];
  final tileEffects = <HexCoord, TileEffect>{
    a: const ConveyorTile(direction: HexCoord(1, 0)),
    b: const ConveyorTile(direction: HexCoord(-1, 0)),
  };
  for (final t in loop) {
    for (final n in _neighbors(t)) {
      if (!loop.contains(n) && !openExitTiles.contains(n)) {
        tileEffects[n] = const ImpassableTile();
      }
    }
  }
  return (a: a, b: b, loop: loop, tileEffects: tileEffects);
}

void main() {
  final rng = Random(1);

  group('straight (non-looping) chains', () {
    test('no terrain: stays put, no damage', () {
      final state = _state();
      final outcome = resolveTileEntry(
        state: state, rng: rng, enteredTile: const HexCoord(0, 0),
        flying: false, currentHp: 20,
      );
      expect(outcome.finalPosition, const HexCoord(0, 0));
      expect(outcome.totalDamage, 0);
      expect(outcome.killed, isFalse);
      expect(outcome.animationPath, [const HexCoord(0, 0)]);
    });

    test('lava on the entered tile deals damage and does not push', () {
      const tile = HexCoord(0, 0);
      final state = _state(tileEffects: {tile: const FloorIsLava(damage: 2)});
      final outcome = resolveTileEntry(
        state: state, rng: rng, enteredTile: tile, flying: false, currentHp: 20,
      );
      expect(outcome.totalDamage, 2);
      expect(outcome.finalPosition, tile);
    });

    test('applyEntryLava: false skips the entered tile\'s own lava damage', () {
      const tile = HexCoord(0, 0);
      final state = _state(tileEffects: {tile: const FloorIsLava(damage: 2)});
      final outcome = resolveTileEntry(
        state: state, rng: rng, enteredTile: tile, flying: false, currentHp: 20,
        applyEntryLava: false,
      );
      expect(outcome.totalDamage, 0);
    });

    test('conveyor pushes one hex in its direction', () {
      const a = HexCoord(0, 0);
      const b = HexCoord(1, 0);
      final state = _state(tileEffects: {
        a: const ConveyorTile(direction: HexCoord(1, 0)),
      });
      final outcome = resolveTileEntry(
        state: state, rng: rng, enteredTile: a, flying: false, currentHp: 20,
      );
      expect(outcome.finalPosition, b);
      expect(outcome.animationPath, [a, b]);
    });

    test('cascading push: conveyor into conveyor chains further', () {
      const a = HexCoord(0, 0);
      const b = HexCoord(1, 0);
      const c = HexCoord(1, -1);
      final state = _state(tileEffects: {
        a: const ConveyorTile(direction: HexCoord(1, 0)),  // a -> b
        b: const ConveyorTile(direction: HexCoord(0, -1)), // b -> c
      });
      final outcome = resolveTileEntry(
        state: state, rng: rng, enteredTile: a, flying: false, currentHp: 20,
      );
      expect(outcome.finalPosition, c);
      expect(outcome.animationPath, [a, b, c]);
    });

    test('push stops at an impassable tile without cascading', () {
      const a = HexCoord(0, 0);
      const wall = HexCoord(1, 0);
      final state = _state(tileEffects: {
        a: const ConveyorTile(direction: HexCoord(1, 0)),
        wall: const ImpassableTile(),
      });
      final outcome = resolveTileEntry(
        state: state, rng: rng, enteredTile: a, flying: false, currentHp: 20,
      );
      expect(outcome.finalPosition, a);
      expect(outcome.animationPath, [a]);
    });

    test('flying entities ignore conveyor pushes and lava damage entirely', () {
      const tile = HexCoord(0, 0);
      final state = _state(tileEffects: {
        tile: const ConveyorTile(direction: HexCoord(1, 0)),
      });
      final outcome = resolveTileEntry(
        state: state, rng: rng, enteredTile: tile, flying: true, currentHp: 20,
      );
      expect(outcome.finalPosition, tile);
      expect(outcome.totalDamage, 0);
      expect(outcome.animationPath, [tile]);
    });
  });

  group('closed loops', () {
    test('2-tile loop with a free exit: no damage (loopLen ~/ 3 == 0)', () {
      const a = HexCoord(0, 0);
      const b = HexCoord(1, 0);
      final state = _state(tileEffects: {
        a: const ConveyorTile(direction: HexCoord(1, 0)),  // a -> b
        b: const ConveyorTile(direction: HexCoord(-1, 0)), // b -> a
      });
      final outcome = resolveTileEntry(
        state: state, rng: rng, enteredTile: a, flying: false, currentHp: 20,
      );
      expect(outcome.totalDamage, 0);
      expect(outcome.killed, isFalse);
      // Exit must be adjacent to the loop-entry tile checked, and not a loop tile.
      expect([a, b], isNot(contains(outcome.finalPosition)));
    });

    test('3-tile triangular loop with a free exit: 1 damage', () {
      const a = HexCoord(0, 0);
      const b = HexCoord(1, 0);
      const c = HexCoord(1, -1);
      final state = _state(tileEffects: {
        a: const ConveyorTile(direction: HexCoord(1, 0)),   // a -> b
        b: const ConveyorTile(direction: HexCoord(0, -1)),  // b -> c
        c: const ConveyorTile(direction: HexCoord(-1, 1)),  // c -> a
      });
      final outcome = resolveTileEntry(
        state: state, rng: rng, enteredTile: a, flying: false, currentHp: 20,
      );
      expect(outcome.totalDamage, 1);
      expect(outcome.killed, isFalse);
      expect([a, b, c], isNot(contains(outcome.finalPosition)));
    });

    test(
        'when the first loop tile has no valid exit, the search continues to '
        'the next tile and adds to the damage divisor', () {
      const a = HexCoord(0, 0);
      const b = HexCoord(1, 0);
      const c = HexCoord(1, -1);
      const d = HexCoord(0, -1);
      final loop = [a, b, c, d];
      final tileEffects = <HexCoord, TileEffect>{
        a: const ConveyorTile(direction: HexCoord(1, 0)),   // a -> b
        b: const ConveyorTile(direction: HexCoord(0, -1)),  // b -> c
        c: const ConveyorTile(direction: HexCoord(-1, 0)),  // c -> d
        d: const ConveyorTile(direction: HexCoord(0, 1)),   // d -> a
      };
      // Block every non-loop neighbor of a and b (loop[0], loop[1]) so the
      // exit search must skip past both before reaching c (loop[2]), which is
      // left open -- extra == 2, damage == (4 + 2) ~/ 3 == 2.
      for (final t in [a, b]) {
        for (final n in _neighbors(t)) {
          if (!loop.contains(n)) tileEffects[n] = const ImpassableTile();
        }
      }
      final state = _state(tileEffects: tileEffects);
      final outcome = resolveTileEntry(
        state: state, rng: rng, enteredTile: a, flying: false, currentHp: 20,
      );
      expect(outcome.totalDamage, 2);
      expect(outcome.killed, isFalse);
      expect(loop, isNot(contains(outcome.finalPosition)));
    });

    test('an occupied candidate exit is skipped in favor of another open one', () {
      const a = HexCoord(0, 0);
      const b = HexCoord(1, 0);
      const c = HexCoord(1, -1);
      final loop = [a, b, c];
      final tileEffects = <HexCoord, TileEffect>{
        a: const ConveyorTile(direction: HexCoord(1, 0)),
        b: const ConveyorTile(direction: HexCoord(0, -1)),
        c: const ConveyorTile(direction: HexCoord(-1, 1)),
      };
      final state = _state(tileEffects: tileEffects);
      final occupied = _neighbors(a).firstWhere((n) => !loop.contains(n));
      state.avatars.add(WizardAvatar(
        playerId: 'blocker',
        ownerPubkeyHex: '0x${'0' * 64}',
        hp: 24,
        mana: 100,
        maxMana: 100,
        position: occupied,
        teamId: 'x',
        baseSpellRange: 3,
      ));

      final outcome = resolveTileEntry(
        state: state, rng: rng, enteredTile: a, flying: false, currentHp: 20,
      );
      // a (loop[0]) still has other open exits, so this resolves at extra ==
      // 0 (damage 1) via one of them -- never the occupied tile.
      expect(outcome.finalPosition, isNot(occupied));
      expect(loop, isNot(contains(outcome.finalPosition)));
      expect(outcome.totalDamage, 1);
    });

    test('a fully-blocked loop kills the entity via repeated passes', () {
      const a = HexCoord(0, 0);
      const b = HexCoord(1, 0);
      const c = HexCoord(1, -1);
      final loop = [a, b, c];
      final tileEffects = <HexCoord, TileEffect>{
        a: const ConveyorTile(direction: HexCoord(1, 0)),
        b: const ConveyorTile(direction: HexCoord(0, -1)),
        c: const ConveyorTile(direction: HexCoord(-1, 1)),
      };
      for (final t in loop) {
        for (final n in _neighbors(t)) {
          if (!loop.contains(n)) tileEffects[n] = const ImpassableTile();
        }
      }
      final state = _state(tileEffects: tileEffects);
      final outcome = resolveTileEntry(
        state: state, rng: rng, enteredTile: a, flying: false, currentHp: 10,
      );
      // loopLen ~/ 3 == 1 damage per pass; 10 hp needs 10 passes to guarantee
      // lethal damage.
      expect(outcome.killed, isTrue);
      expect(outcome.totalDamage, greaterThanOrEqualTo(10));
    });
  });

  group('fully-blocked 2-tile loop: crash into the weakest blocker', () {
    test('looped entity outguns the blocker: blocker dies, looped escapes onto its tile', () {
      const exit = HexCoord(1, -1); // a non-loop neighbor of `a`
      final setup = _twoTileLoop(openExitTiles: [exit]);
      final state = _state(tileEffects: setup.tileEffects);
      state.avatars.add(_avatar('blocker', exit, 5));

      final outcome = resolveTileEntry(
        state: state, rng: rng, enteredTile: setup.a, flying: false, currentHp: 20,
      );

      expect(outcome.killed, isFalse);
      expect(outcome.finalPosition, exit);
      expect(outcome.totalDamage, 5); // blocker's own (pre-collision) HP
      final blocker = state.avatars.firstWhere((a) => a.playerId == 'blocker');
      expect(blocker.isAlive, isFalse);
    });

    test('blocker outguns the looped entity: looped dies, blocker survives damaged', () {
      const exit = HexCoord(1, -1);
      final setup = _twoTileLoop(openExitTiles: [exit]);
      final state = _state(tileEffects: setup.tileEffects);
      state.avatars.add(_avatar('blocker', exit, 30));

      final outcome = resolveTileEntry(
        state: state, rng: rng, enteredTile: setup.a, flying: false, currentHp: 20,
      );

      expect(outcome.killed, isTrue);
      expect(outcome.totalDamage, 30); // blocker's own (pre-collision) HP
      final blocker = state.avatars.firstWhere((a) => a.playerId == 'blocker');
      expect(blocker.isAlive, isTrue);
      expect(blocker.hp, 10); // 30 - 20 (looped entity's pre-collision HP)
    });

    test('an exact HP tie kills both combatants', () {
      const exit = HexCoord(1, -1);
      final setup = _twoTileLoop(openExitTiles: [exit]);
      final state = _state(tileEffects: setup.tileEffects);
      state.avatars.add(_avatar('blocker', exit, 20));

      final outcome = resolveTileEntry(
        state: state, rng: rng, enteredTile: setup.a, flying: false, currentHp: 20,
      );

      expect(outcome.killed, isTrue);
      final blocker = state.avatars.firstWhere((a) => a.playerId == 'blocker');
      expect(blocker.isAlive, isFalse);
    });

    test('crashes into whichever blocker has the lowest HP, not the first found', () {
      const strongExit = HexCoord(1, -1); // neighbor of a
      const weakExit = HexCoord(2, -1);   // neighbor of b
      final setup = _twoTileLoop(openExitTiles: [strongExit, weakExit]);
      final state = _state(tileEffects: setup.tileEffects);
      state.avatars.add(_avatar('strong', strongExit, 15));
      state.avatars.add(_avatar('weak', weakExit, 3));

      final outcome = resolveTileEntry(
        state: state, rng: rng, enteredTile: setup.a, flying: false, currentHp: 20,
      );

      expect(outcome.finalPosition, weakExit);
      expect(outcome.totalDamage, 3);
      expect(state.avatars.firstWhere((a) => a.playerId == 'weak').isAlive, isFalse);
      expect(state.avatars.firstWhere((a) => a.playerId == 'strong').isAlive, isTrue);
    });

    test('no entity anywhere to crash into: stays put, no damage, no death', () {
      final setup = _twoTileLoop(); // every non-loop neighbor impassable
      final state = _state(tileEffects: setup.tileEffects);

      final outcome = resolveTileEntry(
        state: state, rng: rng, enteredTile: setup.a, flying: false, currentHp: 20,
      );

      expect(outcome.killed, isFalse);
      expect(outcome.totalDamage, 0);
      expect(outcome.finalPosition, setup.a);
    });
  });
}
