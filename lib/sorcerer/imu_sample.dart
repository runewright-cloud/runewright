// SPDX-License-Identifier: GPL-3.0-or-later
//
// imu_sample.dart — ImuSample and the pure-computation helpers built on it
// (feature-frame conversion, windowed energy for the stillness gate).
//
// Mirrors mfcc.dart's split: this file is pure math, no I/O, no
// sensors_plus import. gesture_capture.dart is the only file that talks to
// the sensor package and produces List<ImuSample>; everything downstream
// (GestureClassifier, GestureEnrollment) consumes only this type.

import 'dart:math' as math;

/// One IMU reading: linear acceleration with gravity removed (ax/ay/az) and
/// angular velocity (gx/gy/gz), at [tMs] milliseconds since capture start.
class ImuSample {
  const ImuSample({
    required this.tMs,
    required this.ax,
    required this.ay,
    required this.az,
    required this.gx,
    required this.gy,
    required this.gz,
  });

  final int tMs;
  final double ax, ay, az;
  final double gx, gy, gz;

  List<double> toFrame() => [ax, ay, az, gx, gy, gz];

  Map<String, dynamic> toJson() => {
        't': tMs,
        'ax': ax, 'ay': ay, 'az': az,
        'gx': gx, 'gy': gy, 'gz': gz,
      };

  static ImuSample fromJson(Map<String, dynamic> json) => ImuSample(
        tMs: json['t'] as int,
        ax: (json['ax'] as num).toDouble(),
        ay: (json['ay'] as num).toDouble(),
        az: (json['az'] as num).toDouble(),
        gx: (json['gx'] as num).toDouble(),
        gy: (json['gy'] as num).toDouble(),
        gz: (json['gz'] as num).toDouble(),
      );
}

/// Converts a raw capture to the 6-component feature-frame sequence
/// [DtwMatcher.distance] (mfcc.dart) matches on. v1 is time-domain only —
/// no resampling, since DTW is already time-warp invariant; a fixed-rate
/// resample can be added later if frequency features are ever needed
/// (SOMATIC_GESTURE_PLAN.md §4).
List<List<double>> imuFeatureFrames(List<ImuSample> samples) =>
    samples.map((s) => s.toFrame()).toList();

/// Mean-square energy over [samples] (acceleration + gyro combined) — the
/// scalar the stillness gate thresholds against. Holding steady (gravity
/// already removed by the sensor) sits near sensor-noise floor; a real
/// gesture is a "bounded oscillation" with much higher energy. See
/// GestureClassifier.energyFloor and SOMATIC_GESTURE_PLAN.md §6.1.
///
/// Returns 0.0 for an empty capture.
double windowEnergy(List<ImuSample> samples) {
  if (samples.isEmpty) return 0.0;
  var sumSq = 0.0;
  for (final s in samples) {
    sumSq += s.ax * s.ax + s.ay * s.ay + s.az * s.az +
        s.gx * s.gx + s.gy * s.gy + s.gz * s.gz;
  }
  return sumSq / samples.length;
}

/// Sample rate implied by [samples]' timestamps, in Hz. Used to record the
/// device's actual steady IMU rate into enrollment fixtures rather than
/// assuming one (SOMATIC_GESTURE_PLAN.md §12 — resample rate is a
/// `[DECISION — needs Soren]` to be made from real data, not invented).
/// Returns 0.0 for fewer than 2 samples.
double impliedSampleRateHz(List<ImuSample> samples) {
  if (samples.length < 2) return 0.0;
  final spanMs = samples.last.tMs - samples.first.tMs;
  if (spanMs <= 0) return 0.0;
  return (samples.length - 1) * 1000.0 / spanMs;
}

/// √(mean-square) convenience over [imuFeatureFrames] distances — not used
/// by the gate itself (which thresholds mean-square directly) but handy for
/// debug readouts in physically interpretable units.
double windowRms(List<ImuSample> samples) => math.sqrt(windowEnergy(samples));
