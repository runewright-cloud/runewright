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
    this.energyFloor = 0.02,
    this.distanceCap = 4.0,
    this.marginThreshold = 0.5,
  });

  /// windowEnergy() below this = holding steady = neutral, skip DTW
  /// entirely. **Placeholder** — must sit above sensor noise + hand tremor,
  /// grid-searched from the "hold steady" confusable capture, exactly like
  /// DtwMatcher.score's `scale` placeholder was calibrated against real
  /// recordings. Not yet calibrated against a real device.
  final double energyFloor;

  /// Reject a match whose best DTW distance is >= this (query resembles no
  /// enrolled gesture closely enough). **Placeholder**, same caveat.
  final double distanceCap;

  /// Reject a match whose margin over the second-best gesture is <= this
  /// (query is ambiguous between two gestures). **Placeholder**, same
  /// caveat. Grid-search all three constants together via the confusion
  /// matrix harness (SOMATIC_GESTURE_PLAN.md §6.5/§9) once a real corpus
  /// exists — do not hand-tune in isolation.
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

    final queryFrames = imuFeatureFrames(query);
    final distances = <Gesture, double>{};
    for (final entry in templatesByGesture.entries) {
      if (entry.value.isEmpty) continue; // unenrolled — not a candidate
      var best = double.infinity;
      for (final rep in entry.value) {
        final d = DtwMatcher.distance(queryFrames, rep);
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
