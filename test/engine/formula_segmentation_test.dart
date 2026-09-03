// SPDX-License-Identifier: GPL-3.0-or-later
//
// formula_segmentation_test.dart — the one incantation segmentation primitive
// (Mutable Leylines, Slice A).
//
// Slice A is a MECHANICAL refactor: five call sites that each wrote
// `for (i = 0; i + 3 <= n; i += 3)` — plus three that wrote `(n ~/ 3) * 3` for
// the same rule as a count — now share one implementation. Nothing about
// behaviour changes, and the tests below exist to prove exactly that.
//
// The forward-looking L=4/5/6 group is deliberately marked: those lengths are
// mechanically supported by the primitive and are reached by NO production
// caller in this slice.

import 'package:test/test.dart';

import 'package:rune_duel/battle/models/effect_kind.dart';
import 'package:rune_duel/battle/models/leyline_config.dart'
    show LeylineConfig;
import 'package:rune_duel/battle/engine/trajectory_parser.dart'
    show ParsedFormula;
import 'package:rune_duel/engine/border_zone.dart';
import 'package:rune_duel/engine/formula.dart';
import 'package:rune_duel/engine/formula_segmentation.dart';
import 'package:rune_duel/spells/wild_magic_preview.dart'
    show completedFormulasFromZones, completedFormulasFromNames;

const _f = BorderZone.fire;
const _e = BorderZone.earth;
const _w = BorderZone.water;
const _a = BorderZone.air;

/// The EXACT loop every one of the five call sites ran before this slice,
/// transcribed here so the new primitive can be differentially tested against
/// it rather than against a restatement of itself.
List<List<T>> _legacyChunkByThree<T>(List<T> xs) {
  final out = <List<T>>[];
  for (var i = 0; i + 3 <= xs.length; i += 3) {
    out.add(xs.sublist(i, i + 3));
  }
  return out;
}

void main() {
  group('segmentFormulas at the ordinary length', () {
    test('L=3 output matches the previous implementation exactly', () {
      // Every length from 0 to 20, over a repeating four-element alphabet, so
      // every residual class (0, 1, 2) is covered many times over.
      const alphabet = [_f, _e, _w, _a];
      for (var n = 0; n <= 20; n++) {
        final xs = [for (var i = 0; i < n; i++) alphabet[i % 4]];
        expect(
          segmentFormulas(xs, formulaLength: kIncantationFormulaLength),
          _legacyChunkByThree(xs),
          reason: 'divergence at length $n',
        );
      }
    });

    test('empty sequence yields no formulas', () {
      expect(segmentFormulas(<BorderZone>[], formulaLength: 3), isEmpty);
      expect(completeFormulaCount(0, formulaLength: 3), 0);
      expect(completeFormulaElementCount(0, formulaLength: 3), 0);
    });

    test('one exact formula', () {
      expect(
        segmentFormulas([_f, _e, _w], formulaLength: 3),
        [
          [_f, _e, _w]
        ],
      );
    });

    test('multiple disjoint formulas — no overlap, no element reused', () {
      expect(
        segmentFormulas([_f, _e, _w, _a, _f, _e], formulaLength: 3),
        [
          [_f, _e, _w],
          [_a, _f, _e],
        ],
      );
    });

    test('a trailing 1 element is discarded', () {
      expect(
        segmentFormulas([_f, _e, _w, _a], formulaLength: 3),
        [
          [_f, _e, _w]
        ],
      );
      expect(completeFormulaElementCount(4, formulaLength: 3), 3);
    });

    test('a trailing 2 elements are discarded', () {
      expect(
        segmentFormulas([_f, _e, _w, _a, _f], formulaLength: 3),
        [
          [_f, _e, _w]
        ],
      );
      expect(completeFormulaElementCount(5, formulaLength: 3), 3);
    });

    test('canonical ordering is preserved — chunks and their contents', () {
      // A sequence in which every element is distinguishable by position, so a
      // reordering anywhere would show. (Four symbols repeat, but the chunk
      // pattern below is asymmetric.)
      final xs = [_f, _f, _e, _w, _a, _a, _e, _w, _f];
      expect(segmentFormulas(xs, formulaLength: 3), [
        [_f, _f, _e],
        [_w, _a, _a],
        [_e, _w, _f],
      ]);
    });

    test('the returned groups are unmodifiable and detached from the input',
        () {
      final xs = [_f, _e, _w];
      final chunks = segmentFormulas(xs, formulaLength: 3);
      expect(() => chunks.single.add(_a), throwsUnsupportedError);
      xs[0] = _a;
      expect(chunks.single.first, _f, reason: 'a copy, not a view');
    });
  });

  group('the count helpers agree with the segmentation', () {
    test('completeFormulaCount == segmentFormulas(...).length, always', () {
      for (var L = 1; L <= 6; L++) {
        for (var n = 0; n <= 24; n++) {
          final xs = List<int>.generate(n, (i) => i);
          expect(
            completeFormulaCount(n, formulaLength: L),
            segmentFormulas(xs, formulaLength: L).length,
            reason: 'L=$L n=$n',
          );
        }
      }
    });

    test('completeFormulaElementCount truncates down to a whole multiple', () {
      expect(completeFormulaElementCount(0, formulaLength: 3), 0);
      expect(completeFormulaElementCount(2, formulaLength: 3), 0);
      expect(completeFormulaElementCount(3, formulaLength: 3), 3);
      expect(completeFormulaElementCount(7, formulaLength: 3), 6);
      // Guards the old `(n ~/ 3) * 3` sites against a negative slipping in.
      expect(completeFormulaElementCount(-1, formulaLength: 3), 0);
    });
  });

  group('nonsensical lengths are refused, not absorbed', () {
    test('length 0 and negative lengths throw', () {
      expect(() => segmentFormulas([_f], formulaLength: 0), throwsArgumentError);
      expect(
          () => segmentFormulas([_f], formulaLength: -3), throwsArgumentError);
      expect(() => completeFormulaCount(9, formulaLength: 0),
          throwsArgumentError);
    });

    test('the UPPER bound belongs to LeylineConfig, not to this primitive', () {
      // The primitive is a mechanism and does not know what a leyline is; the
      // ratified 4..6 range is enforced where the config is constructed.
      expect(segmentFormulas([_f, _e, _w], formulaLength: 99), isEmpty);
      expect(
        () => LeylineConfig.mutable(communitySeed: 'x', formulaLength: 99),
        throwsA(isA<Exception>()),
      );
    });
  });

  group('the former call sites are unchanged', () {
    // A trajectory with a residual, so every path has to discard it.
    const zones = [_f, _f, _f, _e, _e, _e, _w];

    test('FormulaTracker.formulas and .residuals', () {
      final tracker = FormulaTracker();
      // Interleave neutrals so every element is a fresh lead change and
      // commits exactly once — the fixture idiom used across the suite.
      for (final z in zones) {
        tracker.step(z);
        tracker.step(null);
      }
      expect(tracker.committed, zones);
      expect(tracker.formulas, _legacyChunkByThree(zones));
      expect(tracker.residuals, [_w]);
    });

    test('completedFormulasFromZones (card geometry)', () {
      expect(
        completedFormulasFromZones(zones),
        [
          const ParsedFormulaLike(_f, _f, _f),
          const ParsedFormulaLike(_e, _e, _e),
        ].map((p) => p.asParsed),
      );
    });

    test('formulaEffects drops unrecognised names BEFORE segmenting', () {
      // 'bogus' is dropped first, so the surviving zones are
      // [fire, fire, fire, earth] -> one complete formula.
      final effects = formulaEffects(
        const ['fire', 'bogus', 'fire', 'fire', 'earth'],
      );
      expect(effects.length, 1);
      expect(effects.single.affinity, SpellAffinity.fire);
      expect(effects.single.kind, EffectKind.damage);
    });

    test('completedFormulasFromNames matches formulaEffects\' segmentation',
        () {
      const names = ['fire', 'bogus', 'fire', 'fire', 'earth'];
      expect(completedFormulasFromNames(names).length,
          formulaEffects(names).length);
    });
  });

  group('preview and certification segment identically', () {
    // Both sides of the divergence the audit flagged: the duel segments the
    // CERTIFIED sequence through FormulaTracker, the card segments the AUTHORED
    // name list through completedFormulasFromNames. For an honest asset the
    // two are the same list and must therefore cut the same way.
    const trajectories = <List<BorderZone>>[
      [],
      [_f],
      [_f, _e],
      [_f, _e, _w],
      [_f, _e, _w, _a],
      [_f, _f, _f, _e, _e, _e],
      [_f, _f, _f, _e, _e, _e, _w, _w],
      [_a, _w, _e, _f, _a, _w, _e, _f, _a, _w, _e, _f],
    ];

    test('across representative trajectories', () {
      for (final zones in trajectories) {
        final tracker = FormulaTracker();
        for (final z in zones) {
          tracker.step(z);
          tracker.step(null);
        }
        final certified = tracker.formulas;
        final previewed = completedFormulasFromNames(
          [for (final z in zones) z.name],
        );
        expect(previewed.length, certified.length, reason: '$zones');
        for (var i = 0; i < certified.length; i++) {
          expect(previewed[i].affinity, certified[i][0], reason: '$zones #$i');
          expect(previewed[i].effectType1, certified[i][1]);
          expect(previewed[i].effectType2, certified[i][2]);
        }
      }
    });
  });

  group('forward-looking: L=4/5/6 (UNUSED by production in this slice)', () {
    // The primitive must already cut mutable lengths correctly so Slice D is a
    // one-line seam change rather than a new implementation. NOTHING in
    // production passes these lengths today — every caller passes
    // kIncantationFormulaLength.
    test('L=4 cuts disjoint quads and discards the remainder', () {
      final xs = List<int>.generate(10, (i) => i);
      expect(segmentFormulas(xs, formulaLength: 4), [
        [0, 1, 2, 3],
        [4, 5, 6, 7],
      ]);
    });

    test('L=5', () {
      final xs = List<int>.generate(12, (i) => i);
      expect(segmentFormulas(xs, formulaLength: 5), [
        [0, 1, 2, 3, 4],
        [5, 6, 7, 8, 9],
      ]);
    });

    test('L=6', () {
      final xs = List<int>.generate(13, (i) => i);
      expect(segmentFormulas(xs, formulaLength: 6), [
        [0, 1, 2, 3, 4, 5],
        [6, 7, 8, 9, 10, 11],
      ]);
    });

    test('chunk[0] is still the affinity slot at every supported length', () {
      for (var L = 3; L <= 6; L++) {
        final xs = [_a, ...List.filled(L - 1, _f), _a, ...List.filled(L - 1, _e)];
        final chunks = segmentFormulas(xs, formulaLength: L);
        expect(chunks.length, 2);
        expect(chunks[0][0], _a);
        expect(chunks[1][0], _a);
      }
    });

    test('no production caller passes anything but the ordinary length', () {
      // A statement of intent this slice can actually assert: the ordinary
      // grammar's length is 3, and LeylineConfig agrees with the engine about
      // it through a single constant rather than two copies.
      expect(kIncantationFormulaLength, 3);
      expect(LeylineConfig.kOrdinaryFormulaLength, kIncantationFormulaLength);
      expect(LeylineConfig.ordinaryDefault.formulaLength,
          kIncantationFormulaLength);
    });
  });
}

/// Tiny helper so the expectation above reads as a triplet rather than as a
/// constructor call repeated three times.
class ParsedFormulaLike {
  const ParsedFormulaLike(this.a, this.b, this.c);
  final BorderZone a;
  final BorderZone b;
  final BorderZone c;
  ParsedFormula get asParsed =>
      ParsedFormula(affinity: a, effectType1: b, effectType2: c);
}
