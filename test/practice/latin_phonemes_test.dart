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

  test('ignis rhymes with "kiss" via a voiceless final s '
      '(deliberate "ignisse" TTS override, not plain "ignis")', () {
    final phonemes = LatinPhonemes.phonemesFor(VocalWord.ignis);
    expect(phonemes.last.label, 's');
    expect(phonemes[phonemes.length - 2].label, 'ɪ');
  });

  test('finitus carries the English intervocalic t-flap', () {
    final phonemes = LatinPhonemes.phonemesFor(VocalWord.finitus);
    expect(phonemes.any((p) => p.label == 'ɾ'), isTrue);
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
