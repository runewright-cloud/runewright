// SPDX-License-Identifier: GPL-3.0-or-later
//
// target_tile_effects_test.dart — 2026-07-27 sweep: several spell effects
// used to hardcode ctx.caster as their recipient regardless of the spell's
// actual target tile. Design doc: nearly every effect lands on whoever
// occupies the TARGET tile ("tiles, not targets") -- self-target to buff
// yourself, an ally's tile to buff them, an enemy's tile if you're feeling
// generous (or reckless). This file pins each fix directly via
// EffectApplicator.apply(), mirroring effect_applicator_test.dart's style:
// Barrier, Speed Manipulation's highMobility/highLiquidity, Spell
// Interaction's Quick, Range Modification's Penetrating, Fuel Transmutation
// (all four flavors trade the RECIPIENT's own resources), and Artifacts
// Interaction's summon flavors (Earth/Water/Air).

import 'dart:math';

import 'package:test/test.dart';
import 'package:rune_duel/battle/engine/effect_applicator.dart';
import 'package:rune_duel/battle/models/battle_state.dart';
import 'package:rune_duel/battle/models/effect_descriptor.dart';
import 'package:rune_duel/battle/models/effect_kind.dart' show EffectKind;
import 'package:rune_duel/battle/models/hex_battlefield.dart' show Battlefield;
import 'package:rune_duel/battle/models/match_config.dart';
import 'package:rune_duel/battle/models/spell_effect.dart';
import 'package:rune_duel/battle/models/status_effect_ids.dart';
import 'package:rune_duel/battle/models/wizard_avatar.dart';
import 'package:rune_duel/engine/hex_grid.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

WizardAvatar _avatar(String id, HexCoord pos) => WizardAvatar(
      playerId: id,
      ownerPubkeyHex: '0x${'0' * 64}',
      hp: 24,
      mana: 100,
      maxMana: 100,
      position: pos,
      teamId: id,
      baseSpellRange: 3,
    );

BattleState _state(List<WizardAvatar> avatars, {int radius = 6}) {
  final battlefield = Battlefield(radius: radius);
  for (final a in avatars) {
    battlefield.occupancy[a.playerId] = a.position;
  }
  return BattleState(
    config: MatchConfig(gridRadius: radius),
    avatars: avatars,
    teams: const [],
    battlefield: battlefield,
    tileEffects: const {},
  );
}

ApplyContext _ctx({
  required BattleState state,
  required WizardAvatar caster,
  required SpellEffect effect,
  required HexCoord targetTile,
  SpellAffinity affinity = SpellAffinity.fire,
}) =>
    ApplyContext(
      descriptor: EffectDescriptor(
        affinity: affinity,
        effectKind: EffectKind.damage, // irrelevant to dispatch; apply() switches on effect's type
        spellEffect: effect,
      ),
      targetTile: targetTile,
      caster: caster,
      state: state,
      rng: Random(7),
    );

void main() {
  group('Barrier (Earth-Earth) targets the tile', () {
    test('lands on the enemy standing on the target tile, not the caster', () {
      final caster = _avatar('caster', const HexCoord(0, 0));
      final enemy = _avatar('enemy', const HexCoord(1, 0));
      final state = _state([caster, enemy]);

      EffectApplicator.apply(_ctx(
        state: state,
        caster: caster,
        effect: const BarrierEffect(hp: 4, durationTurns: 3),
        targetTile: enemy.position,
      ));

      expect(enemy.barriers[SpellAffinity.fire], isNotNull);
      expect(caster.barriers[SpellAffinity.fire], isNull);
    });
  });

  group('Speed Manipulation (Air-Air) highMobility/highLiquidity target the tile', () {
    test('highMobility lands on whoever is self-targeted, not an untargeted caster', () {
      final caster = _avatar('caster', const HexCoord(0, 0));
      final enemy = _avatar('enemy', const HexCoord(1, 0));
      final state = _state([caster, enemy]);

      EffectApplicator.apply(_ctx(
        state: state,
        caster: caster,
        effect: const SpeedManipulationEffect(
          affinity: SpellAffinity.fire,
          highMobility: true,
          freeExtraTiles: 1,
        ),
        targetTile: enemy.position,
      ));

      expect(
        enemy.activeStatusEffects.any((fx) => fx.effectTypeId == StatusEffectId.highMobility),
        isTrue,
      );
      expect(
        caster.activeStatusEffects.any((fx) => fx.effectTypeId == StatusEffectId.highMobility),
        isFalse,
      );
    });

    test('highLiquidity self-targeted lands on the caster', () {
      final caster = _avatar('caster', const HexCoord(0, 0));
      final state = _state([caster]);

      EffectApplicator.apply(_ctx(
        state: state,
        caster: caster,
        effect: const SpeedManipulationEffect(
          affinity: SpellAffinity.water,
          highLiquidity: true,
          freeExtraTiles: 1,
        ),
        targetTile: caster.position,
      ));

      expect(
        caster.activeStatusEffects.any((fx) => fx.effectTypeId == StatusEffectId.highLiquidity),
        isTrue,
      );
    });
  });

  group('Spell Interaction (Fire-Air) Quick targets the tile', () {
    test('lands on the enemy standing on the target tile, not the caster', () {
      final caster = _avatar('caster', const HexCoord(0, 0));
      final enemy = _avatar('enemy', const HexCoord(1, 0));
      final state = _state([caster, enemy]);

      EffectApplicator.apply(_ctx(
        state: state,
        caster: caster,
        effect: const SpellInteractionEffect(
          affinity: SpellAffinity.air,
          isQuickEffect: true,
          durationTurns: 2,
        ),
        targetTile: enemy.position,
      ));

      expect(
        enemy.activeStatusEffects.any((fx) => fx.effectTypeId == StatusEffectId.quick),
        isTrue,
      );
      expect(
        caster.activeStatusEffects.any((fx) => fx.effectTypeId == StatusEffectId.quick),
        isFalse,
      );
    });
  });

  group('Range Modification (Earth-Air) Penetrating targets the tile', () {
    test('lands on the enemy standing on the target tile, not the caster', () {
      final caster = _avatar('caster', const HexCoord(0, 0));
      final enemy = _avatar('enemy', const HexCoord(1, 0));
      final state = _state([caster, enemy]);

      EffectApplicator.apply(_ctx(
        state: state,
        caster: caster,
        effect: const RangeModificationEffect(
          affinity: SpellAffinity.fire,
          penetrating: true,
          penetrationDamage: 1,
          durationTurns: 2,
        ),
        targetTile: enemy.position,
      ));

      expect(
        enemy.activeStatusEffects.any((fx) => fx.effectTypeId == StatusEffectId.penetrating),
        isTrue,
      );
      expect(
        caster.activeStatusEffects.any((fx) => fx.effectTypeId == StatusEffectId.penetrating),
        isFalse,
      );
    });
  });

  group('Fuel Transmutation (Earth-Fire) trades the target\'s own resources', () {
    test('Water flavor burns mana / gains life on the enemy, not the caster', () {
      final caster = _avatar('caster', const HexCoord(0, 0));
      final enemy = _avatar('enemy', const HexCoord(1, 0));
      final casterManaBefore = caster.mana;
      final enemyManaBefore = enemy.mana;
      final enemyHpBefore = enemy.hp;
      final state = _state([caster, enemy]);

      EffectApplicator.apply(_ctx(
        state: state,
        caster: caster,
        effect: const FuelTransmutationEffect(
          affinity: SpellAffinity.water,
          burnMana: 20,
          gainLife: 4,
        ),
        targetTile: enemy.position,
      ));

      expect(enemy.mana, enemyManaBefore - 20);
      expect(enemy.hp, enemyHpBefore + 4);
      expect(caster.mana, casterManaBefore, reason: 'the caster\'s own resources are untouched');
    });

    test('self-targeted Water flavor trades the caster\'s own resources', () {
      final caster = _avatar('caster', const HexCoord(0, 0));
      final manaBefore = caster.mana;
      final hpBefore = caster.hp;
      final state = _state([caster]);

      EffectApplicator.apply(_ctx(
        state: state,
        caster: caster,
        effect: const FuelTransmutationEffect(
          affinity: SpellAffinity.water,
          burnMana: 20,
          gainLife: 4,
        ),
        targetTile: caster.position,
      ));

      expect(caster.mana, manaBefore - 20);
      expect(caster.hp, hpBefore + 4);
    });
  });

  group('Artifacts Interaction (Water-Earth) summon flavors target the tile', () {
    test('Water flavor (mana gems) lands on the enemy, not the caster', () {
      final caster = _avatar('caster', const HexCoord(0, 0));
      final enemy = _avatar('enemy', const HexCoord(1, 0));
      final state = _state([caster, enemy]);

      EffectApplicator.apply(_ctx(
        state: state,
        caster: caster,
        effect: const ArtifactsInteractionEffect(affinity: SpellAffinity.water, count: 1),
        targetTile: enemy.position,
      ));

      expect(enemy.manaGemsEquipped, 1);
      expect(caster.manaGemsEquipped, 0);
    });

    test('self-targeted Earth flavor (deflection totem) lands on the caster', () {
      final caster = _avatar('caster', const HexCoord(0, 0));
      final state = _state([caster]);

      EffectApplicator.apply(_ctx(
        state: state,
        caster: caster,
        effect: const ArtifactsInteractionEffect(affinity: SpellAffinity.earth, count: 1),
        targetTile: caster.position,
      ));

      expect(
        caster.accoutrements.any((a) => a.kind == AccoutrementKind.deflectionTotem),
        isTrue,
      );
    });

    test('Air flavor (bookmarks) lands on the enemy, not the caster', () {
      final caster = _avatar('caster', const HexCoord(0, 0));
      final enemy = _avatar('enemy', const HexCoord(1, 0));
      final state = _state([caster, enemy]);

      EffectApplicator.apply(_ctx(
        state: state,
        caster: caster,
        effect: const ArtifactsInteractionEffect(affinity: SpellAffinity.air, count: 2),
        targetTile: enemy.position,
      ));

      expect(enemy.accoutrements.where((a) => a.kind == AccoutrementKind.bookmark).length, 2);
      expect(caster.accoutrements.where((a) => a.kind == AccoutrementKind.bookmark).length, 0);
    });
  });
}
