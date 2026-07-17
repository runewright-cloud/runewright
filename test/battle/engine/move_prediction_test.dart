// SPDX-License-Identifier: GPL-3.0-or-later
//
// move_prediction_test.dart — tests for predictTileEntry/predictAvatarMove:
// the client-side, RNG-free preview used while a player is interactively
// building their move path (battle_screen.dart), before a turn is
// submitted. The critical guarantee is that this preview is byte-identical
// to what TurnLoop actually does for the deterministic (non-loop) case, and
// honestly reports "indeterminate" rather than guessing when a conveyor
// chain would enter a closed loop (whose resolution needs post-entropy RNG
// the client doesn't have yet).

import 'dart:math';

import 'package:test/test.dart';
import 'package:rune_duel/battle/engine/tile_entry_resolver.dart';
import 'package:rune_duel/battle/engine/turn_loop.dart';
import 'package:rune_duel/battle/models/battle_state.dart';
import 'package:rune_duel/battle/models/hex_battlefield.dart' show Battlefield;
import 'package:rune_duel/battle/models/match_config.dart';
import 'package:rune_duel/battle/models/terrain.dart';
import 'package:rune_duel/battle/models/wizard_avatar.dart';
import 'package:rune_duel/battle/networking/solo_battle_session.dart';
import 'package:rune_duel/engine/hex_grid.dart';

BattleState _state({Map<HexCoord, TileEffect> tileEffects = const {}, int radius = 6}) {
  return BattleState(
    config: MatchConfig(gridRadius: radius),
    avatars: <WizardAvatar>[],
    teams: const [],
    battlefield: Battlefield(radius: radius),
    tileEffects: Map.of(tileEffects),
  );
}

void main() {
  group('predictTileEntry', () {
    test('matches resolveTileEntry exactly for a straight cascade', () {
      const a = HexCoord(0, 0);
      const b = HexCoord(1, 0);
      const c = HexCoord(1, -1);
      final state = _state(tileEffects: {
        a: const ConveyorTile(direction: HexCoord(1, 0)),
        b: const ConveyorTile(direction: HexCoord(0, -1)),
      });

      final prediction = predictTileEntry(state: state, enteredTile: a, flying: false);
      final real = resolveTileEntry(
        state: state, rng: Random(1), enteredTile: a, flying: false, currentHp: 20);

      expect(prediction.enteredIndeterminateLoop, isFalse);
      expect(prediction.finalPosition, c);
      expect(prediction.finalPosition, real.finalPosition);
      expect(prediction.path, real.animationPath);
    });

    test('stops and reports indeterminate the moment a closed loop is detected', () {
      const a = HexCoord(0, 0);
      const b = HexCoord(1, 0);
      final state = _state(tileEffects: {
        a: const ConveyorTile(direction: HexCoord(1, 0)),
        b: const ConveyorTile(direction: HexCoord(-1, 0)),
      });

      final prediction = predictTileEntry(state: state, enteredTile: a, flying: false);

      expect(prediction.enteredIndeterminateLoop, isTrue);
      // Reports where the loop was detected, not a guess at the (RNG-
      // dependent) real exit/crash outcome.
      expect(prediction.path, [a, b]);
    });

    test('flying entities never trigger a push, so nothing is ever indeterminate', () {
      const a = HexCoord(0, 0);
      const b = HexCoord(1, 0);
      final state = _state(tileEffects: {
        a: const ConveyorTile(direction: HexCoord(1, 0)),
        b: const ConveyorTile(direction: HexCoord(-1, 0)),
      });

      final prediction = predictTileEntry(state: state, enteredTile: a, flying: true);

      expect(prediction.enteredIndeterminateLoop, isFalse);
      expect(prediction.finalPosition, a);
    });
  });

  group('predictAvatarMove', () {
    test('a mid-path conveyor push is free and does not consume budget', () {
      const conveyorTile = HexCoord(1, 0);
      final state = _state(tileEffects: {
        conveyorTile: const ConveyorTile(direction: HexCoord(0, 1)),
      });

      final prediction = predictAvatarMove(
        state: state,
        origin: const HexCoord(0, 0),
        declaredPath: const [HexCoord(1, 0), HexCoord(2, 0)],
        budget: 2,
      );

      expect(prediction.indeterminate, isFalse);
      // origin -> (1,0) [voluntary, cost 1] -> (1,1) [free push] -> (2,0)
      // [voluntary, cost 1] -- exactly 2 budget spent for 2 voluntary tiles,
      // even though 3 tiles beyond the origin were actually visited.
      expect(prediction.path, [
        const HexCoord(0, 0),
        const HexCoord(1, 0),
        const HexCoord(1, 1),
        const HexCoord(2, 0),
      ]);
      expect(prediction.budgetRemaining, 0);
    });

    test('stops (indeterminate) at a loop even mid-budget, not consuming further steps', () {
      const a = HexCoord(1, 0);
      const b = HexCoord(1, 1);
      final state = _state(tileEffects: {
        a: const ConveyorTile(direction: HexCoord(0, 1)),
        b: const ConveyorTile(direction: HexCoord(0, -1)),
      });

      final prediction = predictAvatarMove(
        state: state,
        origin: const HexCoord(0, 0),
        declaredPath: const [HexCoord(1, 0), HexCoord(2, 0)],
        budget: 2,
      );

      expect(prediction.indeterminate, isTrue);
      expect(prediction.path, [const HexCoord(0, 0), a, b]);
    });

    test('an impassable tile stops the walk exactly like a declared step that fails', () {
      const wall = HexCoord(1, 0);
      final state = _state(tileEffects: {wall: const ImpassableTile()});

      final prediction = predictAvatarMove(
        state: state,
        origin: const HexCoord(0, 0),
        declaredPath: const [HexCoord(1, 0), HexCoord(2, 0)],
        budget: 2,
      );

      expect(prediction.path, [const HexCoord(0, 0)]);
      expect(prediction.budgetRemaining, 2);
    });
  });

  group('prediction matches the real resolved turn (WYSIWYG guarantee)', () {
    test('a client-side prediction of a mid-path conveyor push equals what '
        'TurnLoop.runTurn actually does', () async {
      const localId = 'local';
      const dummyId = 'dummy';
      const localPos = HexCoord(0, 0);
      const dummyPos = HexCoord(0, 5);
      const conveyorTile = HexCoord(1, 0);
      const radius = 6;

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

      final tileEffects = {conveyorTile: const ConveyorTile(direction: HexCoord(0, 1))};
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

      const declaredPath = [HexCoord(1, 0), HexCoord(2, 0)];

      // What the player would see while planning, before submitting.
      final prediction = predictAvatarMove(
        state: state, origin: localPos, declaredPath: declaredPath,
        budget: local.effectiveMoveSpeed,
      );
      expect(prediction.indeterminate, isFalse);

      final loop = TurnLoop(state: state, session: SoloBattleSession(state: state), localPlayerId: localId);
      await loop.runTurn(TurnInput(action: PassAction(), movePath: declaredPath));

      expect(local.position, prediction.path.last);
    });
  });
}
