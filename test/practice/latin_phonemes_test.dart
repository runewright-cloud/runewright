// SPDX-License-Identifier: GPL-3.0-or-later
//
// latin_phonemes_test.dart — unit tests for LatinPhonemes' hardcoded
// per-word phoneme/weight table (lib/practice/latin_phonemes.dart).

import 'package:test/test.dart';
import 'package:rune_duel/practice/latin_phonemes.dart';
import 'package:rune_duel/sorcerer/vocal_slot.dart';

void main() {
  test('every VocalSlot has a non-empty phoneme entry', () {
    for (final word in VocalSlot.values) {
      expect(LatinPhonemes.phonemesFor(word), isNotEmpty, reason: word.name);
    }
  });

  test('ignis rhymes with "kiss" via a voiceless final s '
      '(deliberate "ignisse" TTS override, not plain "ignis")', () {
    final phonemes = LatinPhonemes.phonemesFor(VocalSlot.fire);
    expect(phonemes.last.label, 's');
    expect(phonemes[phonemes.length - 2].label, 'ɪ');
  });

  test('reformare keeps the Latin "-ah-ray" tail, not the "reformer" /ɛɹ/ '
      '(deliberate "reformahray" TTS override)', () {
    final phonemes = LatinPhonemes.phonemesFor(VocalSlot.openerGeneral);
    expect(phonemes.last.label, 'eɪ');
    expect(phonemes[phonemes.length - 2].label, 'ɹ');
    expect(phonemes[phonemes.length - 3].label, 'ɑː');
  });

  // §8.7: opener-vs-opener is the load-bearing distance in the vocabulary —
  // the one pair a player is motivated to collapse so a summon can't be told
  // from an incantation. The shipped defaults must not start alike.
  test('the two default openers differ in onset and length', () {
    final general = LatinPhonemes.phonemesFor(VocalSlot.openerGeneral);
    final summon = LatinPhonemes.phonemesFor(VocalSlot.openerSummon);
    expect(general.first.label, isNot(summon.first.label));
    expect(general.length, isNot(summon.length));
  });

  group('cumulativeWeightFractions', () {
    for (final word in VocalSlot.values) {
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
