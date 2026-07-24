// SPDX-License-Identifier: GPL-3.0-or-later
//
// gesture_capture.dart — GestureCapture: the only file in the gesture
// pipeline that imports sensors_plus. Buffers raw IMU samples for one
// hold-to-record window and hands back a List<ImuSample>; all downstream
// processing (GestureClassifier, GestureEnrollment) is pure Dart over that
// type. Mirrors VocalScorer's split between mic I/O and MFCC/DTW math.
//
// Streams userAccelerometerEventStream (gravity already removed by the
// platform) + gyroscopeEventStream, merged by wall-clock offset from
// beginCapture(). Both streams are independently timed by the OS, so
// samples are NOT synchronized frame-for-frame — each stream is buffered
// into its own list and the two are merged by nearest-timestamp when
// endCapture() is called, matching the coarser of the two rates.

import 'dart:async';

import 'package:sensors_plus/sensors_plus.dart';

import 'imu_sample.dart';

/// One hold-to-record capture session's raw sensor readings.
class _RawReading {
  const _RawReading(this.tMs, this.x, this.y, this.z);
  final int tMs;
  final double x, y, z;
}

/// Interface for somatic-gesture sensor capture. Implementations must not
/// be imported by battle-layer code directly — go through the classifier
/// seam once it's wired (SOMATIC_GESTURE_PLAN.md §10).
abstract class GestureCapture {
  /// Opens the accelerometer + gyroscope streams and begins buffering.
  /// Must not be called while a capture is already in progress.
  void beginCapture();

  /// Stops the streams and returns the merged, timestamp-sorted samples
  /// collected since [beginCapture].
  List<ImuSample> endCapture();

  /// Releases sensor subscriptions. Do not call during an active capture.
  void dispose();
}

class SensorsGestureCapture implements GestureCapture {
  StreamSubscription<UserAccelerometerEvent>? _accelSub;
  StreamSubscription<GyroscopeEvent>? _gyroSub;
  final List<_RawReading> _accel = [];
  final List<_RawReading> _gyro = [];
  int? _startMs;

  static const _samplingPeriod = Duration(milliseconds: 10); // ~100 Hz target

  @override
  void beginCapture() {
    _accel.clear();
    _gyro.clear();
    _startMs = DateTime.now().millisecondsSinceEpoch;
    _accelSub = userAccelerometerEventStream(
      samplingPeriod: _samplingPeriod,
    ).listen((e) => _accel.add(_RawReading(_elapsedMs(), e.x, e.y, e.z)));
    _gyroSub = gyroscopeEventStream(
      samplingPeriod: _samplingPeriod,
    ).listen((e) => _gyro.add(_RawReading(_elapsedMs(), e.x, e.y, e.z)));
  }

  int _elapsedMs() =>
      DateTime.now().millisecondsSinceEpoch - (_startMs ?? 0);

  @override
  List<ImuSample> endCapture() {
    unawaited(_accelSub?.cancel());
    unawaited(_gyroSub?.cancel());
    _accelSub = null;
    _gyroSub = null;

    // Merge by nearest gyro reading to each accel timestamp (accel and
    // gyro are independently timed streams). Falls back to zeros for the
    // missing side when one stream produced nothing, rather than dropping
    // the capture — a partial reading is still useful signal.
    final samples = <ImuSample>[];
    var gyroIdx = 0;
    for (final a in _accel) {
      while (gyroIdx + 1 < _gyro.length &&
          (_gyro[gyroIdx + 1].tMs - a.tMs).abs() <=
              (_gyro[gyroIdx].tMs - a.tMs).abs()) {
        gyroIdx++;
      }
      final g = _gyro.isEmpty ? null : _gyro[gyroIdx];
      samples.add(ImuSample(
        tMs: a.tMs,
        ax: a.x, ay: a.y, az: a.z,
        gx: g?.x ?? 0.0, gy: g?.y ?? 0.0, gz: g?.z ?? 0.0,
      ));
    }
    _accel.clear();
    _gyro.clear();
    return samples;
  }

  @override
  void dispose() {
    unawaited(_accelSub?.cancel());
    unawaited(_gyroSub?.cancel());
    _accelSub = null;
    _gyroSub = null;
  }
}
