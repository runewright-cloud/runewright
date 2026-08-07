// SPDX-License-Identifier: GPL-3.0-or-later
//
// status_effect_stacking_test.dart — 2026-08-07 ruling: applying a status
// effect to an entity that already carries that effect EXTENDS it by the new
// application's duration instead of replacing it. Slow someone for 3 turns
// while 2 turns of slow are still on them and they have 5 turns of slow.
//
// The rule lives in one place (StatusEffect.applyTo) and everything that puts
// a status on an entity routes through it — EffectApplicator, TurnLoop, the
// wild-magic applicator. This file pins the primitive directly, then pins the
// spell path through EffectApplicator.apply() so a future refactor that
// reintroduces a second, replacing application path fails here.
//
// What deliberately does NOT stack: magnitude. One entry per effect id remains
// an invariant of activeStatusEffects — WizardAvatar.effectiveMoveSpeed sums
// every speedDelta it finds, so a second speedDown entry would double the
// debuff rather than extend it.

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
  SpellAffinity affinity = SpellAffinity.air,
}) =>
    ApplyContext(
      descriptor: EffectDescriptor(
        affinity: affinity,
        effectKind: EffectKind.damage, // apply() switches on the effect's type
        spellEffect: effect,
      ),
      targetTile: targetTile,
      caster: caster,
      state: state,
      rng: Random(11),
    );

StatusEffect _fx(List<StatusEffect> effects, String id) =>
    effects.singleWhere((fx) => fx.effectTypeId == id);

void main() {
  group('StatusEffect.applyTo', () {
    test('adds the effect when the entity does not carry it yet', () {
      final effects = <StatusEffect>[];
      StatusEffect.applyTo(
          effects, StatusEffectId.quick, const {'a': 1}, 3);

      expect(effects, hasLength(1));
      expect(effects.single.effectTypeId, StatusEffectId.quick);
      expect(effects.single.remainingTurns, 3);
      expect(effects.single.modifiers, const {'a': 1});
    });

    test('extends an existing effect by the new duration, in one entry', () {
      final effects = <StatusEffect>[];
      StatusEffect.applyTo(effects, StatusEffectId.sluggish, const {}, 2);
      StatusEffect.applyTo(effects, StatusEffectId.sluggish, const {}, 3);

      expect(effects, hasLength(1),
          reason: 'stacking is on duration only — a second entry of the same '
              'id would double every modifier the derived-stat getters sum');
      expect(effects.single.remainingTurns, 5);
    });

    test('extends what REMAINS, not the original duration', () {
      final av = _avatar('a', const HexCoord(0, 0));
      StatusEffect.applyTo(
          av.activeStatusEffects, StatusEffectId.turbulent, const {}, 3);
      av.tickStatusEffects(); // 3 → 2
      StatusEffect.applyTo(
          av.activeStatusEffects, StatusEffectId.turbulent, const {}, 3);

      expect(_fx(av.activeStatusEffects, StatusEffectId.turbulent).remainingTurns, 5);
    });

    test('the newest application supplies the modifiers', () {
      final effects = <StatusEffect>[];
      StatusEffect.applyTo(effects, StatusEffectId.speedDown,
          const {'speedDelta': -2}, 2);
      StatusEffect.applyTo(effects, StatusEffectId.speedDown,
          const {'speedDelta': -1}, 2);

      expect(effects.single.remainingTurns, 4);
      expect(effects.single.modifiers['speedDelta'], -1,
          reason: 'magnitude does not stack — the freshest cast sets it');
    });

    test('the refreshed entry moves to the end of the list', () {
      // chainAccumulationMultiplier walks activeStatusEffects in reverse and
      // takes the first chain effect it finds, so "most recently applied
      // wins" depends on a re-application landing at the end.
      final av = _avatar('a', const HexCoord(0, 0));
      StatusEffect.applyTo(av.activeStatusEffects, StatusEffectId.chainFast,
          const {'chainAccMultiplierPct': 200}, 3);
      StatusEffect.applyTo(av.activeStatusEffects, StatusEffectId.chainSlow,
          const {'chainAccMultiplierPct': 50}, 3);
      expect(av.chainAccumulationMultiplier, 0.5);

      StatusEffect.applyTo(av.activeStatusEffects, StatusEffectId.chainFast,
          const {'chainAccMultiplierPct': 200}, 3);
      expect(av.chainAccumulationMultiplier, 2.0);
      expect(_fx(av.activeStatusEffects, StatusEffectId.chainFast).remainingTurns, 6);
    });
  });

  group('spell effects stack duration through EffectApplicator', () {
    test('two Airy Speed Manipulation casts on one wizard sum their turns', () {
      final caster = _avatar('caster', const HexCoord(0, 0));
      final state = _state([caster]);
      const effect = SpeedManipulationEffect(
        affinity: SpellAffinity.air,
        speedDelta: 1,
        durationTurns: 2,
      );

      EffectApplicator.apply(_ctx(
          state: state,
          caster: caster,
          effect: effect,
          targetTile: caster.position));
      EffectApplicator.apply(_ctx(
          state: state,
          caster: caster,
          effect: effect,
          targetTile: caster.position));

      final speedUp = _fx(caster.activeStatusEffects, StatusEffectId.speedUp);
      expect(speedUp.remainingTurns, 4);
      expect(caster.effectiveMoveSpeed, 3,
          reason: 'duration stacked; the +1 magnitude did not');
    });

    test('a range debuff refreshed on a target extends rather than resets', () {
      final caster = _avatar('caster', const HexCoord(0, 0));
      final target = _avatar('target', const HexCoord(1, 0));
      final state = _state([caster, target]);
      const effect = RangeModificationEffect(
        affinity: SpellAffinity.earth,
        rangeDelta: -1,
        durationTurns: 2,
      );

      EffectApplicator.apply(_ctx(
          state: state,
          caster: caster,
          effect: effect,
          targetTile: target.position,
          affinity: SpellAffinity.earth));
      target.tickStatusEffects(); // 2 → 1
      EffectApplicator.apply(_ctx(
          state: state,
          caster: caster,
          effect: effect,
          targetTile: target.position,
          affinity: SpellAffinity.earth));

      final rangeDown =
          _fx(target.activeStatusEffects, StatusEffectId.rangeDown);
      expect(rangeDown.remainingTurns, 3);
      expect(target.effectiveSpellRange, 2);
    });
  });
}
