// SPDX-License-Identifier: GPL-3.0-or-later
//
// formula_generator_test.dart — unit tests for PracticeFormulaGenerator
// (lib/practice/formula_generator.dart). No entropy, no ZK — just checks
// the Random-only generation shape and grammar (groups of 3 + one trailing
// finitus).

import 'dart:math';

import 'package:test/test.dart';
import 'package:rune_duel/practice/formula_generator.dart';
import 'package:rune_duel/sorcerer/vocal_score.dart';

const _elements = {VocalWord.ignis, VocalWord.aer, VocalWord.aqua, VocalWord.terra};

void main() {
  group('generate', () {
    for (final k in [1, 2, 3]) {
      test('formulaCount=$k produces ${k * 3} element words + one finitus', () {
        final generator = PracticeFormulaGenerator(random: Random(42));
        final formula = generator.generate(formulaCount: k);
        expect(formula.words.length, k * 3 + 1);
        expect(formula.words.last, VocalWord.finitus);
        for (final w in formula.words.sublist(0, k * 3)) {
          expect(_elements.contains(w), isTrue, reason: '$w should be an element word');
        }
      });
    }

    test('finitus never appears before the final word', () {
      final generator = PracticeFormulaGenerator(random: Random(7));
      final formula = generator.generate(formulaCount: 3);
      for (final w in formula.words.sublist(0, formula.words.length - 1)) {
        expect(w, isNot(VocalWord.finitus));
      }
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
}
