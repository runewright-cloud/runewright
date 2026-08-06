// SPDX-License-Identifier: GPL-3.0-or-later
//
// cast_motion_gate_test.dart — castMotionSatisfied, the free-style motion
// gate (docs/SPELL_COMPONENTS_PLAN.md §4.1).
//
// The gate exists to ask a question the classifier's own stillness floor does
// NOT ask: were you moving THROUGHOUT the hold, or did you twitch once and
// coast? A single flourish inside an otherwise motionless hold clears
// windowEnergy over the whole capture — that is the case these tests are for.
//
// Failing the gate costs the caster their enhancement and nothing else, so the
// bias is deliberately toward accepting an honest performance: the tests below
// pin that direction, not a tight threshold.

import 'package:test/test.dart';
import 'package:rune_duel/sorcerer/gesture_classifier.dart';
import 'package:rune_duel/sorcerer/imu_sample.dart';

/// Well above the shipped energy floor (8.0 mean-square).
const _moving = 4.0;

/// Below it — sensor noise and hand tremor.
const _still = 0.05;

List<ImuSample> _samples(List<double> amplitudePerSample) => [
      for (var i = 0; i < amplitudePerSample.length; i++)
        ImuSample(
          tMs: i * 18, // ~55 Hz, the rate a Pixel 6 actually reports
          ax: amplitudePerSample[i],
          ay: amplitudePerSample[i],
          az: amplitudePerSample[i],
          gx: amplitudePerSample[i],
          gy: amplitudePerSample[i],
          gz: amplitudePerSample[i],
        ),
    ];

/// A hold of [n] samples where the fraction [movingFrom]..[movingTo] of the
/// capture is in motion and the rest is still.
List<ImuSample> _hold(int n, {double movingFrom = 0.0, double movingTo = 1.0}) =>
    _samples([
      for (var i = 0; i < n; i++)
        (i >= n * movingFrom && i < n * movingTo) ? _moving : _still,
    ]);

void main() {
  test('sustained motion across the whole hold passes', () {
    expect(castMotionSatisfied(_hold(120)), isTrue);
  });

  test('a motionless hold fails', () {
    expect(castMotionSatisfied(_hold(120, movingTo: 0.0)), isFalse);
  });

  test('one flourish in an otherwise still hold fails', () {
    // THE case the gate exists for. This capture's overall windowEnergy is
    // well clear of the stillness floor — a whole quarter of it is genuine
    // motion — so the classifier's own gate would wave it through.
    final oneBurst = _hold(120, movingFrom: 0.0, movingTo: 0.25);
    expect(
      windowEnergy(oneBurst),
      greaterThan(const GestureClassifier().energyFloor),
      reason: 'fixture must actually clear the stillness floor, or this '
          'test is not testing the coverage rule',
    );
    expect(castMotionSatisfied(oneBurst), isFalse);
  });

  test('settling still for the final quarter still passes', () {
    // Deliberate tolerance: landing on the closing gesture, or a brief
    // fumble, must not void a committed performance.
    expect(castMotionSatisfied(_hold(120, movingTo: 0.75)), isTrue);
  });

  test('going still for half the hold fails', () {
    expect(castMotionSatisfied(_hold(120, movingTo: 0.5)), isFalse);
  });

  test('a capture too short to judge fails', () {
    expect(castMotionSatisfied(_hold(kMinCastMotionSamples - 1)), isFalse);
    expect(castMotionSatisfied(const []), isFalse);
  });

  test('a hold at exactly the minimum length is judged, not rejected', () {
    expect(castMotionSatisfied(_hold(kMinCastMotionSamples)), isTrue);
  });

  test('every sample is judged — trailing stillness is not dropped', () {
    // The last window takes the remainder, so a hold whose length does not
    // divide evenly cannot hide its tail. 122 % 4 == 2.
    expect(castMotionSatisfied(_hold(122, movingTo: 0.5)), isFalse);
  });

  test('the floor comes from the classifier, not a second constant', () {
    // §6.5 forbids invented constants; the gate borrows the one measured
    // number. Raising the classifier's floor must therefore tighten the gate.
    final gentle = _samples(List.filled(120, 1.5)); // energy 13.5
    expect(castMotionSatisfied(gentle), isTrue);
    expect(
      castMotionSatisfied(
        gentle,
        classifier: const GestureClassifier(energyFloor: 100.0),
      ),
      isFalse,
    );
  });
}
