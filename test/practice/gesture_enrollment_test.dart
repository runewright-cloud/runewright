// SPDX-License-Identifier: GPL-3.0-or-later
//
// gesture_enrollment_test.dart — unit tests for GestureEnrollment
// (lib/practice/gesture_enrollment.dart) and EnrolledGestureTemplateSource,
// using an injected temp directory (no path_provider / Flutter binding
// needed) — mirrors vocal_enrollment_test.dart's structure.

import 'dart:io';
import 'dart:math' as math;

import 'package:test/test.dart';
import 'package:rune_duel/practice/gesture_enrollment.dart';
import 'package:rune_duel/practice/gesture_template_source.dart';
import 'package:rune_duel/sorcerer/gesture.dart';
import 'package:rune_duel/sorcerer/imu_sample.dart';

List<ImuSample> _movingSamples(int n, {double amplitude = 3.0, int seed = 0}) {
  final rnd = math.Random(seed);
  return List.generate(n, (i) {
    final t = i / 100.0;
    final base = amplitude * math.sin(2 * math.pi * 2.0 * t);
    final j = (rnd.nextDouble() - 0.5) * 0.1;
    return ImuSample(
      tMs: i * 10,
      ax: base + j, ay: j, az: j,
      gx: base * 0.3 + j, gy: j, gz: j,
    );
  });
}

List<ImuSample> _stillSamples(int n) => List.generate(
      n,
      (i) => ImuSample(tMs: i * 10, ax: 0.001, ay: 0, az: 0, gx: 0, gy: 0, gz: 0),
    );

void main() {
  late Directory tempDir;
  late GestureEnrollment enrollment;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('gesture_enrollment_test');
    enrollment = GestureEnrollment(Directory('${tempDir.path}/enroll'));
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  test('saveGestureRep -> repsFor roundtrip, hasGestureReps, clearAll', () async {
    expect(enrollment.hasGestureReps(Gesture.fire), isFalse);

    final count = await enrollment.saveGestureRep(Gesture.fire, _movingSamples(30));
    expect(count, 1);
    expect(enrollment.hasGestureReps(Gesture.fire), isTrue);
    expect(enrollment.enrolledGestures(), {Gesture.fire});

    final reps = await enrollment.repsFor(Gesture.fire);
    expect(reps.length, 1);
    expect(reps.first.frames.length, 30);
    expect(reps.first.frames.first.length, 6);
    expect(reps.first.rateHz, closeTo(100.0, 1.0));

    await enrollment.clearAll();
    expect(enrollment.enrolledGestures(), isEmpty);
    expect(await enrollment.repsFor(Gesture.fire), isEmpty);
  });

  test('multiple reps accumulate, not overwrite', () async {
    await enrollment.saveGestureRep(Gesture.water, _movingSamples(30, seed: 1));
    final second = await enrollment.saveGestureRep(Gesture.water, _movingSamples(30, seed: 2));
    expect(second, 2);
    expect(await enrollment.repCountFor(Gesture.water), 2);
  });

  test('reps are capped at maxRepsStored, keeping the most recent', () async {
    for (var i = 0; i < GestureEnrollment.maxRepsStored + 5; i++) {
      await enrollment.saveGestureRep(Gesture.fire, _movingSamples(20, seed: i));
    }
    final reps = await enrollment.repsFor(Gesture.fire);
    expect(reps.length, GestureEnrollment.maxRepsStored);
  });

  test('a too-short capture throws GestureEnrollmentException', () async {
    final tooShort = _movingSamples(GestureEnrollment.minSamplesPerRep - 1);
    await expectLater(
      enrollment.saveGestureRep(Gesture.fire, tooShort),
      throwsA(isA<GestureEnrollmentException>()),
    );
    expect(enrollment.hasGestureReps(Gesture.fire), isFalse);
  });

  test('a still capture (not a real gesture) throws GestureEnrollmentException', () async {
    await expectLater(
      enrollment.saveGestureRep(Gesture.fire, _stillSamples(30)),
      throwsA(isA<GestureEnrollmentException>()),
    );
    expect(enrollment.hasGestureReps(Gesture.fire), isFalse);
  });

  test('confusables: idle is exempt from the stillness check', () async {
    // Unlike a real gesture, a still "idle" confusable is exactly what
    // should be recorded — it must NOT throw.
    final count = await enrollment.saveConfusableRep(
        GestureConfusable.idle, _stillSamples(30));
    expect(count, 1);
    expect(enrollment.hasConfusableReps(GestureConfusable.idle), isTrue);
    expect(enrollment.enrolledConfusables(), {GestureConfusable.idle});
  });

  test('confusables still enforce the minimum-length guard', () async {
    await expectLater(
      enrollment.saveConfusableRep(
          GestureConfusable.walk, _stillSamples(GestureEnrollment.minSamplesPerRep - 1)),
      throwsA(isA<GestureEnrollmentException>()),
    );
  });

  test('EnrolledGestureTemplateSource serves reps and an empty list when unenrolled', () async {
    final source = EnrolledGestureTemplateSource(enrollment);

    // Nothing enrolled: empty, not a crash, not a fallback guess.
    expect(await source.repsFor(Gesture.fire), isEmpty);

    await enrollment.saveGestureRep(Gesture.fire, _movingSamples(30));
    source.invalidate();
    final reps = await source.repsFor(Gesture.fire);
    expect(reps.length, 1);
    expect(reps.first.length, 30);

    // Other gestures still report empty.
    expect(await source.repsFor(Gesture.water), isEmpty);
  });

  test('loadGestureTemplates builds the full map for a gesture set', () async {
    await enrollment.saveGestureRep(Gesture.fire, _movingSamples(30));
    final source = EnrolledGestureTemplateSource(enrollment);
    final map = await loadGestureTemplates(source, [Gesture.fire, Gesture.water]);
    expect(map[Gesture.fire]!.length, 1);
    expect(map[Gesture.water], isEmpty);
  });
}
