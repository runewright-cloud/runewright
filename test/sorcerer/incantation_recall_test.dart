// SPDX-License-Identifier: GPL-3.0-or-later
//
// incantation_recall_test.dart — the recall cost model
// (lib/sorcerer/incantation_recall.dart).
//
// The load-bearing tests here are the two that pin ratified design numbers:
//   - the baked step table is re-derived from its formula, so a hand-edit of
//     a constant can't silently drift the mana ledger; and
//   - a perfect recital NEVER beats −33% at ANY length, which is §3's binding
//     constraint (an ungated skill check must not out-discount the gated
//     Water/Efficiency loadout). That constraint is exactly what the flat
//     step = 0.03 violated once spells got longer than the 9 element words
//     §8.5 assumed.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:rune_duel/sorcerer/incantation_recall.dart';
import 'package:rune_duel/sorcerer/vocal_slot.dart';

/// The ratified gate: the gated Water/Efficiency loadout's −33%.
const double _gatedLoadoutMultiplier = 0.67;

/// Multiplier a tally applies, as a double — for asserting on design targets.
/// Production code never does this; it stays in integers.
double _multiplierOf(RecallTally tally) {
  const base = 100000000;
  return tally.applyTo(base) / base;
}

RecallTally _tally({
  required int elements,
  int wrongElements = 0,
  bool openerWrong = false,
}) {
  final expected = List.filled(elements, VocalSlot.fire);
  final spoken = <VocalSlot?>[
    for (var i = 0; i < elements; i++)
      i < wrongElements ? VocalSlot.water : VocalSlot.fire,
  ];
  return IncantationRecall(
    opener: openerWrong ? VocalSlot.openerSummon : VocalSlot.openerGeneral,
    elements: spoken,
  ).tallyAgainst(expectedIsSummon: false, expectedElements: expected);
}

void main() {
  group('step table', () {
    test('every entry re-derives from step = 1 - 0.737^(1/n)', () {
      for (var n = 1; n <= 49; n++) {
        final expected =
            ((1 - math.pow(kPerfectMultiplierPpm / 1000000, 1 / n)) * 1000000)
                .round();
        expect(stepPpmFor(n), expected, reason: 'n=$n');
      }
    });

    test('n=10 reproduces §8.5\'s ratified flat step of 0.03', () {
      // 9 element words + the opener — the case §8.5 actually ratified.
      expect(stepPpmFor(10), closeTo(30000, 100));
    });

    test('clamps above the tier-48 maximum instead of ranging out', () {
      expect(stepPpmFor(50), stepPpmFor(49));
      expect(stepPpmFor(1000), stepPpmFor(49));
      expect(stepPpmFor(0), stepPpmFor(1));
    });
  });

  group('§3 binding constraint', () {
    // The bug the flat step had: at step = 0.03 a perfect recital passes -33%
    // at ~13 element words and reaches -77% at 48.
    test('a perfect recital never beats the gated loadout, at any length', () {
      for (var elements = 3; elements <= 48; elements++) {
        final multiplier = _multiplierOf(_tally(elements: elements));
        expect(
          multiplier,
          greaterThan(_gatedLoadoutMultiplier),
          reason: '$elements element words discounted to $multiplier, which '
              'beats the GATED Water/Efficiency loadout at '
              '$_gatedLoadoutMultiplier',
        );
      }
    });

    test('a perfect recital lands on -26.3% at every length', () {
      for (var elements = 3; elements <= 48; elements++) {
        expect(
          _multiplierOf(_tally(elements: elements)),
          closeTo(0.737, 0.001),
          reason: '$elements element words',
        );
      }
    });
  });

  group('§8.5 ratified table (9 element words)', () {
    test('perfect recital is -26.3%', () {
      expect(_multiplierOf(_tally(elements: 9)), closeTo(0.737, 0.001));
    });

    test('total blank is +42.6%', () {
      expect(
        _multiplierOf(_tally(elements: 9, wrongElements: 9, openerWrong: true)),
        closeTo(1.426, 0.002),
      );
    });

    test('opener missed, elements perfect is -16.9%', () {
      expect(
        _multiplierOf(_tally(elements: 9, openerWrong: true)),
        closeTo(0.831, 0.002),
      );
    });

    test('6 of 9 elements, opener right is -11.7%', () {
      expect(
        _multiplierOf(_tally(elements: 9, wrongElements: 3)),
        closeTo(0.883, 0.002),
      );
    });
  });

  group('§8.5 opener deterrent', () {
    test('is asymmetric: wrong costs 3x what right earns', () {
      final right = _tally(elements: 9);
      final wrong = _tally(elements: 9, openerWrong: true);
      expect(right.weightedWrong, 0);
      expect(wrong.weightedWrong, IncantationRecall.openerWrongWeight);
      expect(wrong.correct, right.correct - 1);
    });

    test('bites hardest on short spells, where faking is cheapest', () {
      double swing(int elements) =>
          _multiplierOf(_tally(elements: elements, openerWrong: true)) -
          _multiplierOf(_tally(elements: elements));
      // On a 3-element spell missing the opener erases essentially the whole
      // discount; on a 48-element one it is a rounding error. That gradient is
      // the intent, not an artefact.
      expect(swing(3), greaterThan(0.2));
      expect(swing(48), lessThan(0.03));
    });
  });

  group('§5 order-independence', () {
    test('M M X M M X scores identically to M M M M X X', () {
      final expected = List.filled(6, VocalSlot.fire);
      RecallTally forSpoken(List<VocalSlot> spoken) => IncantationRecall(
            opener: VocalSlot.openerGeneral,
            elements: spoken,
          ).tallyAgainst(
            expectedIsSummon: false,
            expectedElements: expected,
          );

      const f = VocalSlot.fire;
      const x = VocalSlot.water;
      final interleaved = forSpoken([f, f, x, f, f, x]);
      final clustered = forSpoken([f, f, f, f, x, x]);

      expect(interleaved.correct, clustered.correct);
      expect(interleaved.weightedWrong, clustered.weightedWrong);
      expect(interleaved.applyTo(1000), clustered.applyTo(1000));
    });
  });

  group('tallyAgainst', () {
    test('a summon spell expects the summon opener', () {
      final tally = IncantationRecall(
        opener: VocalSlot.openerSummon,
        elements: const [VocalSlot.fire],
      ).tallyAgainst(
        expectedIsSummon: true,
        expectedElements: const [VocalSlot.fire],
      );
      expect(tally.isPerfect, isTrue);
    });

    test('a missing utterance scores exactly as a wrong word', () {
      final expected = [VocalSlot.fire, VocalSlot.air];
      final blank = IncantationRecall(
        opener: VocalSlot.openerGeneral,
        elements: const [VocalSlot.fire, null],
      ).tallyAgainst(expectedIsSummon: false, expectedElements: expected);
      final wrong = IncantationRecall(
        opener: VocalSlot.openerGeneral,
        elements: const [VocalSlot.fire, VocalSlot.earth],
      ).tallyAgainst(expectedIsSummon: false, expectedElements: expected);
      expect(blank.correct, wrong.correct);
      expect(blank.weightedWrong, wrong.weightedWrong);
    });

    // The wire's count byte is untrusted framing. Scoring reads the CERTIFIED
    // expected length, so lying about how much was spoken changes nothing.
    test('under-reporting words scores the missing ones as wrong', () {
      final tally = IncantationRecall(
        opener: VocalSlot.openerGeneral,
        elements: const [VocalSlot.fire],
      ).tallyAgainst(
        expectedIsSummon: false,
        expectedElements: List.filled(9, VocalSlot.fire),
      );
      expect(tally.units, 10);
      expect(tally.correct, 2); // opener + the one spoken word
      expect(tally.weightedWrong, 8);
    });

    test('over-reporting words is ignored past the expected length', () {
      final tally = IncantationRecall(
        opener: VocalSlot.openerGeneral,
        elements: List.filled(40, VocalSlot.fire),
      ).tallyAgainst(
        expectedIsSummon: false,
        expectedElements: List.filled(3, VocalSlot.fire),
      );
      expect(tally.units, 4);
      expect(tally.isPerfect, isTrue);
    });

    test('a silent cast is a total blank', () {
      final tally = IncantationRecall.silent.tallyAgainst(
        expectedIsSummon: false,
        expectedElements: List.filled(3, VocalSlot.fire),
      );
      expect(tally.correct, 0);
      expect(tally.weightedWrong, 3 + IncantationRecall.openerWrongWeight);
      expect(_multiplierOf(tally), greaterThan(1.0));
    });
  });

  group('applyTo', () {
    test('rounds up, once', () {
      // A perfect 9-word recital of a 10-mana spell: 10 x 0.737 = 7.37 -> 8.
      expect(_tally(elements: 9).applyTo(10), 8);
    });

    test('is exact at the 48-element extreme (no overflow, no drift)', () {
      final perfect = _tally(elements: 48).applyTo(1000000);
      final blank =
          _tally(elements: 48, wrongElements: 48, openerWrong: true)
              .applyTo(1000000);
      expect(perfect, closeTo(737000, 500));
      expect(blank, greaterThan(1000000));
      expect(blank, lessThan(1500000));
    });

    test('leaves a free cast free', () {
      expect(_tally(elements: 9).applyTo(0), 0);
    });
  });

  group('wire', () {
    test('round-trips opener and elements', () {
      const recall = IncantationRecall(
        opener: VocalSlot.openerSummon,
        elements: [VocalSlot.fire, null, VocalSlot.earth],
      );
      final bytes = recall.toWireBytes();
      final decoded = IncantationRecall.fromWireBytes(bytes, 0);
      expect(decoded.recall.opener, VocalSlot.openerSummon);
      expect(decoded.recall.elements, [VocalSlot.fire, null, VocalSlot.earth]);
      expect(decoded.bytesRead, bytes.length);
    });

    test('round-trips a silent cast', () {
      final decoded =
          IncantationRecall.fromWireBytes(IncantationRecall.silent.toWireBytes(), 0);
      expect(decoded.recall.opener, isNull);
      expect(decoded.recall.elements, isEmpty);
    });

    test('decodes at an offset and reports what it consumed', () {
      const recall = IncantationRecall(
        opener: VocalSlot.openerGeneral,
        elements: [VocalSlot.water],
      );
      final buf = Uint8List.fromList([0xAA, 0xBB, ...recall.toWireBytes()]);
      final decoded = IncantationRecall.fromWireBytes(buf, 2);
      expect(decoded.recall.elements, [VocalSlot.water]);
      expect(decoded.bytesRead, 3);
    });

    test('round-trips the 48-element maximum', () {
      final recall = IncantationRecall(
        opener: VocalSlot.openerGeneral,
        elements: List.filled(48, VocalSlot.earth),
      );
      final decoded =
          IncantationRecall.fromWireBytes(recall.toWireBytes(), 0);
      expect(decoded.recall.elements.length, 48);
    });

    // A malformed payload must degrade to "no utterance", never throw: every
    // bad reading costs the CASTER mana, so there is nothing here worth
    // forfeiting a match over.
    test('a truncated payload degrades instead of throwing', () {
      final full = const IncantationRecall(
        opener: VocalSlot.openerGeneral,
        elements: [VocalSlot.fire, VocalSlot.air, VocalSlot.water],
      ).toWireBytes();
      final truncated = Uint8List.sublistView(full, 0, full.length - 2);
      final decoded = IncantationRecall.fromWireBytes(truncated, 0);
      expect(decoded.recall.elements, [VocalSlot.fire]);
    });

    test('an empty buffer degrades to silence', () {
      final decoded = IncantationRecall.fromWireBytes(Uint8List(0), 0);
      expect(decoded.recall.opener, isNull);
      expect(decoded.recall.elements, isEmpty);
    });

    test('a lied-about count cannot over-read the buffer', () {
      final bytes = Uint8List.fromList([0, 200, 1, 2]);
      final decoded = IncantationRecall.fromWireBytes(bytes, 0);
      expect(decoded.recall.elements.length, 2);
    });

    test('an out-of-range element byte reads as no utterance', () {
      final bytes = Uint8List.fromList([0, 2, 0xFF, 9]);
      final decoded = IncantationRecall.fromWireBytes(bytes, 0);
      expect(decoded.recall.elements, [null, null]);
    });

    test('caps a hostile length at the tier-48 maximum', () {
      final recall = IncantationRecall(
        opener: VocalSlot.openerGeneral,
        elements: List.filled(200, VocalSlot.fire),
      );
      expect(recall.toWireBytes().length, 2 + IncantationRecall.maxElements);
    });
  });
}
