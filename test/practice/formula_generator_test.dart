// SPDX-License-Identifier: GPL-3.0-or-later
//
// formula_generator_test.dart — unit tests for PracticeFormulaGenerator
// (lib/practice/formula_generator.dart). No entropy, no ZK — just checks
// the Random-only generation shape and grammar: one LEADING opener plus
// groups of 3 element words (VOCAL_RECALL_PLAN.md §8.1).

import 'dart:math';

import 'package:test/test.dart';
import 'package:rune_duel/practice/formula_generator.dart';
import 'package:rune_duel/sorcerer/vocal_slot.dart';

void main() {
  group('generate', () {
    for (final k in [1, 2, 3]) {
      test('formulaCount=$k produces one opener + ${k * 3} element words', () {
        final generator = PracticeFormulaGenerator(random: Random(42));
        final formula = generator.generate(formulaCount: k);
        expect(formula.words.length, k * 3 + 1);
        expect(formula.words.first.isOpener, isTrue);
        expect(formula.elements.length, k * 3);
        for (final w in formula.elements) {
          expect(w.isElement, isTrue, reason: '$w should be an element word');
        }
      });
    }

    test('an opener never appears after the first word', () {
      final generator = PracticeFormulaGenerator(random: Random(7));
      final formula = generator.generate(formulaCount: 3);
      for (final w in formula.elements) {
        expect(w.isOpener, isFalse);
      }
    });

    test('isSummon picks which opener leads', () {
      final generator = PracticeFormulaGenerator(random: Random(3));
      expect(generator.generate(isSummon: true).opener,
          VocalSlot.openerSummon);
      expect(generator.generate(isSummon: false).opener,
          VocalSlot.openerGeneral);
    });

    test('rejects formulaCount outside 1-3', () {
      final generator = PracticeFormulaGenerator(random: Random(1));
      expect(() => generator.generate(formulaCount: 0), throwsA(isA<AssertionError>()));
      expect(() => generator.generate(formulaCount: 4), throwsA(isA<AssertionError>()));
    });

    test('a seeded Random makes generation deterministic', () {
      final a = PracticeFormulaGenerator(random: Random(99)).generate(formulaCount: 2);
      final b = PracticeFormulaGenerator(random: Random(99)).generate(formulaCount: 2);
      expect(a.words, equals(b.words));
    });
  });

  group('fromSpellFormula', () {
    test('leads with an opener, then maps zone names in order', () {
      final formula =
          PracticeFormula.fromSpellFormula(['fire', 'earth', 'water']);
      expect(formula!.words, [
        VocalSlot.openerGeneral,
        VocalSlot.fire,
        VocalSlot.earth,
        VocalSlot.water,
      ]);
    });

    test('a summon spell leads with the summon opener', () {
      final formula = PracticeFormula.fromSpellFormula(
          ['fire', 'earth', 'water'],
          isSummon: true);
      expect(formula!.opener, VocalSlot.openerSummon);
      expect(formula.elements, [
        VocalSlot.fire,
        VocalSlot.earth,
        VocalSlot.water,
      ]);
    });

    test('a three-formula spell yields one opener + 9 element words', () {
      final formula = PracticeFormula.fromSpellFormula([
        'fire', 'earth', 'water',
        'air', 'fire', 'earth',
        'water', 'air', 'fire',
      ]);
      expect(formula!.words.length, 10);
      expect(formula.opener.isOpener, isTrue);
      expect(
        formula.elements.any((w) => w.isOpener),
        isFalse,
        reason: 'the opener is spoken once for the whole spell, not per triplet',
      );
    });

    // A tier-48 spell can commit one activation per generation, so the drill
    // must handle far more than the 9 words the original design assumed.
    test('handles a 48-element trajectory without truncating', () {
      final formula = PracticeFormula.fromSpellFormula(
        List.generate(48, (i) => ['fire', 'air', 'water', 'earth'][i % 4]),
      );
      expect(formula!.elements.length, 48);
      expect(formula.words.length, 49);
    });

    // SpellAsset.formula stores FormulaTracker.committed, which includes the
    // 1-2 trailing activations that never completed a group of 3. Those form
    // no formula and resolve to no effect, so the drill must not ask for them.
    test('drops residual activations that complete no triplet', () {
      final formula = PracticeFormula.fromSpellFormula(
          ['fire', 'earth', 'water', 'air', 'fire']);
      expect(formula!.words, [
        VocalSlot.openerGeneral,
        VocalSlot.fire,
        VocalSlot.earth,
        VocalSlot.water,
      ]);
    });

    test('returns null when no complete triplet exists', () {
      expect(PracticeFormula.fromSpellFormula([]), isNull);
      expect(PracticeFormula.fromSpellFormula(['fire']), isNull);
      expect(PracticeFormula.fromSpellFormula(['fire', 'earth']), isNull);
    });

    test('returns null on an unrecognised zone name', () {
      expect(
        PracticeFormula.fromSpellFormula(['fire', 'neutral', 'water']),
        isNull,
      );
    });

    test('accepts all four zone names', () {
      final formula = PracticeFormula.fromSpellFormula(
          ['fire', 'air', 'water', 'earth', 'fire', 'air']);
      expect(formula!.words, [
        VocalSlot.openerGeneral,
        VocalSlot.fire,
        VocalSlot.air,
        VocalSlot.water,
        VocalSlot.earth,
        VocalSlot.fire,
        VocalSlot.air,
      ]);
    });
  });
}
