// SPDX-License-Identifier: GPL-3.0-or-later
//
// gesture_classifier_test.dart — GestureClassifier over synthetic IMU
// waveforms (no hardware available in this environment — see
// docs/SOMATIC_GESTURE_PLAN.md §11: a real captured corpus + real-device
// pass remain pending; this validates the pipeline mechanics only).
//
// Fixture design: each gesture is a distinct sine oscillation (frequency +
// axis emphasis + phase), matching the "bounded oscillation" description in
// SORCERER_REALTIME_PLAN.md §5.2. Reps of the same gesture get independent
// jitter/phase to simulate natural rep-to-rep variance without ever being
// identical (so DTW isn't trivially matching a byte-identical sequence).
// distanceCap/marginThreshold here are now the SHIPPED values, because
// normalizeForMatching puts synthetic and real captures on the same scale —
// so these fixtures exercise the real operating point rather than a
// fixture-specific one. Only energyFloor is overridden: these synthetic
// waveforms sit at mean-square energy ~5, below the 8.0 floor calibrated
// from real captures, and raising their amplitude would be tuning the
// fixture to the gate rather than testing the gate.
//
// The real calibration gate is gesture_confusion_e2e_test.dart, over the
// captured Pixel 6 corpus. This file tests pipeline mechanics.

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
  double axisEmphasis = 1.0, // 1.0 = ax/gx-heavy, 0.0 = ay/gy-heavy
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

List<ImuSample> _still(int n, {int seed = 0}) {
  final rnd = math.Random(seed);
  double noise() => (rnd.nextDouble() - 0.5) * 0.01;
  return List.generate(
    n,
    (i) => ImuSample(
      tMs: i * 10,
      ax: noise(), ay: noise(), az: noise(),
      gx: noise(), gy: noise(), gz: noise(),
    ),
  );
}

List<ImuSample> _garbage(int n, {int seed = 99, double amplitude = 3.0}) {
  final rnd = math.Random(seed);
  double v() => (rnd.nextDouble() - 0.5) * 2 * amplitude;
  return List.generate(
    n,
    (i) => ImuSample(
      tMs: i * 10,
      ax: v(), ay: v(), az: v(),
      gx: v(), gy: v(), gz: v(),
    ),
  );
}

// Fixture "gestures": clearly separated in frequency and axis emphasis.
List<ImuSample> _fireRep({int seed = 0}) =>
    _oscillation(n: 60, freqHz: 2.0, amplitude: 3.0, seed: seed, axisEmphasis: 1.0);
List<ImuSample> _waterRep({int seed = 0}) => _oscillation(
    n: 60, freqHz: 1.0, amplitude: 3.0, phase: math.pi / 2, seed: seed, axisEmphasis: 0.0);
List<ImuSample> _meleeRep({int seed = 0}) =>
    _oscillation(n: 40, freqHz: 3.5, amplitude: 4.0, seed: seed, axisEmphasis: 0.7);

Map<Gesture, List<List<List<double>>>> _templates() => {
      Gesture.fire: [for (var i = 0; i < 4; i++) imuFeatureFrames(_fireRep(seed: i))],
      Gesture.water: [for (var i = 0; i < 4; i++) imuFeatureFrames(_waterRep(seed: 10 + i))],
      Gesture.melee: [for (var i = 0; i < 4; i++) imuFeatureFrames(_meleeRep(seed: 20 + i))],
      // earth/air deliberately unenrolled — the "not yet calibrated" case.
      Gesture.earth: const [],
      Gesture.air: const [],
    };

const _classifier = GestureClassifier(
  energyFloor: 0.05, // synthetic still-noise is ~0.0001; real gestures ~4-9
  distanceCap: 0.80,
  marginThreshold: 0.15,
);

void main() {
  test('a held-out fire rep classifies as fire', () {
    final match = _classifier.classify(_fireRep(seed: 500), _templates());
    expect(match.gesture, Gesture.fire);
    expect(match.stillnessGated, isFalse);
  });

  test('a held-out water rep classifies as water', () {
    final match = _classifier.classify(_waterRep(seed: 501), _templates());
    expect(match.gesture, Gesture.water);
  });

  test('a held-out melee rep classifies as melee', () {
    final match = _classifier.classify(_meleeRep(seed: 502), _templates());
    expect(match.gesture, Gesture.melee);
  });

  test('holding still is stillness-gated to neutral without running DTW', () {
    final match = _classifier.classify(_still(60), _templates());
    expect(match.gesture, Gesture.neutral);
    expect(match.stillnessGated, isTrue);
    expect(match.distances, isEmpty);
  });

  test('an empty capture is stillness-gated to neutral', () {
    final match = _classifier.classify(const [], _templates());
    expect(match.gesture, Gesture.neutral);
    expect(match.stillnessGated, isTrue);
  });

  test('garbage/theatrical motion resolves to neutral, not a false accept', () {
    final match = _classifier.classify(_garbage(60), _templates());
    expect(match.gesture, Gesture.neutral);
  });

  test('an unenrolled gesture is never a candidate, even when performed', () {
    // "earth" has zero reps in _templates(); a fire-shaped query must never
    // resolve to earth regardless of how close it might theoretically be —
    // absence of a template is the safe default, not a wildcard match.
    final match = _classifier.classify(_fireRep(seed: 503), _templates());
    expect(match.gesture, isNot(Gesture.earth));
    expect(match.distances.containsKey(Gesture.earth), isFalse);
  });

  test('classify never selects a gesture with an empty rep list at all', () {
    final onlyFire = {Gesture.fire: _templates()[Gesture.fire]!};
    final match = _classifier.classify(_waterRep(seed: 504), onlyFire);
    // Only fire is a candidate; either it accepts fire (single-candidate,
    // cap-gated only) or rejects to neutral — it must never fabricate water.
    expect(match.gesture, anyOf(Gesture.fire, Gesture.neutral));
  });

  test('an ambiguous query exactly between two templates rejects to neutral', () {
    // Blend fire and water frame-by-frame (same length) — equidistant from
    // both, so the contrastive margin must reject it.
    final fire = _fireRep(seed: 600);
    final water = _waterRep(seed: 601);
    final n = math.min(fire.length, water.length);
    final blended = List.generate(n, (i) {
      final f = fire[i], w = water[i];
      return ImuSample(
        tMs: f.tMs,
        ax: (f.ax + w.ax) / 2, ay: (f.ay + w.ay) / 2, az: (f.az + w.az) / 2,
        gx: (f.gx + w.gx) / 2, gy: (f.gy + w.gy) / 2, gz: (f.gz + w.gz) / 2,
      );
    });
    final match = _classifier.classify(blended, _templates());
    expect(match.gesture, Gesture.neutral);
  });
}
