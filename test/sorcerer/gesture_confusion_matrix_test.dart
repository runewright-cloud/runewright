// SPDX-License-Identifier: GPL-3.0-or-later
//
// gesture_confusion_matrix_test.dart — confusion-matrix harness mechanics,
// run over a SYNTHETIC corpus.
//
// IMPORTANT — this is NOT the SOMATIC_GESTURE_PLAN.md §9 calibration gate.
// That gate requires a REAL captured corpus (test/sorcerer/fixtures/, built
// from lib/ui/practice_screen.dart's Gesture tab on a real device) — the
// somatic analog of test/practice/real_template_e2e_test.dart, which is
// what caught the vocal scorer's real "silence crosses templates in 40ms"
// bug that no synthetic test found (docs/M4_findings.md 2026-07-16). No
// physical device / IMU is available in this development environment, so
// that real corpus and its real-device pass remain outstanding — see
// SOMATIC_GESTURE_PLAN.md §11 build order, step 6, and gesture.dart's
// kSomaticCaptureEnabled, which stays false until it exists and passes.
//
// What THIS file verifies: the harness *mechanics* — that a confusion
// matrix built the way §9 specifies (recognized gestures × {gestures,
// confusables, neutral}) correctly flags a zero-false-accept pass/fail,
// using the same synthetic fixture generators as gesture_classifier_test.dart.
// When the real corpus exists, build gesture_confusion_e2e_test.dart beside
// this file (same matrix-building code, real WAV/JSON fixtures loaded from
// disk) rather than editing this one — keep the synthetic mechanics check
// and the real hardware gate as separate, clearly-named files, exactly like
// the vocal side keeps its synthetic chirp tests separate from
// real_template_e2e_test.dart.

import 'dart:math' as math;

import 'package:test/test.dart';
import 'package:rune_duel/sorcerer/gesture.dart';
import 'package:rune_duel/sorcerer/gesture_classifier.dart';
import 'package:rune_duel/sorcerer/imu_sample.dart';

List<ImuSample> _oscillation({
  required int n,
  required double freqHz,
  required double amplitude,
  double phase = 0.0,
  int seed = 0,
  double axisEmphasis = 1.0,
  double rateHz = 100,
}) {
  final rnd = math.Random(seed);
  double jitter() => (rnd.nextDouble() - 0.5) * amplitude * 0.08;
  return List.generate(n, (i) {
    final tMs = (i * 1000 / rateHz).round();
    final t = tMs / 1000.0;
    final base = amplitude * math.sin(2 * math.pi * freqHz * t + phase);
    return ImuSample(
      tMs: tMs,
      ax: base * axisEmphasis + jitter(),
      ay: base * (1 - axisEmphasis) + jitter(),
      az: jitter(),
      gx: base * 0.4 * axisEmphasis + jitter(),
      gy: base * 0.4 * (1 - axisEmphasis) + jitter(),
      gz: jitter(),
    );
  });
}

List<ImuSample> _fireRep({int seed = 0}) =>
    _oscillation(n: 60, freqHz: 2.0, amplitude: 3.0, seed: seed, axisEmphasis: 1.0);
List<ImuSample> _waterRep({int seed = 0}) => _oscillation(
    n: 60, freqHz: 1.0, amplitude: 3.0, phase: math.pi / 2, seed: seed, axisEmphasis: 0.0);
List<ImuSample> _meleeRep({int seed = 0}) =>
    _oscillation(n: 40, freqHz: 3.5, amplitude: 4.0, seed: seed, axisEmphasis: 0.7);

List<ImuSample> _idle(int n, {int seed = 0}) {
  final rnd = math.Random(seed);
  double noise() => (rnd.nextDouble() - 0.5) * 0.01;
  return List.generate(
    n,
    (i) => ImuSample(
        tMs: i * 10, ax: noise(), ay: noise(), az: noise(),
        gx: noise(), gy: noise(), gz: noise()),
  );
}

/// Low-frequency, large-amplitude, vertical-axis-dominant — a walking
/// bounce, deliberately shaped unlike any of the three enrolled gestures.
List<ImuSample> _walk(int n, {int seed = 0}) => _oscillation(
    n: n, freqHz: 0.6, amplitude: 2.0, seed: seed, axisEmphasis: 0.5)
    .map((s) => ImuSample(tMs: s.tMs, ax: s.ax * 0.2, ay: s.ay * 0.2,
        az: s.ax.abs(), gx: s.gx * 0.2, gy: s.gy * 0.2, gz: s.gz))
    .toList();

List<ImuSample> _garbage(int n, {int seed = 0, double amplitude = 3.0}) {
  final rnd = math.Random(seed);
  double v() => (rnd.nextDouble() - 0.5) * 2 * amplitude;
  return List.generate(
    n,
    (i) => ImuSample(tMs: i * 10, ax: v(), ay: v(), az: v(), gx: v(), gy: v(), gz: v()),
  );
}

const _classifier = GestureClassifier(
  energyFloor: 0.05,
  distanceCap: 3.0,
  marginThreshold: 0.3,
);

Map<Gesture, List<List<List<double>>>> _enrolledTemplates() => {
      Gesture.fire: [for (var i = 0; i < 6; i++) imuFeatureFrames(_fireRep(seed: i))],
      Gesture.water: [for (var i = 0; i < 6; i++) imuFeatureFrames(_waterRep(seed: 10 + i))],
      Gesture.melee: [for (var i = 0; i < 6; i++) imuFeatureFrames(_meleeRep(seed: 20 + i))],
    };

void main() {
  final templates = _enrolledTemplates();

  group('own-gesture reps accept as themselves (held-out from enrollment)', () {
    test('fire', () {
      for (var seed = 500; seed < 510; seed++) {
        expect(_classifier.classify(_fireRep(seed: seed), templates).gesture,
            Gesture.fire, reason: 'seed=$seed');
      }
    });
    test('water', () {
      for (var seed = 500; seed < 510; seed++) {
        expect(_classifier.classify(_waterRep(seed: seed), templates).gesture,
            Gesture.water, reason: 'seed=$seed');
      }
    });
    test('melee', () {
      for (var seed = 500; seed < 510; seed++) {
        expect(_classifier.classify(_meleeRep(seed: seed), templates).gesture,
            Gesture.melee, reason: 'seed=$seed');
      }
    });
  });

  group('every confusable resolves to neutral — the strict, never-false-'
      'advance bar (SOMATIC_GESTURE_PLAN.md §0/§9)', () {
    test('idle', () {
      for (var seed = 0; seed < 10; seed++) {
        final match = _classifier.classify(_idle(60, seed: seed), templates);
        expect(match.gesture, Gesture.neutral, reason: 'seed=$seed');
      }
    });
    test('walk', () {
      for (var seed = 0; seed < 10; seed++) {
        final match = _classifier.classify(_walk(60, seed: seed), templates);
        expect(match.gesture, Gesture.neutral, reason: 'seed=$seed');
      }
    });
    test('garbage', () {
      for (var seed = 0; seed < 10; seed++) {
        final match = _classifier.classify(_garbage(60, seed: seed), templates);
        expect(match.gesture, Gesture.neutral, reason: 'seed=$seed');
      }
    });
  });

  test('gate condition: zero wrong-gesture false-accepts across the full '
      'synthetic matrix (a release-blocker bar once this is a real corpus)', () {
    final rows = <String, List<ImuSample> Function(int)>{
      'fire': (seed) => _fireRep(seed: seed),
      'water': (seed) => _waterRep(seed: seed),
      'melee': (seed) => _meleeRep(seed: seed),
      'idle': (seed) => _idle(60, seed: seed),
      'walk': (seed) => _walk(60, seed: seed),
      'garbage': (seed) => _garbage(60, seed: seed),
    };

    final falseAccepts = <String>[];
    for (final row in rows.entries) {
      for (var seed = 800; seed < 805; seed++) {
        final match = _classifier.classify(row.value(seed), templates);
        final expectedGesture = switch (row.key) {
          'fire' => Gesture.fire,
          'water' => Gesture.water,
          'melee' => Gesture.melee,
          _ => Gesture.neutral, // every confusable's only correct label
        };
        if (match.gesture != Gesture.neutral && match.gesture != expectedGesture) {
          falseAccepts.add('${row.key}(seed=$seed) -> ${match.gesture.name}');
        }
      }
    }
    expect(falseAccepts, isEmpty,
        reason: 'wrong-gesture false-accepts: $falseAccepts');
  });
}
