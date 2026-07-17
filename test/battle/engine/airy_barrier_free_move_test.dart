// SPDX-License-Identifier: GPL-3.0-or-later
//
// airy_barrier_free_move_test.dart — engine tests for the post-resolution
// free-move commit-reveal round granted when an Airy Barrier bursts from
// damage this turn (WizardAvatar.pendingFreeMoveBurst, set in absorbDamage).
// Uses SoloBattleSession the same way dash_meditate_melee_test.dart does —
// scripts the dummy to cast a Fire-Fire-Fire (4 damage) bolt at the local
// avatar to burst a 2 HP Air barrier.

import 'package:test/test.dart';
import 'package:rune_duel/battle/engine/turn_loop.dart';
import 'package:rune_duel/battle/models/barrier.dart';
import 'package:rune_duel/battle/models/battle_state.dart';
import 'package:rune_duel/battle/models/effect_kind.dart' show SpellAffinity;
import 'package:rune_duel/battle/models/hex_battlefield.dart' show Battlefield;
import 'package:rune_duel/battle/models/match_config.dart';
import 'package:rune_duel/battle/models/wizard_avatar.dart';
import 'package:rune_duel/battle/networking/solo_battle_session.dart';
import 'package:rune_duel/engine/hex_grid.dart';

({BattleState state, TurnLoop loop, WizardAvatar local, WizardAvatar dummy}) _setup({
  int airBarrierHp = 2,
  FreeMoveDirectionPicker? freeMovePicker,
  bool dummyCasts = true,
}) {
  const localId = 'local';
  const dummyId = 'dummy';
  const localPos = HexCoord(0, 0);
  const dummyPos = HexCoord(0, 3);

  final battlefield = Battlefield(radius: 8);
  battlefield.occupancy[localId] = localPos;
  battlefield.occupancy[dummyId] = dummyPos;

  final local = WizardAvatar(
    playerId: localId,
    ownerPubkeyHex: '0x${'0' * 64}',
    hp: 24,
    mana: 50,
    maxMana: 100,
    position: localPos,
    teamId: 'solo',
    baseSpellRange: 6,
  );
  local.barriers[SpellAffinity.air] = BarrierState(
    element: SpellAffinity.air,
    hp: airBarrierHp,
    maxHp: airBarrierHp,
    remainingTurns: 3,
    freeMoveOnCollapse: true,
  );

  final dummy = WizardAvatar(
    playerId: dummyId,
    ownerPubkeyHex: '0x${'0' * 64}',
    hp: 24,
    mana: 100,
    maxMana: 100,
    position: dummyPos,
    teamId: 'foe',
    baseSpellRange: 6,
  );

  final state = BattleState(
    config: MatchConfig(playerHp: 24, gridRadius: 8, maxPlayers: 2),
    avatars: [local, dummy],
    teams: [
      Team(id: 'solo', playerIds: const [localId]),
      Team(id: 'foe', playerIds: const [dummyId]),
    ],
    battlefield: battlefield,
  );

  final loop = TurnLoop(
    state: state,
    session: SoloBattleSession(
      state: state,
      dummyAutoCast: dummyCasts,
      dummyCastTarget: localPos,
      dummyCastFormula: const ['fire', 'fire', 'fire'], // 4 damage
    ),
    localPlayerId: localId,
    freeMoveDirectionPicker: freeMovePicker ?? (candidates) async => null,
  );

  return (state: state, loop: loop, local: local, dummy: dummy);
}

void main() {
  group('Airy Barrier burst free-move', () {
    test('barrier destroyed by damage grants a free move to the picked tile', () async {
      List<HexCoord>? seenCandidates;
      final ctx = _setup(
        airBarrierHp: 2,
        freeMovePicker: (candidates) async {
          seenCandidates = candidates;
          return candidates.first;
        },
      );
      final startPos = ctx.local.position;

      await ctx.loop.runTurn(TurnInput(action: PassAction()));

      expect(seenCandidates, isNotNull, reason: 'picker should have been prompted');
      expect(seenCandidates, isNot(contains(startPos)));
      expect(ctx.local.position, isNot(startPos));
      expect(ctx.local.barriers.containsKey(SpellAffinity.air), isFalse,
          reason: '2 HP barrier fully absorbed the 4 damage bolt (with overflow to real HP)');
      expect(ctx.local.pendingFreeMoveBurst, isFalse,
          reason: 'one-shot grant must be cleared after being consumed');
    });

    test('declining the free-move prompt (picker returns null) leaves position unchanged',
        () async {
      final ctx = _setup(airBarrierHp: 2, freeMovePicker: (candidates) async => null);
      final startPos = ctx.local.position;

      await ctx.loop.runTurn(TurnInput(action: PassAction()));

      expect(ctx.local.position, startPos);
      expect(ctx.local.pendingFreeMoveBurst, isFalse,
          reason: 'the one-shot grant is still cleared even if unused');
    });

    test('no prompt when the barrier absorbs damage but survives', () async {
      var pickerCalled = false;
      final ctx = _setup(
        airBarrierHp: 10, // 4 damage this turn is not enough to burst it
        freeMovePicker: (candidates) async {
          pickerCalled = true;
          return candidates.first;
        },
      );
      final startPos = ctx.local.position;

      await ctx.loop.runTurn(TurnInput(action: PassAction()));

      expect(pickerCalled, isFalse);
      expect(ctx.local.position, startPos);
      expect(ctx.local.barriers[SpellAffinity.air]?.hp, 6);
    });

    test('no prompt when no damage is dealt at all', () async {
      var pickerCalled = false;
      final ctx = _setup(
        airBarrierHp: 2,
        dummyCasts: false, // dummy just passes — no damage this turn
        freeMovePicker: (candidates) async {
          pickerCalled = true;
          return candidates.first;
        },
      );

      await ctx.loop.runTurn(TurnInput(action: PassAction()));

      expect(pickerCalled, isFalse);
      expect(ctx.local.barriers.containsKey(SpellAffinity.air), isTrue);
    });
  });
}
