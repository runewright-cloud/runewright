// SPDX-License-Identifier: GPL-3.0-or-later
//
// formula_generator.dart — PracticeFormula and PracticeFormulaGenerator.
//
// Practice-only: no entropy, no commit-reveal, no ZK. A formula is nothing
// is proven or wagered here, just dart:math Random.

import 'dart:math';

import '../sorcerer/vocal_score.dart';

/// A generated practice formula: [formulaCount] groups of 3 element words,
/// followed by a single [VocalWord.finitus] — the terminator is spoken once
/// per whole spell, matching real Sorcerer-mode casting
/// (lib/ui/battle_screen.dart's _onCast) and FormulaTracker's groups-of-3
/// convention (lib/engine/formula.dart), not once per group of 3.
class PracticeFormula {
  const PracticeFormula(this.words);

  final List<VocalWord> words;
}

class PracticeFormulaGenerator {
  PracticeFormulaGenerator({Random? random}) : _random = random ?? Random();

  final Random _random;

  static const List<VocalWord> _elements = [
    VocalWord.ignis,
    VocalWord.aer,
    VocalWord.aqua,
    VocalWord.terra,
  ];

  /// Generates a practice formula of [formulaCount] groups of 3 element
  /// words (1–3 groups, i.e. 3–9 spoken element words) plus one trailing
  /// [VocalWord.finitus].
  PracticeFormula generate({int formulaCount = 1}) {
    assert(formulaCount >= 1 && formulaCount <= 3,
        'formulaCount must be 1-3, got $formulaCount');
    final words = <VocalWord>[
      for (int i = 0; i < formulaCount * 3; i++)
        _elements[_random.nextInt(_elements.length)],
      VocalWord.finitus,
    ];
    return PracticeFormula(List.unmodifiable(words));
  }
}
