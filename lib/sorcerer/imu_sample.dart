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

/// Moving-average window (in frames) applied before matching. At the Pixel
/// 6's measured ~55 Hz this is ~90 ms — long enough to kill per-frame IMU
/// jitter that DTW would otherwise pay full Euclidean cost for, short enough
/// to preserve the shape of a ~1.5 s gesture.
const int kMatchingSmoothWindow = 5;

/// Gyro channels are multiplied by this before normalisation.
///
/// Measured on the real corpus: this device's gyro magnitudes run ~1/4 of
/// its accelerometer magnitudes (accel RMS ~10-25 m/s² vs gyro ~2-5 rad/s).
/// Without rebalancing, a single global normalisation lets the accelerometer
/// dominate the DTW cost and drowns out the rotation signature — which is
/// most of what actually separates the gestures. Sweeping this factor over
/// the corpus moved held-out false accepts from 2 to 0.
const double kGyroBalance = 4.0;

/// Prepares raw feature frames for DTW matching: smooth, rebalance the gyro
/// block against the accel block, then scale the whole rep to unit RMS.
///
/// The unit-RMS step is what makes matching amplitude-invariant, and it is
/// load-bearing rather than cosmetic. On raw frames DTW distance is
/// dominated by sheer magnitude, and because fire is the *quietest* gesture
/// (mean-square energy ~25, vs air ~390 and melee ~1100), near-zero motion
/// lands closer to a fire template than to anything else: on the real corpus
/// 19 of 20 idle/walk captures classified as fire. Normalising removes the
/// amplitude axis entirely and hands the decision to shape, where the
/// gestures genuinely differ.
///
/// Applied to BOTH the query and every template rep, so stored enrollment
/// JSON stays raw and reprocessable as calibration evolves.
List<List<double>> normalizeForMatching(List<List<double>> frames) {
  if (frames.isEmpty) return frames;

  final w = kMatchingSmoothWindow;
  final c = frames.first.length;
  final smoothed = <List<double>>[];
  for (var i = 0; i < frames.length; i++) {
    final lo = math.max(0, i - w ~/ 2);
    final hi = math.min(frames.length - 1, i + w ~/ 2);
    final acc = List<double>.filled(c, 0.0);
    for (var j = lo; j <= hi; j++) {
      for (var k = 0; k < c; k++) {
        acc[k] += frames[j][k];
      }
    }
    final n = (hi - lo + 1).toDouble();
    smoothed.add([
      for (var k = 0; k < c; k++)
        acc[k] / n * (k >= 3 ? kGyroBalance : 1.0),
    ]);
  }

  var sumSq = 0.0;
  var count = 0;
  for (final row in smoothed) {
    for (final v in row) {
      sumSq += v * v;
      count++;
    }
  }
  final rms = count == 0 ? 0.0 : math.sqrt(sumSq / count);
  if (rms < 1e-9) return smoothed;
  return smoothed.map((row) => row.map((v) => v / rms).toList()).toList();
}

/// Reflects [frames] across the performer's sagittal plane — the exact
/// transform between a right-handed performance and its left-handed mirror,
/// assuming the phone is held in the same orientation relative to the body
/// so device +x runs along the user's left-right axis.
///
/// Linear acceleration is a true vector, so only the mirrored axis flips.
/// Angular velocity is a PSEUDOvector: under a reflection it picks up an
/// extra sign change, so the OTHER two components flip instead. Getting this
/// backwards yields a physically impossible motion that still looks
/// plausible on a plot — it is the classic IMU-mirroring bug.
///
/// This is an orthogonal transform, so it preserves Euclidean distance
/// exactly and therefore commutes with [normalizeForMatching] and DTW: a
/// mirrored template set reproduces the original's accuracy bit for bit,
/// with no recapture and no recalibration. Used to cover both handedness
/// from a single captured corpus.
List<List<double>> mirrorFrames(List<List<double>> frames) => frames
    .map((row) => [-row[0], row[1], row[2], row[3], -row[4], -row[5]])
    .toList();

/// [mirrorFrames] at the raw-sample level, preserving timestamps.
List<ImuSample> mirrorSamples(List<ImuSample> samples) => samples
    .map((s) => ImuSample(
          tMs: s.tMs,
          ax: -s.ax, ay: s.ay, az: s.az,
          gx: s.gx, gy: -s.gy, gz: -s.gz,
        ))
    .toList();

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
