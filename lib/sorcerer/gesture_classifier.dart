// SPDX-License-Identifier: GPL-3.0-or-later
//
// gesture_classifier.dart — GestureClassifier: the somatic-cast open-set
// recognizer. Pure computation (no I/O, no sensors_plus), so it is testable
// without hardware — mirrors mfcc.dart/DtwMatcher's separation from
// vocal_scorer.dart's mic plumbing.
//
// Pipeline (SOMATIC_GESTURE_PLAN.md §6), cheapest/most-reliable gate first:
//   1. stillness floor  — windowEnergy(query) < energyFloor      -> neutral
//   2. open-set DTW      — min DTW distance to each gesture's rep set
//   3. accept rule       — best < distanceCap AND
//                           (secondBest - best) > marginThreshold -> match
//                           else                                  -> neutral
//
// Reuses DtwMatcher.distance (mfcc.dart) rather than reimplementing DTW —
// it is generic over List<List<double>> and already Sakoe-Chiba-free
// Euclidean-cost DTW, which is exactly what a 6-component IMU feature frame
// needs. No new DTW code, no new dependency.
//
// Design stance (SOMATIC_GESTURE_PLAN.md §0): gesticulation is meant to be
// hard to learn, so the accept rule is tuned strict — never-false-advance,
// same posture as the vocal scorer. Neutral is the universal safe sink: an
// unrecognized, ambiguous, or ineligible gesture always resolves to no
// enhancement, never the wrong one.

import 'dart:math' as math;

import 'gesture.dart';
import 'imu_sample.dart';
import 'mfcc.dart' show DtwMatcher;

/// Result of classifying one captured gesture attempt.
class GestureMatch {
  const GestureMatch({
    required this.gesture,
    required this.stillnessGated,
    required this.distances,
  });

  /// The resolved gesture. [Gesture.neutral] for every rejection path
  /// (stillness, no confident match, or — applied by the caller, not here —
  /// certified ineligibility; see SOMATIC_GESTURE_PLAN.md §5).
  final Gesture gesture;

  /// True if the query never reached DTW matching because it was below the
  /// energy floor (holding steady).
  final bool stillnessGated;

  /// Best DTW distance found per candidate gesture, for calibration/debug
  /// readouts (the confusion-matrix harness and the practice-screen "test
  /// last capture" readout both want this, not just the final verdict).
  /// Empty when [stillnessGated] or when no gesture had any enrolled reps.
  final Map<Gesture, double> distances;

  @override
  String toString() =>
      'GestureMatch(gesture: $gesture, stillnessGated: $stillnessGated, '
      'distances: $distances)';
}

class GestureClassifier {
  const GestureClassifier({
    this.energyFloor = 8.0,
    this.distanceCap = 0.80,
    this.marginThreshold = 0.15,
  });

  /// windowEnergy() below this = holding steady = neutral, skip DTW
  /// entirely.
  ///
  /// Calibrated against the real Pixel 6 corpus: idle captures top out at
  /// mean-square energy 7.76, while the weakest genuine gesture rep (fire)
  /// sits at 13.75. 8.0 clears every recorded idle without gating any
  /// recorded gesture. The previous placeholder of 0.02 was ~400x too low —
  /// real stillness sails straight past it, which is how a still hand
  /// reached DTW and came out "fire".
  ///
  /// This is a cheap early-out, not the primary defence: idle also sits
  /// >1.1 away in normalised DTW space, comfortably outside [distanceCap].
  final double energyFloor;

  /// Reject a match whose best DTW distance is >= this (query resembles no
  /// enrolled gesture closely enough).
  ///
  /// Calibrated over the real corpus in normalised feature space (see
  /// [normalizeForMatching]) — NOT comparable to a distance on raw frames.
  /// Genuine reps span 0.21-0.86; the closest impostor (theatrical
  /// "garbage") sits near 0.90. 0.80 accepts 90% of genuine reps with zero
  /// false accepts and leaves headroom below the first impostor.
  ///
  /// Bias this DOWN, never up: a rejected genuine gesture is merely a cast
  /// without enhancement, but a false accept applies the *wrong*
  /// enhancement and breaks the never-false-advance bar
  /// (SOMATIC_GESTURE_PLAN.md §0).
  final double distanceCap;

  /// Reject a match whose margin over the second-best gesture is <= this
  /// (query is ambiguous between two gestures). Calibrated jointly with
  /// [distanceCap] and [energyFloor] over the real corpus — do not
  /// hand-tune one in isolation; re-run
  /// `tool/gesture_corpus_analysis.dart` after any change.
  final double marginThreshold;

  /// Classifies [query] against [templatesByGesture] (each gesture's
  /// enrolled rep set, from GestureTemplateSource — NOT averaged; DTW
  /// matches against the nearest individual rep, per SOMATIC_GESTURE_PLAN.md
  /// §4's "don't average misaligned time-series" rule).
  ///
  /// A gesture with an empty rep list (unenrolled) is simply never a
  /// candidate — the safe default for "not yet calibrated" is neutral, not
  /// a crash or a guess.
  GestureMatch classify(
    List<ImuSample> query,
    Map<Gesture, List<List<List<double>>>> templatesByGesture,
  ) {
    if (query.isEmpty || windowEnergy(query) < energyFloor) {
      return const GestureMatch(
        gesture: Gesture.neutral,
        stillnessGated: true,
        distances: {},
      );
    }

    // Both sides go through normalizeForMatching: template reps are stored
    // raw (so the corpus stays reprocessable as calibration evolves), so the
    // normalisation happens here rather than at write time. Cost is O(frames)
    // against DTW's O(n*m) — immaterial.
    final queryFrames = normalizeForMatching(imuFeatureFrames(query));
    final distances = <Gesture, double>{};
    for (final entry in templatesByGesture.entries) {
      if (entry.value.isEmpty) continue; // unenrolled — not a candidate
      var best = double.infinity;
      for (final rep in entry.value) {
        final d = DtwMatcher.distance(queryFrames, normalizeForMatching(rep));
        if (d < best) best = d;
      }
      distances[entry.key] = best;
    }

    if (distances.isEmpty) {
      return GestureMatch(
        gesture: Gesture.neutral,
        stillnessGated: false,
        distances: distances,
      );
    }

    final ranked = distances.entries.toList()
      ..sort((a, b) => a.value.compareTo(b.value));
    final best = ranked.first;
    final secondBestDistance =
        ranked.length > 1 ? ranked[1].value : double.infinity;
    final margin = secondBestDistance - best.value;

    // secondBestDistance is +infinity when only one gesture has any
    // enrolled reps — margin is then infinite too, so the cap alone gates.
    final accepted = best.value < distanceCap && margin > marginThreshold;

    return GestureMatch(
      gesture: accepted ? best.key : Gesture.neutral,
      stillnessGated: false,
      distances: distances,
    );
  }
}

/// √ of [GestureClassifier.energyFloor] in the same units as [windowRms] —
/// convenience for UI readouts that want to show energy against the floor
/// in a physically comparable scale.
double energyFloorRms(GestureClassifier classifier) =>
    math.sqrt(classifier.energyFloor);
