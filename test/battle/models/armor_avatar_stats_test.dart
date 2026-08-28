// SPDX-License-Identifier: GPL-3.0-or-later
//
// armor_avatar_stats_test.dart — Aetherial Armor as equipment on a
// WizardAvatar: the Air and Water bonuses inside the two authoritative
// effective-stat getters, the two keywords that are live as of engine v7
// (Charger -> hasHaymakerDistanceBonus, Muddy -> hasHaymakerSlow), and the
// proof that every OTHER keyword is still inert
// (docs/AETHERIAL_ARMOR.md §9, §11).

import 'package:test/test.dart';
import 'package:rune_duel/battle/models/certified_armor.dart';
import 'package:rune_duel/battle/models/status_effect_ids.dart';
import 'package:rune_duel/battle/models/wizard_avatar.dart';
import 'package:rune_duel/engine/hex_grid.dart';

import 'certified_armor_fixture.dart';

WizardAvatar _wizard({CertifiedArmor? armor, int baseSpellRange = 3}) =>
    WizardAvatar(
      playerId: 'w',
      ownerPubkeyHex: '0x${'0' * 64}',
      hp: 24,
      mana: 100,
      maxMana: 100,
      position: const HexCoord(0, 0),
      teamId: 't',
      baseSpellRange: baseSpellRange,
      armor: armor,
    );

void _addStatus(WizardAvatar av, String id, Map<String, int> mods) {
  av.activeStatusEffects.add(StatusEffect(
    effectTypeId: id,
    remainingTurns: 5,
    modifiers: mods,
  ));
}

void main() {
  group('no armor changes nothing', () {
    test('an unarmored wizard has the pre-armor stats', () {
      final av = _wizard();
      expect(av.armor, isNull);
      expect(av.effectiveMoveSpeed, 2, reason: 'the base move speed');
      expect(av.effectiveSpellRange, 3, reason: 'baseSpellRange, untouched');
    });

    test('an armor with no ladder rung reached adds nothing', () {
      // Three fires is below the first rung (4), so every bonus is 0 and the
      // armor is real but silent. This is the case that would hide a bug where
      // "wearing anything" rather than the ladder drove the stat.
      final av = _wizard(armor: armorOf('FFF'));
      expect(av.armor!.meleeBonus, 0);
      expect(av.effectiveMoveSpeed, 2);
      expect(av.effectiveSpellRange, 3);
    });
  });

  group('Air -> effectiveMoveSpeed', () {
    test('four airs is +1 move', () {
      final av = _wizard(armor: armorOf(kAirArmorCodes));
      expect(av.armor!.moveSpeedBonus, 1);
      expect(av.effectiveMoveSpeed, 3, reason: 'base 2 + armor 1');
    });

    test('a higher rung carries through', () {
      final av = _wizard(armor: armorOf(runOfCode('A', 18)));
      expect(av.armor!.moveSpeedBonus, 3);
      expect(av.effectiveMoveSpeed, 5);
    });

    test('composes additively with a speed status effect', () {
      final av = _wizard(armor: armorOf(kAirArmorCodes));
      _addStatus(av, StatusEffectId.speedDown, {'speedDelta': -1});
      expect(av.effectiveMoveSpeed, 2,
          reason: 'armor +1 and a −1 slow cancel; neither replaces the other');
    });

    test('a slow deeper than the armor still floors at 0, never negative', () {
      final av = _wizard(armor: armorOf(kAirArmorCodes));
      _addStatus(av, StatusEffectId.speedDown, {'speedDelta': -9});
      expect(av.effectiveMoveSpeed, 0);
    });
  });

  group('Water -> effectiveSpellRange', () {
    test('four waters is +1 range', () {
      final av = _wizard(armor: armorOf(kWaterArmorCodes));
      expect(av.armor!.spellRangeBonus, 1);
      expect(av.effectiveSpellRange, 4, reason: 'base 3 + armor 1');
    });

    test('a higher rung carries through', () {
      final av = _wizard(armor: armorOf(runOfCode('W', 10)));
      expect(av.armor!.spellRangeBonus, 2);
      expect(av.effectiveSpellRange, 5);
    });

    test('composes additively with a range status effect', () {
      final av = _wizard(armor: armorOf(runOfCode('W', 10)));
      _addStatus(av, StatusEffectId.rangeDown, {'rangeDelta': -1});
      expect(av.effectiveSpellRange, 4, reason: 'base 3 + armor 2 − 1');
    });

    test('the armor does not raise the base of an unrelated stat', () {
      final av = _wizard(armor: armorOf(runOfCode('W', 10)));
      expect(av.effectiveMoveSpeed, 2,
          reason: 'a Water armor is worth no movement at all');
    });
  });

  group('Charger -> hasHaymakerDistanceBonus (engine v7)', () {
    test('a certified Charger armor grants the capability', () {
      final av = _wizard(armor: armorOf('FAFA'));
      expect(av.armor!.hasKeyword(ArmorKeyword.charger), isTrue);
      expect(av.hasHaymakerDistanceBonus, isTrue);
    });

    test('the pre-armor status source still grants it on its own', () {
      final av = _wizard();
      expect(av.hasHaymakerDistanceBonus, isFalse);
      _addStatus(av, StatusEffectId.haymakerDistanceBonus, const {});
      expect(av.hasHaymakerDistanceBonus, isTrue,
          reason: 'the Air haymaker buff must keep working without armor');
    });

    test('a dormant or expired status does not suppress armor Charger', () {
      // The status source going away — or going dormant — must not take the
      // armor's grant with it: they are independent sources of one capability.
      final av = _wizard(armor: armorOf('FAFA'));
      final fx = StatusEffect(
        effectTypeId: StatusEffectId.haymakerDistanceBonus,
        remainingTurns: 5,
      );
      av.activeStatusEffects.add(fx);
      expect(av.hasHaymakerDistanceBonus, isTrue);
      fx.isDormant = true;
      expect(av.hasHaymakerDistanceBonus, isTrue,
          reason: 'the armor still grants it while the status sleeps');
      av.activeStatusEffects.clear();
      expect(av.hasHaymakerDistanceBonus, isTrue,
          reason: 'and still after the status is gone entirely');
    });

    test('an armor without Charger grants nothing', () {
      final av = _wizard(armor: armorOf(kFireArmorCodes));
      expect(av.armor!.hasKeyword(ArmorKeyword.charger), isFalse);
      expect(av.hasHaymakerDistanceBonus, isFalse);
    });
  });

  group('Muddy -> hasHaymakerSlow (engine v7)', () {
    test('a certified Muddy armor grants the capability', () {
      final av = _wizard(armor: armorOf('WEWE'));
      expect(av.armor!.hasKeyword(ArmorKeyword.muddy), isTrue);
      expect(av.hasHaymakerSlow, isTrue);
    });

    test('the pre-armor status source still grants it on its own', () {
      final av = _wizard();
      expect(av.hasHaymakerSlow, isFalse);
      _addStatus(av, StatusEffectId.haymakerSlow, const {});
      expect(av.hasHaymakerSlow, isTrue,
          reason: 'the Earth haymaker buff must keep working without armor');
    });

    test('a dormant or expired status does not suppress armor Muddy', () {
      final av = _wizard(armor: armorOf('WEWE'));
      final fx = StatusEffect(
        effectTypeId: StatusEffectId.haymakerSlow,
        remainingTurns: 5,
      );
      av.activeStatusEffects.add(fx);
      fx.isDormant = true;
      expect(av.hasHaymakerSlow, isTrue);
      av.activeStatusEffects.clear();
      expect(av.hasHaymakerSlow, isTrue);
    });

    test('an armor without Muddy grants nothing', () {
      final av = _wizard(armor: armorOf(kEarthArmorCodes));
      expect(av.armor!.hasKeyword(ArmorKeyword.muddy), isFalse);
      expect(av.hasHaymakerSlow, isFalse);
    });

    test('Charger and Muddy are independent grants', () {
      final charger = _wizard(armor: armorOf('FAFA'));
      expect(charger.hasHaymakerDistanceBonus, isTrue);
      expect(charger.hasHaymakerSlow, isFalse,
          reason: 'Charger must not drag the slow along with it');

      final muddy = _wizard(armor: armorOf('WEWE'));
      expect(muddy.hasHaymakerSlow, isTrue);
      expect(muddy.hasHaymakerDistanceBonus, isFalse);
    });
  });

  group('every other keyword is canonical but completely inert', () {
    test('certified Flying does not make the wizard fly', () {
      final av = _wizard(armor: armorOf(kAirArmorCodes));
      expect(av.armor!.hasKeyword(ArmorKeyword.flying), isTrue,
          reason: 'AAAA is the Flying pattern — the keyword IS certified');
      expect(av.isFlying, isFalse,
          reason: 'isFlying derives solely from the Flying STATUS effect; '
              'wiring the armor keyword to it is exactly the opportunistic '
              'connection slice 5 forbids');
    });

    test('the Flying status still works, so the check above is not vacuous', () {
      final av = _wizard(armor: armorOf(kAirArmorCodes));
      _addStatus(av, StatusEffectId.flying, const {});
      expect(av.isFlying, isTrue);
    });

    test('certified Cleave is present and drives nothing', () {
      // The Pixel hardware fixture's armor is exactly this shape: seven fires,
      // so `[cleave]` plus a real melee bonus. It must punch harder and must
      // not cleave.
      final av = _wizard(armor: armorOf(runOfCode('F', 7)));
      expect(av.armor!.hasKeyword(ArmorKeyword.cleave), isTrue);
      expect(av.armor!.meleeBonus, 1);
      expect(av.effectiveMoveSpeed, 2);
      expect(av.effectiveSpellRange, 3);
    });

    test('each keyword flips exactly the hooks it has been approved for', () {
      // The blanket version of the checks above, and the gate on the next
      // keyword: whichever keyword is certified, the ONLY hook it may flip is
      // the one this table approves for it. Slice 6 approved two
      // (docs/AETHERIAL_ARMOR.md §11); every other keyword must still leave
      // all ten false. A keyword added to the enum — or quietly wired to a
      // hook — fails here rather than silently acquiring behaviour.
      const codes = {
        ArmorKeyword.flying: 'AAAA',
        ArmorKeyword.cleave: 'FFFF',
        ArmorKeyword.charger: 'FAFA',
        ArmorKeyword.muddy: 'WEWE',
        ArmorKeyword.moltenCarapace: 'EFEF',
        ArmorKeyword.stealthy: 'AWAW',
        ArmorKeyword.anchored: 'EEEE',
      };
      expect(codes.keys.toSet(), ArmorKeyword.values.toSet(),
          reason: 'a keyword added to the enum needs a case here');

      // keyword -> the single hook it is allowed to turn true. Absent means
      // "inert": no hook at all.
      const approved = {
        ArmorKeyword.charger: 'hasHaymakerDistanceBonus',
        ArmorKeyword.muddy: 'hasHaymakerSlow',
      };

      for (final entry in codes.entries) {
        final av = _wizard(armor: armorOf(entry.value));
        expect(av.armor!.hasKeyword(entry.key), isTrue,
            reason: '${entry.value} must certify ${entry.key.name}');
        final hooks = <String, bool>{
          'isFlying': av.isFlying,
          'hasHaymakerDistanceBonus': av.hasHaymakerDistanceBonus,
          'hasHaymakerSlow': av.hasHaymakerSlow,
          'hasHaymakerDot': av.hasHaymakerDot,
          'hasHaymakerStatusDrain': av.hasHaymakerStatusDrain,
          'hasPenetrating': av.hasPenetrating,
          'hasTurbulent': av.hasTurbulent,
          'isSluggish': av.isSluggish,
          'isQuick': av.isQuick,
          'canRevealCounterCharms': av.canRevealCounterCharms,
        };
        final live = approved[entry.key];
        if (live != null) {
          expect(hooks[live], isTrue,
              reason: '${entry.key.name} is approved to drive $live');
        }
        for (final hook in hooks.entries) {
          if (hook.key == live) continue;
          expect(hook.value, isFalse,
              reason: '${entry.key.name} must not touch ${hook.key}');
        }
      }
    });

    test('Morphic (WWWW) still grants no keyword at all', () {
      final av = _wizard(armor: armorOf('WWWW'));
      expect(av.armor!.keywords, isEmpty,
          reason: 'Morphic is designed but unbuilt — WWWW must stay bare');
    });
  });

  group('armor HP provenance', () {
    test('the granted HP stays readable through avatar.armor', () {
      // No mutable `armorHpBonus` copy is kept on the avatar; the armor object
      // itself is the record, which is what a later armor-breaking mechanic
      // will need to strip exactly what was granted.
      final av = _wizard(armor: armorOf(runOfCode('E', 12)));
      expect(av.armor!.armorHpBonus, 8);
    });
  });
}
