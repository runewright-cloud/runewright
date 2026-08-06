// SPDX-License-Identifier: GPL-3.0-or-later
//
// gesture_rep_count_sweep.dart — how many attunements per gesture is enough?
// A bench tool, not a test. Companion to gesture_corpus_analysis.dart, which
// answers "what thresholds?"; this one answers "how many reps behind them?".
//
// Usage: dart run tool/gesture_rep_count_sweep.dart [corpus_dir]
//   (defaults to test/sorcerer/fixtures/corpus_pixel6)
//
// Method: for each enrolled-set size N, hold one rep out as the query, draw
// [_trials] random N-subsets of the remaining reps as that gesture's enrolled
// set, and run the REAL GestureClassifier over them. Repeats for every rep of
// every gesture, then runs the confusables through the same enrolled sets.
//
// Reports, per N:
//   accept   — genuine reps read as themselves (higher is better)
//   WRONG    — genuine reps read as a DIFFERENT gesture (must stay 0: this is
//              SOMATIC_GESTURE_PLAN.md §0's never-false-advance bar)
//   falseacc — confusables (idle/walk/garbage) read as any gesture (must be 0)
//   cost     — mean DTW pair count per classification, i.e. what one more
//              enrolled rep costs on the per-cast path at runtime.
//
// Subsets are drawn from a FIXED seed so the sweep is reproducible run to run.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:rune_duel/sorcerer/gesture.dart';
import 'package:rune_duel/sorcerer/gesture_classifier.dart';
import 'package:rune_duel/sorcerer/imu_sample.dart';

const _defaultCorpus = 'test/sorcerer/fixtures/corpus_pixel6';
const _trials = 12;
const _seed = 20260806;

const _gestures = [
  Gesture.fire,
  Gesture.air,
  Gesture.water,
  Gesture.earth,
  Gesture.melee,
];

/// The three enrollment-only confusable labels (GestureConfusable's names).
/// Spelled out rather than imported: gesture_enrollment.dart pulls in
/// path_provider and therefore Flutter, which `dart run` cannot load — the
/// same reason gesture_corpus_analysis.dart parses the corpus itself.
const _confusableNames = ['idle', 'walk', 'garbage'];

/// One stored repetition, read straight off disk (see above).
class Rep {
  Rep(this.rateHz, this.frames);
  final double rateHz;
  final List<List<double>> frames;
}

List<Rep> loadReps(String dir, String fileStem) {
  final f = File('$dir/$fileStem.json');
  if (!f.existsSync()) return const [];
  final json = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
  return [
    for (final r in json['reps'] as List)
      Rep(
        ((r as Map<String, dynamic>)['rateHz'] as num).toDouble(),
        (r['frames'] as List)
            .map((row) =>
                (row as List).map((v) => (v as num).toDouble()).toList())
            .toList(),
      ),
  ];
}

/// Corpus reps are stored as feature frames; the classifier takes raw samples
/// and derives frames itself. Rehydrating through [ImuSample] runs the query
/// down the exact path a live capture takes — same as the e2e test does.
List<ImuSample> toSamples(Rep rep) {
  final periodMs = 1000.0 / rep.rateHz;
  return [
    for (var i = 0; i < rep.frames.length; i++)
      ImuSample(
        tMs: (i * periodMs).round(),
        ax: rep.frames[i][0], ay: rep.frames[i][1], az: rep.frames[i][2],
        gx: rep.frames[i][3], gy: rep.frames[i][4], gz: rep.frames[i][5],
      ),
  ];
}

void main(List<String> args) {
  final dir = args.isNotEmpty ? args.first : _defaultCorpus;
  final classifier = const GestureClassifier();

  final reps = <Gesture, List<Rep>>{
    for (final g in _gestures) g: loadReps(dir, g.name),
  };
  final confusables = <String, List<Rep>>{
    for (final c in _confusableNames) c: loadReps(dir, 'confusable_$c'),
  };
  final available =
      reps.values.map((r) => r.length).reduce((a, b) => a < b ? a : b);
  if (available < 2) {
    stderr.writeln('Corpus at $dir has too few reps ($available) to sweep.');
    exitCode = 1;
    return;
  }

  stdout.writeln('corpus: $dir  ($available reps per gesture)');
  stdout.writeln('classifier: cap=${classifier.distanceCap} '
      'margin=${classifier.marginThreshold} floor=${classifier.energyFloor}');
  stdout.writeln('');
  stdout.writeln('   N   accept   WRONG   falseacc   cost(DTW pairs/cast)');

  // Held out one at a time, so the largest enrolled set the corpus can
  // honestly evaluate is (available - 1).
  for (var n = 1; n <= available - 1; n++) {
    final rng = math.Random(_seed + n);
    var genuine = 0, correct = 0, wrong = 0;
    var confusableTries = 0, falseAccepts = 0;

    for (var trial = 0; trial < _trials; trial++) {
      for (final target in _gestures) {
        for (var q = 0; q < reps[target]!.length; q++) {
          // Enrolled set for every gesture, excluding the query rep itself
          // from its own gesture — leave-one-out, not self-recognition.
          final templates = <Gesture, List<List<List<double>>>>{};
          for (final g in _gestures) {
            final pool = [
              for (var i = 0; i < reps[g]!.length; i++)
                if (!(g == target && i == q)) reps[g]![i].frames,
            ]..shuffle(rng);
            templates[g] = pool.take(n).toList();
          }
          final match =
              classifier.classify(toSamples(reps[target]![q]), templates);
          genuine++;
          if (match.gesture == target) {
            correct++;
          } else if (match.gesture != Gesture.neutral) {
            wrong++;
          }

          // One confusable per (trial, target, q) against the same enrolled
          // set — cheaper than the full cross product, same expectation.
          final cKind =
              _confusableNames[confusableTries % _confusableNames.length];
          final cPool = confusables[cKind]!;
          if (cPool.isNotEmpty) {
            final cRep = cPool[rng.nextInt(cPool.length)];
            final cMatch = classifier.classify(toSamples(cRep), templates);
            confusableTries++;
            if (cMatch.gesture != Gesture.neutral) falseAccepts++;
          }
        }
      }
    }

    final acceptPct = 100.0 * correct / genuine;
    final wrongPct = 100.0 * wrong / genuine;
    final falsePct =
        confusableTries == 0 ? 0.0 : 100.0 * falseAccepts / confusableTries;
    stdout.writeln('  ${n.toString().padLeft(2)}   '
        '${acceptPct.toStringAsFixed(1).padLeft(5)}%   '
        '${wrongPct.toStringAsFixed(1).padLeft(5)}%   '
        '${falsePct.toStringAsFixed(1).padLeft(6)}%   '
        '${(n * _gestures.length).toString().padLeft(4)}');
  }
}
