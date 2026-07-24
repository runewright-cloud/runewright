// SPDX-License-Identifier: GPL-3.0-or-later
//
// imu_sample_test.dart — ImuSample and the pure helpers built on it:
// windowEnergy (stillness gate), imuFeatureFrames (DTW input shape),
// impliedSampleRateHz (recorded, not assumed).

import 'package:test/test.dart';
import 'package:rune_duel/sorcerer/imu_sample.dart';

List<ImuSample> _stillSamples(int n, {double noise = 0.001}) => List.generate(
      n,
      (i) => ImuSample(
        tMs: i * 10,
        ax: noise, ay: -noise, az: noise * 0.5,
        gx: noise, gy: noise, gz: -noise,
      ),
    );

List<ImuSample> _movingSamples(int n, {double amplitude = 3.0}) => List.generate(
      n,
      (i) => ImuSample(
        tMs: i * 10,
        ax: amplitude, ay: amplitude * 0.5, az: 0.0,
        gx: amplitude * 0.3, gy: 0.0, gz: 0.0,
      ),
    );

void main() {
  test('windowEnergy is near zero for a still capture', () {
    expect(windowEnergy(_stillSamples(50)), lessThan(0.001));
  });

  test('windowEnergy is much larger for a moving capture', () {
    final still = windowEnergy(_stillSamples(50));
    final moving = windowEnergy(_movingSamples(50));
    expect(moving, greaterThan(still * 100));
  });

  test('windowEnergy of an empty capture is 0.0', () {
    expect(windowEnergy(const []), 0.0);
  });

  test('imuFeatureFrames preserves order and the 6-component shape', () {
    final samples = _movingSamples(5);
    final frames = imuFeatureFrames(samples);
    expect(frames.length, 5);
    for (final frame in frames) {
      expect(frame.length, 6);
    }
    expect(frames.first, samples.first.toFrame());
  });

  test('impliedSampleRateHz reads the actual capture rate, not an assumed one', () {
    // 10ms spacing => 100 Hz.
    final samples = _movingSamples(11); // spans 100ms over 10 intervals
    expect(impliedSampleRateHz(samples), closeTo(100.0, 0.5));
  });

  test('impliedSampleRateHz is 0.0 for fewer than 2 samples', () {
    expect(impliedSampleRateHz(const []), 0.0);
    expect(impliedSampleRateHz(_movingSamples(1)), 0.0);
  });

  test('ImuSample json roundtrip', () {
    const sample = ImuSample(tMs: 42, ax: 1, ay: 2, az: 3, gx: 4, gy: 5, gz: 6);
    final decoded = ImuSample.fromJson(sample.toJson());
    expect(decoded.tMs, sample.tMs);
    expect(decoded.toFrame(), sample.toFrame());
  });
}
