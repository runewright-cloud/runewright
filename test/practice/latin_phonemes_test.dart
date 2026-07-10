// SPDX-License-Identifier: GPL-3.0-or-later
//
// latin_phonemes_test.dart — unit tests for LatinPhonemes' hardcoded
// per-word phoneme/weight table (lib/practice/latin_phonemes.dart).

import 'package:test/test.dart';
import 'package:rune_duel/practice/latin_phonemes.dart';
import 'package:rune_duel/sorcerer/vocal_score.dart';

void main() {
  test('every VocalWord has a non-empty phoneme entry', () {
    for (final word in VocalWord.values) {
      expect(LatinPhonemes.phonemesFor(word), isNotEmpty, reason: word.name);
    }
  });

  test('ignis carries the palatalized-gn geminate as its second phoneme', () {
    final phonemes = LatinPhonemes.phonemesFor(VocalWord.ignis);
    expect(phonemes[1].label, 'ɲː');
  });

  group('cumulativeWeightFractions', () {
    for (final word in VocalWord.values) {
      test('${word.name}: monotonically increasing, ends at 1.0', () {
        final fractions = LatinPhonemes.cumulativeWeightFractions(word);
        expect(fractions.length, LatinPhonemes.phonemesFor(word).length);
        expect(fractions.last, closeTo(1.0, 1e-9));
        for (int i = 1; i < fractions.length; i++) {
          expect(fractions[i], greaterThan(fractions[i - 1]));
        }
      });
    }
  });
}
