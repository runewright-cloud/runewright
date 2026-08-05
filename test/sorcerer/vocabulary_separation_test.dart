// SPDX-License-Identifier: GPL-3.0-or-later
//
// vocabulary_separation_test.dart — §8.7's disclosure tool
// (lib/sorcerer/vocabulary_separation.dart).
//
// The behaviours worth pinning are the ones that make it a WARNING rather than
// a gate, and the ones that keep its numbers comparable across speakers.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:rune_duel/sorcerer/mfcc.dart';
import 'package:rune_duel/sorcerer/vocabulary_separation.dart';
import 'package:rune_duel/sorcerer/vocal_slot.dart';

/// A take: a chirp, optionally jittered so repeats of one "word" differ a
/// little — which is what gives a word a measurable within-word spread.
List<List<double>> _take(
  double startFreq,
  double endFreq, {
  double jitter = 0.0,
  int samples = 6400,
}) {
  final bytes = ByteData(samples * 2);
  var phase = 0.0;
  for (var i = 0; i < samples; i++) {
    final t = i / samples;
    final freq = startFreq + (endFreq - startFreq) * t + jitter;
    phase += 2 * math.pi * freq / MfccExtractor.sampleRate;
    bytes.setInt16(i * 2, (math.sin(phase) * 12000).round(), Endian.little);
  }
  return MfccExtractor.extract(bytes.buffer.asUint8List());
}

/// Two takes of a word centred on [base], jittered apart.
List<List<List<double>>> _word(double base) => [
      _take(base, base + 600, jitter: 0),
      _take(base, base + 600, jitter: 40),
    ];

void main() {
  group('measure', () {
    test('well-separated words clear their bars', () {
      final separation = VocabularySeparation.measure({
        VocalSlot.fire: _word(300),
        VocalSlot.air: _word(1400),
        VocalSlot.water: _word(2400),
        VocalSlot.earth: _word(3400),
      });
      expect(separation.pairs, hasLength(6));
      expect(separation.isClean, isTrue);
    });

    test('two words that are nearly the same sound are flagged', () {
      final separation = VocabularySeparation.measure({
        VocalSlot.fire: _word(300),
        // 5 Hz apart: far closer to each other than a speaker's own repeats.
        VocalSlot.air: _word(305),
        VocalSlot.water: _word(2400),
        VocalSlot.earth: _word(3400),
      });
      expect(separation.isClean, isFalse);
      final worst = separation.warnings.first;
      expect({worst.a, worst.b}, {VocalSlot.fire, VocalSlot.air});
    });

    // Elements and openers are never candidates for the same position, so
    // their separation is not something the recogniser can get wrong.
    test('never compares an element against an opener', () {
      final separation = VocabularySeparation.measure({
        VocalSlot.fire: _word(300),
        VocalSlot.openerGeneral: _word(300),
      });
      expect(separation.pairs, isEmpty);
    });

    test('measures the opener pair and marks it as such', () {
      final separation = VocabularySeparation.measure({
        VocalSlot.openerGeneral: _word(400),
        VocalSlot.openerSummon: _word(2600),
      });
      expect(separation.openerPair, isNotNull);
      expect(separation.openerPair!.isOpenerPair, isTrue);
    });

    test('skips slots with no takes', () {
      final separation = VocabularySeparation.measure({
        VocalSlot.fire: _word(300),
        VocalSlot.air: const [],
      });
      expect(separation.pairs, isEmpty);
    });

    test('a single take still yields a number rather than dividing by zero', () {
      final separation = VocabularySeparation.measure({
        VocalSlot.fire: [_take(300, 900)],
        VocalSlot.air: [_take(2400, 3000)],
      });
      expect(separation.pairs, hasLength(1));
      expect(separation.pairs.first.margin.isFinite, isTrue);
    });
  });

  group('the openers are held to a higher bar', () {
    test('the opener pair requires more separation than an element pair', () {
      const opener = SlotPairSeparation(
        a: VocalSlot.openerGeneral,
        b: VocalSlot.openerSummon,
        margin: 1.3,
        isOpenerPair: true,
      );
      const elements = SlotPairSeparation(
        a: VocalSlot.fire,
        b: VocalSlot.air,
        margin: 1.3,
        isOpenerPair: false,
      );
      // Same margin, different verdict: collapsing the openers is the one
      // confusion a player is motivated to cause.
      expect(opener.isTooClose, isTrue);
      expect(elements.isTooClose, isFalse);
    });

    test('a flagged opener pair is reported ahead of worse element pairs', () {
      const separation = VocabularySeparation([
        SlotPairSeparation(
          a: VocalSlot.fire,
          b: VocalSlot.air,
          margin: 0.2, // much worse in absolute terms
          isOpenerPair: false,
        ),
        SlotPairSeparation(
          a: VocalSlot.openerGeneral,
          b: VocalSlot.openerSummon,
          margin: 1.5,
          isOpenerPair: true,
        ),
      ]);
      expect(separation.warnings.first.isOpenerPair, isTrue);
    });
  });

  group('the meter', () {
    test('reads 0 when the words are indistinguishable', () {
      const pair = SlotPairSeparation(
        a: VocalSlot.fire,
        b: VocalSlot.air,
        margin: 0.0,
        isOpenerPair: false,
      );
      expect(pair.meter, 0.0);
    });

    test('saturates at 1 rather than running off the end', () {
      const pair = SlotPairSeparation(
        a: VocalSlot.fire,
        b: VocalSlot.air,
        margin: 99.0,
        isOpenerPair: false,
      );
      expect(pair.meter, 1.0);
    });
  });
}
