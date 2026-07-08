// SPDX-License-Identifier: GPL-3.0-or-later
//
// Tests for elementSymbolsFor — the elemental-symbol allocation that surrounds
// a spell's heraldic shield. The two worked examples come straight from the
// feature spec.
import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/ui/spell_card_painter.dart';

/// Builds a flat formula whose effect affinities (first-of-triplet) match the
/// requested per-element effect counts. The 2nd/3rd triplet entries are
/// irrelevant to the affinity ratio, so they reuse the affinity element.
List<String> formulaWithEffects(Map<String, int> effectCounts) {
  final out = <String>[];
  effectCounts.forEach((element, n) {
    for (var i = 0; i < n; i++) {
      out.addAll([element, element, element]);
    }
  });
  return out;
}

Map<String, int> singleCounts(List<List<String>> symbols) {
  final m = <String, int>{};
  for (final s in symbols.where((s) => s.length == 1)) {
    m[s[0]] = (m[s[0]] ?? 0) + 1;
  }
  return m;
}

List<List<String>> splits(List<List<String>> symbols) =>
    symbols.where((s) => s.length == 2).toList();

void main() {
  test('total symbol count always equals the step count', () {
    for (final steps in [1, 3, 7, 12, 14, 24, 48]) {
      final syms = elementSymbolsFor(
          formulaWithEffects({'water': 2, 'fire': 1, 'air': 1}), steps);
      expect(syms.length, steps, reason: 'steps=$steps');
    }
  });

  test('single affinity → all identical symbols', () {
    final syms = elementSymbolsFor(formulaWithEffects({'water': 3}), 10);
    expect(syms.length, 10);
    expect(syms.every((s) => s.length == 1 && s[0] == 'water'), isTrue);
  });

  test('example 1: 2 water + 1 fire over 12 steps → 8 water, 4 fire', () {
    final syms = elementSymbolsFor(
        formulaWithEffects({'water': 2, 'fire': 1}), 12);
    expect(syms.length, 12);
    expect(splits(syms), isEmpty);
    expect(singleCounts(syms), {'water': 8, 'fire': 4});
  });

  test('example 2: 2 water + 1 fire + 1 air over 14 steps '
      '→ 7 water, 3 fire, 3 air, 1 fire/air split', () {
    final syms = elementSymbolsFor(
        formulaWithEffects({'water': 2, 'fire': 1, 'air': 1}), 14);
    expect(syms.length, 14);
    expect(singleCounts(syms), {'water': 7, 'fire': 3, 'air': 3});
    final sp = splits(syms);
    expect(sp.length, 1);
    expect(sp.first.toSet(), {'fire', 'air'});
  });

  test('exact even split needs no split symbol', () {
    final syms =
        elementSymbolsFor(formulaWithEffects({'fire': 1, 'water': 1}), 8);
    expect(splits(syms), isEmpty);
    expect(singleCounts(syms), {'fire': 4, 'water': 4});
  });

  test('empty formula or zero steps → no symbols', () {
    expect(elementSymbolsFor(const [], 12), isEmpty);
    expect(elementSymbolsFor(formulaWithEffects({'fire': 1}), 0), isEmpty);
  });

  test('sub-triplet formula falls back to raw activation counts', () {
    // Only 2 activations → 0 complete effects; still shows something.
    final syms = elementSymbolsFor(['fire', 'water'], 6);
    expect(syms.length, 6);
    expect(singleCounts(syms), {'fire': 3, 'water': 3});
  });
}
