// SPDX-License-Identifier: GPL-3.0-or-later
//
// haymaker_interaction_target_test.dart — Air-Earth "Melee Enhancement"
// (haymakerInteraction): 2026-07-27 fix. The spell primes a FUTURE melee
// punch (design doc "melee attacks": "Spell effects (Air-Earth row) can
// empower a melee attack with bonuses") and used to always land the pending
// buff on the caster regardless of the spell's target. It now lands on
// whoever occupies the target tile, like nearly every other spell effect --
// so buffing your own next haymaker requires self-targeting, and an
// enemy-targeted cast primes THEM instead.

import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:rune_duel/battle/engine/turn_loop.dart';
import 'package:rune_duel/battle/models/battle_state.dart';
import 'package:rune_duel/battle/models/hex_battlefield.dart' show Battlefield;
import 'package:rune_duel/battle/models/match_config.dart';
import 'package:rune_duel/battle/models/status_effect_ids.dart';
import 'package:rune_duel/battle/models/wizard_avatar.dart';
import 'package:rune_duel/battle/networking/solo_battle_session.dart';
import 'package:rune_duel/engine/hex_grid.dart';
import 'package:rune_duel/spells/spell_asset.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

// Water-flavor Air-Earth: (BorderZone.air, BorderZone.earth) selects
// haymakerInteraction; the leading zone selects the Water ("drain target
// status") flavor.
SpellAsset _waterHaymaker() => SpellAsset(
      id: 'haymaker-water',
      createdAt: DateTime.utc(2026, 7, 27),
      tier: 12,
      t: 5,
      ownerPubkeyHex: '0x${'0' * 64}',
      manaCost: 1,
      segmentCount: 0,
      dotCount: 1,
      initialGrid: List<int>.filled(469, 0)..[234] = 1,
      proofBytes: Uint8List.fromList([1, 2, 3, 4, 5]), // never verified in solo mode
      name: 'Test Haymaker Water',
      commitmentHex: '0x${'water,air,earth'.hashCode.toRadixString(16)}',
      spellHashHex: '0x${'water,air,earth'.hashCode.toRadixString(16)}2',
      formula: const ['water', 'air', 'earth'],
    );

({BattleState state, TurnLoop loop, WizardAvatar local, WizardAvatar dummy}) _setup({
  required HexCoord localPos,
  required HexCoord dummyPos,
  MeleeTargetPicker? meleePicker,
  int radius = 6,
}) {
  const localId = 'local';
  const dummyId = 'dummy';

  final battlefield = Battlefield(radius: radius);
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
    baseSpellRange: 6,
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
    config: MatchConfig(playerHp: 24, gridRadius: radius, maxPlayers: 2),
    avatars: [local, dummy],
    teams: [
      Team(id: 'solo', playerIds: const [localId]),
      Team(id: 'foe', playerIds: const [dummyId]),
    ],
    battlefield: battlefield,
  );

  final loop = TurnLoop(
    state: state,
    session: SoloBattleSession(state: state),
    localPlayerId: localId,
    meleeTargetPicker: meleePicker ?? (candidates) async => null,
  );

  return (state: state, loop: loop, local: local, dummy: dummy);
}

void main() {
  group('Haymaker Interaction targets the tile, not the caster', () {
    test('self-targeted cast primes the caster\'s own next haymaker', () async {
      final ctx = _setup(localPos: const HexCoord(0, 0), dummyPos: const HexCoord(0, 5));

      await ctx.loop.runTurn(TurnInput(
        action: SpellCastAction(spell: _waterHaymaker(), targetHex: ctx.local.position),
      ));

      expect(
        ctx.local.activeStatusEffects
            .any((fx) => fx.effectTypeId == StatusEffectId.haymakerStatusDrain),
        isTrue,
      );
      expect(
        ctx.dummy.activeStatusEffects
            .any((fx) => fx.effectTypeId == StatusEffectId.haymakerStatusDrain),
        isFalse,
      );
    });

    test('enemy-targeted cast primes the ENEMY\'s next haymaker, not the caster\'s', () async {
      final ctx = _setup(localPos: const HexCoord(0, 0), dummyPos: const HexCoord(0, 5));

      await ctx.loop.runTurn(TurnInput(
        action: SpellCastAction(spell: _waterHaymaker(), targetHex: ctx.dummy.position),
      ));

      expect(
        ctx.dummy.activeStatusEffects
            .any((fx) => fx.effectTypeId == StatusEffectId.haymakerStatusDrain),
        isTrue,
        reason: 'the enemy standing on the target tile gets primed, not the caster',
      );
      expect(
        ctx.local.activeStatusEffects
            .any((fx) => fx.effectTypeId == StatusEffectId.haymakerStatusDrain),
        isFalse,
      );
    });

    test('a self-primed caster who lands a later haymaker actually drains the target',
        () async {
      // dummy 3 tiles away: local's base move speed (2) closes to exactly
      // adjacent in one turn.
      final ctx = _setup(
        localPos: const HexCoord(0, 0),
        dummyPos: const HexCoord(0, 3),
        meleePicker: (candidates) async => candidates.first,
      );

      // Turn 1: self-target the priming spell (2 turns of "Draining Hits").
      await ctx.loop.runTurn(TurnInput(
        action: SpellCastAction(spell: _waterHaymaker(), targetHex: ctx.local.position),
      ));
      expect(
        ctx.local.activeStatusEffects
            .any((fx) => fx.effectTypeId == StatusEffectId.haymakerStatusDrain),
        isTrue,
      );

      // Give the dummy an unrelated status effect to observe getting drained.
      ctx.dummy.activeStatusEffects.add(StatusEffect(
        effectTypeId: StatusEffectId.speedDown,
        remainingTurns: 5,
        modifiers: const {'speedDelta': -1},
      ));

      // Turn 2: local moves adjacent and lands a haymaker on the dummy.
      await ctx.loop.runTurn(TurnInput(
        action: PassAction(),
        movePath: const [HexCoord(0, 1), HexCoord(0, 2)],
      ));

      final speedDown = ctx.dummy.activeStatusEffects
          .firstWhere((fx) => fx.effectTypeId == StatusEffectId.speedDown);
      expect(speedDown.remainingTurns, lessThan(5),
          reason: 'the primed haymaker punch should have stripped a turn from the '
              'dummy\'s status effects');
    });
  });
}
