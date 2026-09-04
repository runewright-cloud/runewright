// SPDX-License-Identifier: GPL-3.0-or-later
//
// creature_spec_test.dart — Unit tests for CreatureSpec.fromElements (design
// doc v3.0 "Summons"): stat formula boundaries, affinity + tiebreak,
// all 8 ability patterns (incl. overlap), Morphic reform, and the
// resistance wheel.

import 'package:test/test.dart';
import 'package:rune_duel/battle/models/creature_spec.dart';
import 'package:rune_duel/battle/models/effect_kind.dart' show SpellAffinity;
// The display helpers moved to `summon_lexicon.dart` in Slice F: they read a
// leyline (the ability clause is the rekeyed half) and `CreatureSpec`
// deliberately cannot.
import 'package:rune_duel/battle/models/summon_lexicon.dart'
    show summonSummaryFromFormula, summonSummaryLabel;
import 'package:rune_duel/engine/border_zone.dart';

List<BorderZone> _seq(String s) => s.split('').map((c) => switch (c) {
      'F' => BorderZone.fire,
      'A' => BorderZone.air,
      'W' => BorderZone.water,
      'E' => BorderZone.earth,
      _ => throw ArgumentError('bad char $c'),
    }).toList();

void main() {
  group('CreatureSpec.fromElements — empty input', () {
    test('empty sequence returns null', () {
      expect(CreatureSpec.fromElements([]), isNull);
    });
  });

  group('CreatureSpec.fromElements — stat formula boundaries', () {
    // damage/moveSpeed: floor(count * 0.5) == count ~/ 2, no minimum floor.
    test('fire count 0 -> damage 0 (no fire in sequence)', () {
      final spec = CreatureSpec.fromElements(_seq('E'))!;
      expect(spec.stats.damage, 0);
    });
    test('fire count 1 -> damage 0 (below multiplier boundary)', () {
      final spec = CreatureSpec.fromElements(_seq('F'))!;
      expect(spec.stats.damage, 0);
    });
    test('fire count 2 -> damage 1', () {
      final spec = CreatureSpec.fromElements(_seq('FF'))!;
      expect(spec.stats.damage, 1);
    });
    test('fire count 3 -> damage 1 (below next boundary)', () {
      final spec = CreatureSpec.fromElements(_seq('FFF'))!;
      expect(spec.stats.damage, 1);
    });
    test('fire count 4 -> damage 2', () {
      final spec = CreatureSpec.fromElements(_seq('FFFF'))!;
      expect(spec.stats.damage, 2);
    });
    test('fire count 7 -> damage 3', () {
      final spec = CreatureSpec.fromElements(_seq('FFFFFFF'))!;
      expect(spec.stats.damage, 3);
    });
    test('fire count 8 -> damage 4', () {
      final spec = CreatureSpec.fromElements(_seq('FFFFFFFF'))!;
      expect(spec.stats.damage, 4);
    });

    test('air count mirrors fire formula for moveSpeed', () {
      expect(CreatureSpec.fromElements(_seq('AAAA'))!.stats.moveSpeed, 2);
      expect(CreatureSpec.fromElements(_seq('AAA'))!.stats.moveSpeed, 1);
    });

    // attackRange: floor(count * 1/3) == count ~/ 3 (exact 1/3, not literal
    // 0.33 -- avoids a float boundary bug at exact multiples of 3), no
    // minimum floor.
    test('water count 0 -> range 0', () {
      final spec = CreatureSpec.fromElements(_seq('E'))!;
      expect(spec.stats.attackRange, 0);
    });
    test('water count 2 -> range 0 (below 1/3 boundary)', () {
      final spec = CreatureSpec.fromElements(_seq('WW'))!;
      expect(spec.stats.attackRange, 0);
    });
    test('water count 3 -> range 1 (exact 1/3 boundary)', () {
      final spec = CreatureSpec.fromElements(_seq('WWW'))!;
      expect(spec.stats.attackRange, 1);
    });
    test('water count 8 -> range 2 (below next boundary)', () {
      final spec = CreatureSpec.fromElements(_seq('WWWWWWWW'))!;
      expect(spec.stats.attackRange, 2);
    });
    test('water count 9 -> range 3 (exact 1/3 boundary)', () {
      final spec = CreatureSpec.fromElements(_seq('WWWWWWWWW'))!;
      expect(spec.stats.attackRange, 3);
    });

    // maxHp: floor(earthCount * 1) == earthCount, no minimum floor.
    test('earth count 0 -> hp 0', () {
      final spec = CreatureSpec.fromElements(_seq('F'))!;
      expect(spec.stats.maxHp, 0);
    });
    test('earth count 5 -> hp 5 (linear)', () {
      final spec = CreatureSpec.fromElements(_seq('EEEEE'))!;
      expect(spec.stats.maxHp, 5);
    });
  });

  group('CreatureSpec.fromElements — affinity', () {
    test('most-common element wins', () {
      final spec = CreatureSpec.fromElements(_seq('FFFA'))!;
      expect(spec.affinity, SpellAffinity.fire);
    });
    test('tie broken by first appearance', () {
      // fire appears first among the tied (fire, water) pair.
      expect(CreatureSpec.fromElements(_seq('FWFW'))!.affinity, SpellAffinity.fire);
      // water appears first this time.
      expect(CreatureSpec.fromElements(_seq('WFWF'))!.affinity, SpellAffinity.water);
    });
    test('single-element sequence', () {
      expect(CreatureSpec.fromElements(_seq('A'))!.affinity, SpellAffinity.air);
    });
  });

  group('CreatureSpec.fromElements — ability patterns', () {
    test('AAAA -> flying', () {
      expect(CreatureSpec.fromElements(_seq('AAAA'))!.abilities, contains(SummonAbility.flying));
    });
    test('FFFF -> cleave', () {
      expect(CreatureSpec.fromElements(_seq('FFFF'))!.abilities, contains(SummonAbility.cleave));
    });
    test('EEEE -> big', () {
      expect(CreatureSpec.fromElements(_seq('EEEE'))!.abilities, contains(SummonAbility.big));
    });
    test('WWWW -> morphic', () {
      expect(CreatureSpec.fromElements(_seq('WWWW'))!.abilities, contains(SummonAbility.morphic));
    });
    test('FAFA -> charger', () {
      expect(CreatureSpec.fromElements(_seq('FAFA'))!.abilities, contains(SummonAbility.charger));
    });
    test('AWAW -> stealthy', () {
      expect(CreatureSpec.fromElements(_seq('AWAW'))!.abilities, contains(SummonAbility.stealthy));
    });
    test('WEWE -> muddy', () {
      expect(CreatureSpec.fromElements(_seq('WEWE'))!.abilities, contains(SummonAbility.muddy));
    });
    test('EFEF -> moltenCarapace', () {
      expect(CreatureSpec.fromElements(_seq('EFEF'))!.abilities,
          contains(SummonAbility.moltenCarapace));
    });
    test('no pattern present -> no abilities', () {
      expect(CreatureSpec.fromElements(_seq('FAW'))!.abilities, isEmpty);
    });
    test('pattern can appear as a substring of a longer sequence', () {
      expect(CreatureSpec.fromElements(_seq('WFFFFW'))!.abilities, contains(SummonAbility.cleave));
    });
    test('overlapping occurrences still register once ("element may be used more than once")', () {
      // FAFAFA contains FAFA starting at index 0 and index 2.
      final abilities = CreatureSpec.fromElements(_seq('FAFAFA'))!.abilities;
      expect(abilities, contains(SummonAbility.charger));
    });
    test('multiple distinct abilities can co-occur', () {
      final abilities = CreatureSpec.fromElements(_seq('AAAAFFFF'))!.abilities;
      expect(abilities, containsAll([SummonAbility.flying, SummonAbility.cleave]));
    });
  });

  group('morphicReducedSequence', () {
    int fixedNextInt(int max) => 0; // deterministic stand-in for a seeded RNG

    test('halves the sequence length, rounded down', () {
      final original = _seq('FFAAWWEE'); // length 8
      final reduced = morphicReducedSequence(original, fixedNextInt);
      expect(reduced, isNotNull);
      expect(reduced!.length, 4);
    });

    test('odd-length sequence rounds down', () {
      final original = _seq('FAW'); // length 3 -> half = 1
      final reduced = morphicReducedSequence(original, fixedNextInt);
      expect(reduced!.length, 1);
    });

    test('length 1 sequence reforms to nothing (half = 0)', () {
      final original = _seq('F');
      expect(morphicReducedSequence(original, fixedNextInt), isNull);
    });

    test('length 0 sequence reforms to nothing', () {
      expect(morphicReducedSequence([], fixedNextInt), isNull);
    });

    test('preserves relative order of chosen elements', () {
      final original = _seq('FAWE');
      // A no-op shuffle (identity permutation) via nextInt always returning 0
      // on the Fisher-Yates walk still exercises ordering; verify the result
      // is always a subsequence of the original in original order.
      final reduced = morphicReducedSequence(original, fixedNextInt)!;
      var searchFrom = 0;
      for (final z in reduced) {
        final idx = original.indexOf(z, searchFrom);
        expect(idx, greaterThanOrEqualTo(searchFrom));
        searchFrom = idx + 1;
      }
    });

    test('result is deterministic given the same RNG sequence', () {
      final original = _seq('FFAAWWEE');
      final calls = <int>[3, 2, 1, 0, 0, 0, 0];
      var i = 0;
      int scriptedNextInt(int max) => calls[i++] % max;
      i = 0;
      final r1 = morphicReducedSequence(original, scriptedNextInt);
      i = 0;
      final r2 = morphicReducedSequence(original, scriptedNextInt);
      expect(r1, equals(r2));
    });

    test('always keeps at least one Earth when the original has one, across '
        'every RNG draw (design decision 2026-07-18: no stillborn reforms)', () {
      // WWWW FF EE: half = 4, drawn from a pool where a fully-random pick
      // has a real chance (~21%) of excluding both Earth activations --
      // this is exactly the scenario that used to spawn a 0-maxHp successor.
      final original = _seq('WWWWFFEE');
      for (var seed = 0; seed < 500; seed++) {
        var i = seed; // vary the "RNG" deterministically per iteration
        int nextInt(int max) => (i++) % max;
        final reduced = morphicReducedSequence(original, nextInt)!;
        expect(reduced, contains(BorderZone.earth),
            reason: 'seed $seed produced a reform with no Earth at all');
      }
    });

    test('falls back to fully random selection when the original has zero '
        'Earth (nothing to reserve)', () {
      final original = _seq('WWWWFF'); // no Earth anywhere in the source
      final reduced = morphicReducedSequence(original, (max) => 0)!;
      expect(reduced.length, 3); // half = 3, unaffected by the Earth guarantee
      expect(reduced, isNot(contains(BorderZone.earth)));
    });
  });

  group('resistance wheel', () {
    test('same element -> half damage rounded up', () {
      expect(applyResistance(3, SpellAffinity.fire, SpellAffinity.fire), 2);
      expect(applyResistance(4, SpellAffinity.fire, SpellAffinity.fire), 2);
      expect(applyResistance(1, SpellAffinity.water, SpellAffinity.water), 1);
    });
    test('opposite element -> double damage', () {
      expect(applyResistance(2, SpellAffinity.water, SpellAffinity.fire), 4);
      expect(applyResistance(2, SpellAffinity.fire, SpellAffinity.water), 4);
      expect(applyResistance(3, SpellAffinity.earth, SpellAffinity.air), 6);
      expect(applyResistance(3, SpellAffinity.air, SpellAffinity.earth), 6);
    });
    test('adjacent elements -> normal damage', () {
      expect(applyResistance(5, SpellAffinity.air, SpellAffinity.fire), 5);
      expect(applyResistance(5, SpellAffinity.earth, SpellAffinity.fire), 5);
      expect(applyResistance(5, SpellAffinity.fire, SpellAffinity.air), 5);
      expect(applyResistance(5, SpellAffinity.fire, SpellAffinity.earth), 5);
    });
    test('resistanceTierOf matches applyResistance behaviour', () {
      expect(resistanceTierOf(SpellAffinity.fire, SpellAffinity.fire),
          ResistanceTier.resistant);
      expect(resistanceTierOf(SpellAffinity.fire, SpellAffinity.water),
          ResistanceTier.vulnerable);
      expect(resistanceTierOf(SpellAffinity.fire, SpellAffinity.air), ResistanceTier.normal);
    });
  });

  group('display helpers (battle_screen.dart / library_screen.dart / main.dart captions)', () {
    test('summonSummaryLabel omits the ability clause when there are no abilities', () {
      final spec = CreatureSpec.fromElements(_seq('FFFF'))!; // damage 2, no other stats up
      final label = summonSummaryLabel(spec);
      expect(label, 'Fire Creature · HP 0 · DMG 2 · Move 0 · Range 0 · Cleave');
    });

    test('summonSummaryLabel includes a joined ability clause when present', () {
      final spec = CreatureSpec.fromElements(_seq('AAAA'))!; // AAAA -> flying
      final label = summonSummaryLabel(spec);
      expect(label, contains('Flying'));
      expect(label, startsWith('Air Creature ·'));
    });

    test('summonSummaryLabel with multiple abilities joins them with ", "', () {
      final spec = CreatureSpec.fromElements(_seq('AAAAFFFF'))!; // flying + cleave
      final label = summonSummaryLabel(spec);
      expect(label, endsWith('Flying, Cleave'));
    });

    test('summonSummaryFromFormula parses zone-name strings and matches summonSummaryLabel', () {
      final fromZones = summonSummaryLabel(CreatureSpec.fromElements(_seq('FFFF'))!);
      final fromFormula = summonSummaryFromFormula(['fire', 'fire', 'fire', 'fire']);
      expect(fromFormula, fromZones);
    });

    test('summonSummaryFromFormula is case-insensitive on zone names', () {
      expect(summonSummaryFromFormula(['Fire', 'FIRE', 'fire', 'fire']),
          summonSummaryFromFormula(['fire', 'fire', 'fire', 'fire']));
    });

    test('summonSummaryFromFormula returns null for an empty/void formula', () {
      expect(summonSummaryFromFormula([]), isNull);
    });

    test('summonSummaryFromFormula ignores unrecognized zone-name entries', () {
      expect(summonSummaryFromFormula(['not-a-zone']), isNull);
    });
  });
}
