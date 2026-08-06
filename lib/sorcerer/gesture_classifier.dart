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

// ── Free-style cast motion (docs/SPELL_COMPONENTS_PLAN.md §4.1) ──────────────
//
// The hold is a performance, not a trigger: a caster is expected to gesticulate
// for its whole duration and land on the gesture they want at the end. This
// gate asks the separate question "were you moving THROUGHOUT" — the
// classifier's own stillness gate (§6.1) only asks "did anything happen at
// all", which a single flourish inside an otherwise motionless hold satisfies.
//
// It deliberately introduces NO new calibrated threshold. SOMATIC_GESTURE_PLAN
// §6.5 requires every constant to come out of the §9 harness rather than being
// invented, and there is no corpus of free-style casting motion to grid-search
// against. What makes this an independent check is the COVERAGE rule below,
// evaluated against the one energy floor that has been measured.
//
// Failing it costs the caster their enhancement and nothing else — no mana
// term, no refused cast, no wire field. It cannot be otherwise: whether a
// phone moved is a self-attested sensor claim the peer can never recheck.

/// Windows the hold is split into for the coverage test.
const int kCastMotionWindows = 4;

/// How many of those windows must clear the energy floor.
///
/// 3 of 4 rather than 4 of 4 so that the moment of settling into the final
/// gesture — or a brief fumble — does not void an otherwise committed
/// performance. Biased toward accepting the honest caster, which is the safe
/// direction here: the failure mode is losing a buff, never losing a turn.
const int kCastMotionWindowsRequired = 3;

/// Minimum samples in the hold before the coverage test means anything.
///
/// At the ~55 Hz the Pixel 6 actually reports (SOMATIC_GESTURE_PLAN §12), 32
/// samples is a hold of well under a second — short enough that a genuine
/// cast never trips it, long enough that each of the four windows holds
/// several samples rather than one.
const int kMinCastMotionSamples = 32;

/// True when [samples] show sustained motion across the whole hold.
///
/// Splits the capture into [kCastMotionWindows] equal windows by sample count
/// and requires at least [kCastMotionWindowsRequired] of them to exceed
/// [classifier]'s energy floor. A capture shorter than
/// [kMinCastMotionSamples] fails — there is not enough of a performance there
/// to judge.
///
/// Split by sample count, not by wall-clock time: the two IMU streams are
/// merged by nearest timestamp (gesture_capture.dart) and the resulting rate
/// is steady but not exact, so equal sample counts give equal statistical
/// weight per window where equal time spans would not.
bool castMotionSatisfied(
  List<ImuSample> samples, {
  GestureClassifier classifier = const GestureClassifier(),
}) {
  if (samples.length < kMinCastMotionSamples) return false;
  final per = samples.length ~/ kCastMotionWindows;
  var moving = 0;
  for (var w = 0; w < kCastMotionWindows; w++) {
    // The last window takes the remainder, so no sample goes unjudged.
    final end = w == kCastMotionWindows - 1 ? samples.length : (w + 1) * per;
    final window = samples.sublist(w * per, end);
    if (windowEnergy(window) >= classifier.energyFloor) moving++;
  }
  return moving >= kCastMotionWindowsRequired;
}
