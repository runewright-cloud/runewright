// SPDX-License-Identifier: GPL-3.0-or-later
//
// gesture_enrollment.dart — GestureEnrollment: persistence for per-user
// somatic-gesture templates (Practice Mode), mirroring vocal_enrollment.dart.
//
// Why reps, not an average (SOMATIC_GESTURE_PLAN.md §4): repetitions of a
// gesture are not time-aligned — one is faster, one starts mid-swing.
// Element-wise averaging of misaligned time-series produces a blurred
// template that matches nothing, the somatic analog of the floor-only MFCC
// bug that let silence cross word templates (docs/M4_findings.md
// 2026-07-16). So each saved repetition is kept as-is; GestureClassifier
// matches a query against the *nearest* stored rep via DTW, never a mean.
//
// Confusables (idle/walk/garbage — SOMATIC_GESTURE_PLAN.md §8) are captured
// alongside real gestures because "close enough" can only be thresholded
// against something on the reject side. They are NOT part of the runtime
// Gesture enum (they're not enhancements or actions) — GestureConfusable is
// a separate, enrollment-only vocabulary.
//
// Storage: <app documents>/gesture_enrollment/<name>.json,
// {"reps": [{"rateHz": <measured>, "frames": [[ax,ay,az,gx,gy,gz], ...]}]}.
// Local-only, never leaves the device, consensus-invisible — same posture
// as vocal_enrollment.dart.

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../sorcerer/gesture.dart';
import '../sorcerer/imu_sample.dart';

/// Confusable motion captured during calibration to define the reject side
/// of the accept/reject boundary. Not a runtime Gesture — see file header.
enum GestureConfusable { idle, walk, garbage }

/// Thrown when a captured repetition can't yield a usable rep (too short,
/// or — for a real gesture, not a confusable — too still to be a gesture
/// at all). The message is user-presentable.
class GestureEnrollmentException implements Exception {
  const GestureEnrollmentException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// One stored repetition: the feature-frame sequence plus the sample rate
/// it was captured at (recorded, never assumed — SOMATIC_GESTURE_PLAN.md
/// §12 leaves the resample rate as a `[DECISION — needs Soren]` pending
/// real capture data).
class GestureRep {
  const GestureRep({required this.rateHz, required this.frames});

  final double rateHz;
  final List<List<double>> frames;

  Map<String, dynamic> toJson() => {'rateHz': rateHz, 'frames': frames};

  static GestureRep fromJson(Map<String, dynamic> json) => GestureRep(
        rateHz: (json['rateHz'] as num).toDouble(),
        frames: (json['frames'] as List)
            .map((row) =>
                (row as List).map((v) => (v as num).toDouble()).toList())
            .toList(),
      );
}

/// Persistence for per-user gesture templates. [baseDir] is injectable for
/// tests; production callers use [GestureEnrollment.open], anchored under
/// the app documents directory (same pattern as VocalEnrollment).
class GestureEnrollment {
  GestureEnrollment(this.baseDir);

  final Directory baseDir;

  static Future<GestureEnrollment> open() async {
    final docs = await getApplicationDocumentsDirectory();
    return GestureEnrollment(Directory('${docs.path}/gesture_enrollment'));
  }

  /// A repetition must span at least this many samples to be usable —
  /// shorter than this is almost certainly a mis-timed hold, not a real
  /// attempt. Placeholder threshold; not yet calibrated against real holds.
  static const int minSamplesPerRep = 15;

  /// Cap on stored reps per gesture/confusable — DTW matching is O(N·M) per
  /// rep and per candidate, so unbounded accumulation would slow live
  /// classification. 20 is comfortably above the >=10 the plan asks for to
  /// measure intra-gesture variance (SOMATIC_GESTURE_PLAN.md §8).
  static const int maxRepsStored = 20;

  File _gestureFile(Gesture g) => File('${baseDir.path}/${g.name}.json');
  File _confusableFile(GestureConfusable c) =>
      File('${baseDir.path}/confusable_${c.name}.json');

  bool hasGestureReps(Gesture g) => _gestureFile(g).existsSync();
  bool hasConfusableReps(GestureConfusable c) =>
      _confusableFile(c).existsSync();

  /// Saves one repetition of [gesture] from raw [samples]. Rejects
  /// captures below [minSamplesPerRep] and — for real gestures, unlike
  /// confusables — captures whose energy never clears the stillness floor
  /// (a "gesture" that's just a still hold isn't a usable reference).
  Future<int> saveGestureRep(
    Gesture gesture,
    List<ImuSample> samples, {
    double stillnessFloor = 8.0, // matches GestureClassifier.energyFloor
  }) async {
    if (samples.length < minSamplesPerRep) {
      throw const GestureEnrollmentException(
          'Hold too short — perform the full gesture while holding the '
          'button, then release.');
    }
    if (windowEnergy(samples) < stillnessFloor) {
      throw const GestureEnrollmentException(
          'That looked like holding still, not the gesture — try again '
          'with clear motion.');
    }
    return _appendRep(_gestureFile(gesture), samples);
  }

  /// Saves one repetition of [confusable]. No stillness check — "idle" is
  /// *supposed* to be still; "garbage" and "walk" are checked for minimum
  /// length only.
  Future<int> saveConfusableRep(
    GestureConfusable confusable,
    List<ImuSample> samples,
  ) async {
    if (samples.length < minSamplesPerRep) {
      throw const GestureEnrollmentException(
          'Hold too short — hold the button for the full confusable motion, '
          'then release.');
    }
    return _appendRep(_confusableFile(confusable), samples);
  }

  Future<int> _appendRep(File file, List<ImuSample> samples) async {
    final rep = GestureRep(
      rateHz: impliedSampleRateHz(samples),
      frames: imuFeatureFrames(samples),
    );
    final existing = await _loadReps(file);
    final reps = [...existing, rep];
    final capped =
        reps.length > maxRepsStored ? reps.sublist(reps.length - maxRepsStored) : reps;
    await baseDir.create(recursive: true);
    await file.writeAsString(
        jsonEncode({'reps': capped.map((r) => r.toJson()).toList()}));
    return capped.length;
  }

  Future<List<GestureRep>> _loadReps(File file) async {
    if (!file.existsSync()) return const [];
    final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    return (json['reps'] as List)
        .map((r) => GestureRep.fromJson(r as Map<String, dynamic>))
        .toList();
  }

  Future<List<GestureRep>> repsFor(Gesture gesture) =>
      _loadReps(_gestureFile(gesture));

  Future<List<GestureRep>> confusableRepsFor(GestureConfusable confusable) =>
      _loadReps(_confusableFile(confusable));

  Future<int> repCountFor(Gesture gesture) async =>
      (await repsFor(gesture)).length;

  Future<int> confusableRepCountFor(GestureConfusable confusable) async =>
      (await confusableRepsFor(confusable)).length;

  Set<Gesture> enrolledGestures() =>
      Gesture.values.where(hasGestureReps).toSet();

  Set<GestureConfusable> enrolledConfusables() =>
      GestureConfusable.values.where(hasConfusableReps).toSet();

  Future<void> clearAll() async {
    if (baseDir.existsSync()) await baseDir.delete(recursive: true);
  }
}
