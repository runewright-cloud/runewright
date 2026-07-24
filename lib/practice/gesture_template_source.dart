// SPDX-License-Identifier: GPL-3.0-or-later
//
// gesture_template_source.dart — GestureTemplateSource: the thin,
// swappable abstraction in front of GestureClassifier, mirroring
// vocal_template_source.dart's VocalTemplateSource.
//
// Unlike vocal (which falls back to a bundled Piper voice per word), there
// is no bundled reference gesture — an un-enrolled gesture has no fallback
// and simply isn't a classification candidate (GestureClassifier already
// treats an empty rep list as "not a candidate", the safe default). The
// abstraction still earns its keep: it's what lets tests substitute
// synthetic fixtures without touching disk, and what keeps
// GestureClassifier's caller source-agnostic if a second source (e.g. a
// bundled example gesture to imitate) is ever added.

import '../sorcerer/gesture.dart';
import 'gesture_enrollment.dart';

/// Supplies the enrolled repetition set for a [Gesture]. Each rep is a
/// full feature-frame sequence (SOMATIC_GESTURE_PLAN.md §4: never averaged).
abstract class GestureTemplateSource {
  Future<List<List<List<double>>>> repsFor(Gesture gesture);
}

/// [GestureTemplateSource] backed by the player's own enrolled recordings.
/// Not cached across enrollments — call [invalidate] after saving or
/// clearing an enrollment so the next classification picks up new reps.
class EnrolledGestureTemplateSource implements GestureTemplateSource {
  EnrolledGestureTemplateSource(this.enrollment);

  final GestureEnrollment enrollment;
  final Map<Gesture, List<List<List<double>>>> _cache = {};

  void invalidate() => _cache.clear();

  @override
  Future<List<List<List<double>>>> repsFor(Gesture gesture) async {
    final cached = _cache[gesture];
    if (cached != null) return cached;
    final reps = await enrollment.repsFor(gesture);
    final frames = reps.map((r) => r.frames).toList();
    _cache[gesture] = frames;
    return frames;
  }
}

/// Builds the full `{gesture: reps}` map [GestureClassifier.classify]
/// takes, from [source], for each of [gestures].
Future<Map<Gesture, List<List<List<double>>>>> loadGestureTemplates(
  GestureTemplateSource source,
  Iterable<Gesture> gestures,
) async {
  final map = <Gesture, List<List<List<double>>>>{};
  for (final g in gestures) {
    map[g] = await source.repsFor(g);
  }
  return map;
}
