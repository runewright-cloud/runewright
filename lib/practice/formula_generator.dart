// SPDX-License-Identifier: GPL-3.0-or-later
//
// formula_generator.dart — PracticeFormula and PracticeFormulaGenerator.
//
// Practice-only: no entropy, no commit-reveal, no ZK. Nothing is proven or
// wagered here, just dart:math Random.

import 'dart:math';

import '../sorcerer/vocal_slot.dart';

/// One incantation as a sequence of slots to speak.
///
/// Cast shape is `OPENER + 3n element words` (VOCAL_RECALL_PLAN.md §8.1).
/// The opener is spoken FIRST and marks the start of a cast, replacing the
/// retired trailing `finitus` terminator — a listener needs starts marked,
/// not ends (§8.4). Which of the two openers it is says whether this cast is
/// a summon, and that is the whole telegraph.
class PracticeFormula {
  const PracticeFormula(this.words);

  /// The full spoken sequence: `words.first` is always an opener, the rest
  /// are element slots in trajectory order.
  final List<VocalSlot> words;

  /// The opener this incantation starts with.
  VocalSlot get opener => words.first;

  /// The element slots, in trajectory order — everything after the opener.
  List<VocalSlot> get elements => words.sublist(1);

  /// Builds the incantation for a spell already in the library, from
  /// `SpellAsset.formula` (BorderZone enum names — 'fire'/'air'/'water'/
  /// 'earth') and `SpellAsset.isSummon`, so a player can drill the words
  /// that specific spell will actually need at cast time.
  ///
  /// Two things this must get right, both easy to get wrong:
  ///
  /// 1. **Truncate to complete triplets.** `SpellAsset.formula` stores
  ///    `FormulaTracker.committed` (see main.dart's inscribe call), which is
  ///    *every* activation including the 1–2 residuals that never filled a
  ///    group of three. Residuals form no formula and resolve to no effect
  ///    (`FormulaTracker.formulas` drops them), so reciting them would drill
  ///    words the cast never asks for.
  /// 2. **One leading opener for the whole spell**, chosen by [isSummon] —
  ///    not one per triplet, and never a trailing terminator.
  ///
  /// Note there is no upper bound here beyond the tier: `FormulaTracker.step`
  /// commits at most one activation per generation, so a tier-48 spell can
  /// legitimately reach 48 element words. The cost model handles that by
  /// normalising the step to the length; nothing here truncates it.
  ///
  /// Returns null if the spell has fewer than three activations (nothing
  /// castable to recite) or if any entry is not a recognised zone name.
  static PracticeFormula? fromSpellFormula(
    List<String> spellFormula, {
    bool isSummon = false,
  }) {
    final complete = (spellFormula.length ~/ 3) * 3;
    if (complete == 0) return null;
    final words = <VocalSlot>[VocalSlot.openerFor(isSummon: isSummon)];
    for (int i = 0; i < complete; i++) {
      final word = VocalSlot.fromAffinityZone(spellFormula[i]);
      if (word == null) return null;
      words.add(word);
    }
    return PracticeFormula(List.unmodifiable(words));
  }
}

class PracticeFormulaGenerator {
  PracticeFormulaGenerator({Random? random}) : _random = random ?? Random();

  final Random _random;

  /// Generates a practice formula of [formulaCount] groups of 3 element
  /// words (1–3 groups, i.e. 3–9 spoken element words), led by one opener.
  ///
  /// [isSummon] picks which opener; when omitted it is chosen at random, so
  /// drilling exercises both and a player can't learn to expect one.
  PracticeFormula generate({int formulaCount = 1, bool? isSummon}) {
    assert(formulaCount >= 1 && formulaCount <= 3,
        'formulaCount must be 1-3, got $formulaCount');
    final words = <VocalSlot>[
      VocalSlot.openerFor(isSummon: isSummon ?? _random.nextBool()),
      for (int i = 0; i < formulaCount * 3; i++)
        VocalSlot.elements[_random.nextInt(VocalSlot.elements.length)],
    ];
    return PracticeFormula(List.unmodifiable(words));
  }
}
