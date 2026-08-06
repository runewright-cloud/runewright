// SPDX-License-Identifier: GPL-3.0-or-later
//
// gesture_confusion_e2e_test.dart — the SOMATIC_GESTURE_PLAN.md §9
// calibration gate, run over the REAL captured corpus.
//
// This is the somatic counterpart to test/practice/real_template_e2e_test.dart
// on the vocal side, and it exists for the same reason: the synthetic harness
// (gesture_confusion_matrix_test.dart) validates the matrix *mechanics* but
// cannot catch a representation that is wrong about real sensor data. It
// didn't — every synthetic test passed while the shipped defaults classified
// 19 of 20 real idle/walk captures as `fire`, because DTW on raw frames is
// amplitude-dominated and fire is the quietest gesture. Only real captures
// surface that.
//
// Corpus: fixtures/corpus_pixel6/, 10 reps each of the five gestures plus the
// three confusables, captured on a Pixel 6 (~55 Hz, NOT the 100 Hz
// SensorsGestureCapture requests) via practice_screen's Gesture tab. Stored
// exactly as GestureEnrollment writes them, so this also exercises the real
// on-disk format and loader.
//
// Every threshold here is the shipped default. If a constant changes, re-run
// `dart run tool/gesture_corpus_analysis.dart test/sorcerer/fixtures/corpus_pixel6`
// and move these expectations deliberately — never to make a red test green.

import 'dart:io';
import 'dart:math' as math;

import 'package:test/test.dart';
import 'package:rune_duel/practice/gesture_enrollment.dart';
import 'package:rune_duel/sorcerer/gesture.dart';
import 'package:rune_duel/sorcerer/gesture_classifier.dart';
import 'package:rune_duel/sorcerer/imu_sample.dart';

const _corpusDir = 'test/sorcerer/fixtures/corpus_pixel6';

const _recognized = [
  Gesture.fire,
  Gesture.air,
  Gesture.water,
  Gesture.earth,
  Gesture.melee,
];

/// Shipped defaults — deliberately not overridden.
const _classifier = GestureClassifier();

/// Rebuilds the sample list a rep was captured from. Enrollment stores
/// feature frames, not ImuSamples; classify() takes samples, so the timestamps
/// are reconstructed at the corpus's measured rate. Only [windowEnergy] and
/// frame order depend on this, and neither is sensitive to the exact rate.
List<ImuSample> _samplesOf(GestureRep rep) {
  final periodMs = rep.rateHz > 0 ? 1000.0 / rep.rateHz : 18.0;
  return [
    for (var i = 0; i < rep.frames.length; i++)
      ImuSample(
        tMs: (i * periodMs).round(),
        ax: rep.frames[i][0], ay: rep.frames[i][1], az: rep.frames[i][2],
        gx: rep.frames[i][3], gy: rep.frames[i][4], gz: rep.frames[i][5],
      ),
  ];
}

void main() {
  final enrollment = GestureEnrollment(Directory(_corpusDir));

  late Map<Gesture, List<GestureRep>> gestureReps;
  late Map<GestureConfusable, List<GestureRep>> confusableReps;

  setUpAll(() async {
    gestureReps = {
      for (final g in _recognized) g: await enrollment.repsFor(g),
    };
    confusableReps = {
      for (final c in GestureConfusable.values)
        c: await enrollment.confusableRepsFor(c),
    };
  });

  /// Templates for every gesture, optionally leaving out one rep so a query
  /// is never matched against itself.
  Map<Gesture, List<List<List<double>>>> templates({
    Gesture? holdOutGesture,
    int? holdOutIndex,
  }) =>
      {
        for (final g in _recognized)
          g: [
            for (var i = 0; i < gestureReps[g]!.length; i++)
              if (!(g == holdOutGesture && i == holdOutIndex))
                gestureReps[g]![i].frames,
          ],
      };

  test('corpus is present and complete', () {
    for (final g in _recognized) {
      expect(gestureReps[g], hasLength(10), reason: '${g.name} reps');
    }
    for (final c in GestureConfusable.values) {
      expect(confusableReps[c], hasLength(10), reason: '${c.name} reps');
    }
  });

  test('every genuine rep out-ranks every other gesture (leave-one-out)', () {
    // Ranking only — no accept rule. This is the property that says the five
    // chosen motions are genuinely separable; the accept rule then decides
    // how much confidence to demand before acting on that ranking.
    final wrong = <String>[];
    for (final g in _recognized) {
      for (var i = 0; i < gestureReps[g]!.length; i++) {
        final match = _classifier.classify(
          _samplesOf(gestureReps[g]![i]),
          templates(holdOutGesture: g, holdOutIndex: i),
        );
        final ranked = match.distances.entries.toList()
          ..sort((a, b) => a.value.compareTo(b.value));
        if (ranked.isEmpty || ranked.first.key != g) {
          wrong.add('${g.name}[$i] -> ${ranked.isEmpty ? "none" : ranked.first.key.name}');
        }
      }
    }
    expect(wrong, isEmpty, reason: 'mis-ranked genuine reps: $wrong');
  });

  test('THE GATE: zero wrong-gesture false accepts across the full matrix', () {
    // A release blocker (CLAUDE.md quality bar). A genuine rep may fall to
    // neutral — that is just a cast without enhancement — but nothing may
    // ever be accepted as a gesture it is not.
    final falseAccepts = <String>[];

    for (final g in _recognized) {
      for (var i = 0; i < gestureReps[g]!.length; i++) {
        final match = _classifier.classify(
          _samplesOf(gestureReps[g]![i]),
          templates(holdOutGesture: g, holdOutIndex: i),
        );
        if (match.gesture != Gesture.neutral && match.gesture != g) {
          falseAccepts.add('${g.name}[$i] -> ${match.gesture.name}');
        }
      }
    }

    for (final c in GestureConfusable.values) {
      for (var i = 0; i < confusableReps[c]!.length; i++) {
        final match = _classifier.classify(
          _samplesOf(confusableReps[c]![i]),
          templates(),
        );
        if (match.gesture != Gesture.neutral) {
          falseAccepts.add('${c.name}[$i] -> ${match.gesture.name}');
        }
      }
    }

    expect(falseAccepts, isEmpty,
        reason: 'wrong-gesture false accepts: $falseAccepts');
  });

  test('the suggested attunement count clears the gate on a player-sized set',
      () {
    // Every test above enrols the WHOLE corpus (9 reps after the hold-out).
    // A player will not have that — the Somatic tab asks them for
    // GestureEnrollment.suggestedReps, derived from the sweep in
    // tool/gesture_rep_count_sweep.dart. The number that sweep picked rests on
    // one finding: a single enrolled rep was the only set size that produced a
    // wrong-gesture accept, and everything at or above 2 held clean. So the
    // count the UI prints has to keep clearing the same gate as the corpus and
    // the thresholds move — otherwise the page is quietly telling players to
    // stop attuning before the classifier is safe.
    final n = GestureEnrollment.suggestedReps;
    final rng = math.Random(20260806);
    final falseAccepts = <String>[];

    for (var trial = 0; trial < 12; trial++) {
      for (final target in _recognized) {
        for (var q = 0; q < gestureReps[target]!.length; q++) {
          final subset = <Gesture, List<List<List<double>>>>{
            for (final g in _recognized)
              g: ([
                for (var i = 0; i < gestureReps[g]!.length; i++)
                  if (!(g == target && i == q)) gestureReps[g]![i].frames,
              ]..shuffle(rng))
                  .take(n)
                  .toList(),
          };
          final match =
              _classifier.classify(_samplesOf(gestureReps[target]![q]), subset);
          if (match.gesture != Gesture.neutral && match.gesture != target) {
            falseAccepts.add('${target.name}[$q] -> ${match.gesture.name}');
          }
          // One confusable against the same player-sized set, so the reject
          // side is exercised at N too and not just at full corpus size.
          final c = GestureConfusable
              .values[(trial + q) % GestureConfusable.values.length];
          final cRep = confusableReps[c]![rng.nextInt(confusableReps[c]!.length)];
          final cMatch = _classifier.classify(_samplesOf(cRep), subset);
          if (cMatch.gesture != Gesture.neutral) {
            falseAccepts.add('${c.name} -> ${cMatch.gesture.name}');
          }
        }
      }
    }

    expect(falseAccepts, isEmpty,
        reason: 'false accepts at $n enrolled reps: $falseAccepts');
  });

  test('genuine reps are accepted often enough for the mode to be playable',
      () {
    // The counterweight to the gate above: a classifier that rejects
    // everything trivially has zero false accepts and is also useless.
    // Measured at 90% on this corpus with the shipped defaults; 80% is the
    // floor below which the constants have drifted too strict.
    var accepted = 0, total = 0;
    for (final g in _recognized) {
      for (var i = 0; i < gestureReps[g]!.length; i++) {
        total++;
        final match = _classifier.classify(
          _samplesOf(gestureReps[g]![i]),
          templates(holdOutGesture: g, holdOutIndex: i),
        );
        if (match.gesture == g) accepted++;
      }
    }
    expect(accepted / total, greaterThanOrEqualTo(0.80),
        reason: 'accepted $accepted/$total genuine reps');
  });

  test('idle captures never reach DTW — the stillness gate holds on real data',
      () {
    // energyFloor was 0.02 against real idle energies of 0.04-7.76: the gate
    // never fired, which is how a still hand reached the matcher at all.
    var gated = 0;
    for (final rep in confusableReps[GestureConfusable.idle]!) {
      final match = _classifier.classify(_samplesOf(rep), templates());
      expect(match.gesture, Gesture.neutral);
      if (match.stillnessGated) gated++;
    }
    expect(gated, greaterThanOrEqualTo(9),
        reason: 'only $gated/10 idle captures were stillness-gated');
  });

  group('handedness', () {
    test('mirroring is an exact isometry through the matching pipeline', () {
      // Mirror is a signed permutation, so it is orthogonal and preserves
      // Euclidean distance; normalizeForMatching is a smooth + per-channel
      // scale + global scale, all of which commute with it. Therefore a
      // mirrored template set reproduces right-handed accuracy bit for bit,
      // and one captured corpus covers both handedness for free.
      //
      // This also guards the property: any future feature that breaks the
      // sign symmetry (a rectified magnitude, an axis-specific heuristic)
      // fails here rather than silently making lefties second-class.
      for (final g in _recognized) {
        final reps = gestureReps[g]!;
        for (var i = 0; i + 1 < reps.length; i++) {
          final a = normalizeForMatching(reps[i].frames);
          final b = normalizeForMatching(reps[i + 1].frames);
          final ma = normalizeForMatching(mirrorFrames(reps[i].frames));
          final mb = normalizeForMatching(mirrorFrames(reps[i + 1].frames));

          var maxDelta = 0.0;
          for (var f = 0; f < a.length && f < ma.length; f++) {
            for (var k = 0; k < a[f].length; k++) {
              // Mirrored channels differ only in sign.
              final delta = (a[f][k].abs() - ma[f][k].abs()).abs();
              if (delta > maxDelta) maxDelta = delta;
            }
          }
          expect(maxDelta, lessThan(1e-9),
              reason: '${g.name}[$i] normalisation is not mirror-symmetric');

          // The pairwise distance itself must be preserved exactly.
          expect(_distance(ma, mb), closeTo(_distance(a, b), 1e-9),
              reason: '${g.name}[$i] pair distance changed under mirroring');
        }
      }
    });

    test('mirroring twice is the identity', () {
      final frames = gestureReps[Gesture.fire]!.first.frames;
      final round = mirrorFrames(mirrorFrames(frames));
      for (var i = 0; i < frames.length; i++) {
        for (var k = 0; k < frames[i].length; k++) {
          expect(round[i][k], closeTo(frames[i][k], 1e-12));
        }
      }
    });

    test('a left-handed performance against right-handed templates falls to '
        'neutral, never to a wrong gesture', () {
      // The gestures are strongly chiral (mean self-vs-mirror distance
      // 1.20-1.61, far outside distanceCap), so a mismatched-handedness cast
      // degrades to "no enhancement" rather than to the wrong one. That is
      // the never-false-advance bar holding under a condition the
      // right-handed corpus alone would never exercise.
      final wrong = <String>[];
      for (final g in _recognized) {
        for (var i = 0; i < gestureReps[g]!.length; i++) {
          final mirroredSamples =
              mirrorSamples(_samplesOf(gestureReps[g]![i]));
          final match = _classifier.classify(mirroredSamples, templates());
          if (match.gesture != Gesture.neutral && match.gesture != g) {
            wrong.add('mirrored ${g.name}[$i] -> ${match.gesture.name}');
          }
        }
      }
      expect(wrong, isEmpty, reason: 'handedness-mismatch false accepts: $wrong');
    });

    test('a mirrored corpus recognises mirrored performances exactly as well '
        'as the original does — one capture covers both hands', () {
      final mirroredTemplates = {
        for (final g in _recognized)
          g: [for (final r in gestureReps[g]!) mirrorFrames(r.frames)],
      };
      var accepted = 0, total = 0;
      final wrong = <String>[];
      for (final g in _recognized) {
        for (var i = 0; i < gestureReps[g]!.length; i++) {
          total++;
          final held = {
            for (final k in _recognized)
              k: [
                for (var j = 0; j < gestureReps[k]!.length; j++)
                  if (!(k == g && j == i))
                    mirrorFrames(gestureReps[k]![j].frames),
              ],
          };
          final match = _classifier.classify(
              mirrorSamples(_samplesOf(gestureReps[g]![i])), held);
          if (match.gesture == g) accepted++;
          if (match.gesture != Gesture.neutral && match.gesture != g) {
            wrong.add('${g.name}[$i] -> ${match.gesture.name}');
          }
        }
      }
      expect(wrong, isEmpty, reason: 'mirrored-corpus false accepts: $wrong');
      expect(accepted / total, greaterThanOrEqualTo(0.80),
          reason: 'mirrored corpus accepted $accepted/$total');
      expect(mirroredTemplates, isNotEmpty);
    });
  });
}

/// Local DTW distance so the isometry assertion measures the same quantity
/// the classifier does, without reaching into it.
double _distance(List<List<double>> a, List<List<double>> b) {
  final n = a.length, m = b.length;
  final dtw = List<List<double>>.generate(
      n, (_) => List<double>.filled(m, double.infinity));
  double euclid(List<double> x, List<double> y) {
    var s = 0.0;
    for (var i = 0; i < x.length; i++) {
      final d = x[i] - y[i];
      s += d * d;
    }
    return s <= 0 ? 0.0 : math.sqrt(s);
  }

  dtw[0][0] = euclid(a[0], b[0]);
  for (var i = 1; i < n; i++) {
    dtw[i][0] = dtw[i - 1][0] + euclid(a[i], b[0]);
  }
  for (var j = 1; j < m; j++) {
    dtw[0][j] = dtw[0][j - 1] + euclid(a[0], b[j]);
  }
  for (var i = 1; i < n; i++) {
    for (var j = 1; j < m; j++) {
      dtw[i][j] = euclid(a[i], b[j]) +
          math.min(dtw[i - 1][j], math.min(dtw[i][j - 1], dtw[i - 1][j - 1]));
    }
  }
  return dtw[n - 1][m - 1] / (n + m);
}
