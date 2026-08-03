// SPDX-License-Identifier: GPL-3.0-or-later
//
// gesture_corpus_analysis.dart — offline calibration harness for the somatic
// gesture corpus pulled off a real device. NOT a test; a bench tool.
//
// Usage: dart run tool/gesture_corpus_analysis.dart <corpus_dir>
// where <corpus_dir> holds the app_flutter/gesture_enrollment/*.json files.
//
// Answers three questions the synthetic confusion-matrix test cannot:
//   1. What scale are real DTW distances actually on? (vs distanceCap)
//   2. Which feature representation separates the five gestures?
//   3. For each representation, what is the best zero-false-accept operating
//      point (SOMATIC_GESTURE_PLAN.md §9 gate) and its true-accept rate?

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:rune_duel/sorcerer/mfcc.dart' show DtwMatcher;

const gestureNames = ['fire', 'air', 'water', 'earth', 'melee'];
const confusableNames = [
  'confusable_idle',
  'confusable_walk',
  'confusable_garbage'
];

class Rep {
  Rep(this.label, this.index, this.rateHz, this.frames);
  final String label;
  final int index;
  final double rateHz;
  final List<List<double>> frames;
  bool get isGesture => gestureNames.contains(label);
  String get id => '$label[$index]';
}

List<Rep> loadCorpus(String dir) {
  final reps = <Rep>[];
  for (final name in [...gestureNames, ...confusableNames]) {
    final f = File('$dir/$name.json');
    if (!f.existsSync()) continue;
    final json = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    final list = json['reps'] as List;
    for (var i = 0; i < list.length; i++) {
      final r = list[i] as Map<String, dynamic>;
      reps.add(Rep(
        name,
        i,
        (r['rateHz'] as num).toDouble(),
        (r['frames'] as List)
            .map((row) =>
                (row as List).map((v) => (v as num).toDouble()).toList())
            .toList(),
      ));
    }
  }
  return reps;
}

// ── feature transforms ──────────────────────────────────────────────────────

typedef Transform = List<List<double>> Function(Rep rep);

double _rms(List<List<double>> f) {
  var s = 0.0;
  var n = 0;
  for (final row in f) {
    for (final v in row) {
      s += v * v;
      n++;
    }
  }
  return n == 0 ? 0.0 : math.sqrt(s / n);
}

double _meanSquareEnergy(List<List<double>> f) {
  if (f.isEmpty) return 0.0;
  var s = 0.0;
  for (final row in f) {
    for (final v in row) {
      s += v * v;
    }
  }
  return s / f.length;
}

List<List<double>> _map(List<List<double>> f, List<double> Function(List<double>) fn) =>
    f.map(fn).toList();

List<List<double>> _scaleChannels(List<List<double>> f, List<double> k) =>
    _map(f, (row) => [for (var i = 0; i < row.length; i++) row[i] * k[i]]);

/// Divide the whole rep by its global RMS: removes overall amplitude, keeps
/// inter-channel ratios and temporal shape.
List<List<double>> _unitRms(List<List<double>> f) {
  final r = _rms(f);
  if (r < 1e-9) return f;
  return _map(f, (row) => row.map((v) => v / r).toList());
}

/// Normalise the accelerometer block and the gyroscope block to unit RMS
/// independently, so each contributes equally to the DTW Euclidean cost
/// regardless of the device's native unit scales (m/s² vs rad/s).
List<List<double>> _blockNorm(List<List<double>> f) {
  if (f.isEmpty) return f;
  var sa = 0.0, sg = 0.0;
  for (final row in f) {
    sa += row[0] * row[0] + row[1] * row[1] + row[2] * row[2];
    sg += row[3] * row[3] + row[4] * row[4] + row[5] * row[5];
  }
  final ra = math.sqrt(sa / (3 * f.length));
  final rg = math.sqrt(sg / (3 * f.length));
  final ka = ra < 1e-9 ? 0.0 : 1.0 / ra;
  final kg = rg < 1e-9 ? 0.0 : 1.0 / rg;
  return _map(f, (row) => [
        row[0] * ka, row[1] * ka, row[2] * ka,
        row[3] * kg, row[4] * kg, row[5] * kg,
      ]);
}

/// Reflect a capture across the performer's sagittal plane — the exact
/// transform between a right-handed performance and its left-handed mirror,
/// assuming the phone is held in the same orientation relative to the body
/// (screen toward the user, top up), so device +x runs along the user's
/// left-right axis.
///
/// Linear acceleration is a true vector: only the mirrored axis flips.
/// Angular velocity is a PSEUDOvector: under a reflection it picks up an
/// extra sign, so the OTHER two components flip instead. Getting this
/// backwards is the classic IMU-mirroring bug — it yields a physically
/// impossible motion that still looks plausible in a plot.
List<List<double>> _mirror(List<List<double>> f) => _map(
    f, (row) => [-row[0], row[1], row[2], row[3], -row[4], -row[5]]);

/// Scale every channel independently to unit RMS — for feature sets whose
/// channels have unrelated natural scales (e.g. the rotation-invariant set,
/// where |a×g| is a product of two quantities and dwarfs |a|).
List<List<double>> _normalizeEachChannel(List<List<double>> f) {
  if (f.isEmpty) return f;
  final c = f.first.length;
  final k = List<double>.filled(c, 0.0);
  for (final row in f) {
    for (var i = 0; i < c; i++) {
      k[i] += row[i] * row[i];
    }
  }
  for (var i = 0; i < c; i++) {
    final r = math.sqrt(k[i] / f.length);
    k[i] = r < 1e-9 ? 0.0 : 1.0 / r;
  }
  return _map(f, (row) => [for (var i = 0; i < c; i++) row[i] * k[i]]);
}

/// Short-time band energies — the phase-invariant representation.
///
/// A tremor ("hold still and shake") has no repeatable trajectory: successive
/// shake cycles have arbitrary phase, so time-aligned DTW over raw samples
/// pays a large cost for a *correct* performance. Its identity lives in the
/// frequency content, not the path.
///
/// This is exactly the problem MFCC solves for speech — a spoken word is not
/// a repeatable waveform either, but its short-time spectral envelope is
/// stable. Same treatment: slice into overlapping windows, take the band
/// energies within each, log-compress. The result is still a *sequence*, so
/// DTW still applies and trajectory gestures are unharmed — but now a shake
/// matches a shake regardless of phase.
///
/// [win]/[hop] in frames; at the corpus's ~55 Hz, win=24 is ~436 ms and
/// hop=8 is ~145 ms, giving Nyquist 27.5 Hz — comfortably above hand tremor.
List<List<double>> _bandEnergyFrames(
  List<List<double>> frames, {
  int win = 24,
  int hop = 8,
  int bands = 5,
  bool magnitudeOnly = true,
}) {
  if (frames.length < win) return const [];

  // Channels to analyse: either |accel| and |gyro| (rotation-invariant, 2
  // signals) or all six raw axes.
  final signals = <List<double>>[];
  if (magnitudeOnly) {
    signals.add([
      for (final r in frames)
        math.sqrt(r[0] * r[0] + r[1] * r[1] + r[2] * r[2])
    ]);
    signals.add([
      for (final r in frames)
        math.sqrt(r[3] * r[3] + r[4] * r[4] + r[5] * r[5])
    ]);
  } else {
    for (var c = 0; c < 6; c++) {
      signals.add([for (final r in frames) r[c]]);
    }
  }

  final out = <List<double>>[];
  for (var start = 0; start + win <= frames.length; start += hop) {
    final feat = <double>[];
    for (final sig in signals) {
      // Hann-windowed magnitude DFT. Windows are tiny (24), so a naive DFT
      // costs ~576 multiply-adds — no FFT machinery warranted.
      final mags = List<double>.filled(win ~/ 2, 0.0);
      var mean = 0.0;
      for (var i = 0; i < win; i++) {
        mean += sig[start + i];
      }
      mean /= win;
      for (var k = 1; k <= win ~/ 2; k++) {
        var re = 0.0, im = 0.0;
        for (var i = 0; i < win; i++) {
          final w = 0.5 - 0.5 * math.cos(2 * math.pi * i / (win - 1));
          final v = (sig[start + i] - mean) * w;
          final ang = -2 * math.pi * k * i / win;
          re += v * math.cos(ang);
          im += v * math.sin(ang);
        }
        mags[k - 1] = math.sqrt(re * re + im * im);
      }
      // Aggregate the bins into [bands] contiguous bands, log-compressed.
      final perBand = (mags.length / bands).ceil();
      for (var b = 0; b < bands; b++) {
        var acc = 0.0;
        for (var i = b * perBand; i < (b + 1) * perBand && i < mags.length; i++) {
          acc += mags[i] * mags[i];
        }
        feat.add(math.log(acc + 1e-6));
      }
    }
    out.add(feat);
  }
  return out;
}

/// One sequence carrying BOTH properties: the unit-RMS trajectory frames a
/// path gesture needs, concatenated with per-frame band energies a tremor
/// needs, the latter weighted by [w].
///
/// Band energies are computed at hop=1 so they align frame-for-frame with the
/// trajectory, and the leading (win-1) frames reuse the first full window
/// rather than being dropped — losing the head of the capture would shift
/// every gesture's onset.
List<List<double>> _trajPlusSpectral(List<List<double>> frames, double w) {
  final traj = _unitRms(_smooth(frames, 5));
  final spec = _normalizeEachChannel(
      _bandEnergyFrames(frames, win: 24, hop: 1, bands: 5));
  if (spec.isEmpty || traj.isEmpty) return traj;

  final out = <List<double>>[];
  for (var i = 0; i < traj.length; i++) {
    final si = (i - 23).clamp(0, spec.length - 1);
    out.add([...traj[i], ...spec[si].map((v) => v * w)]);
  }
  return out;
}

/// Per-channel z-score across the rep: removes amplitude AND per-channel
/// scale, keeping only correlated temporal shape.
List<List<double>> _zscore(List<List<double>> f) {
  if (f.isEmpty) return f;
  final c = f.first.length;
  final mean = List<double>.filled(c, 0.0);
  for (final row in f) {
    for (var i = 0; i < c; i++) {
      mean[i] += row[i];
    }
  }
  for (var i = 0; i < c; i++) {
    mean[i] /= f.length;
  }
  final sd = List<double>.filled(c, 0.0);
  for (final row in f) {
    for (var i = 0; i < c; i++) {
      sd[i] += (row[i] - mean[i]) * (row[i] - mean[i]);
    }
  }
  for (var i = 0; i < c; i++) {
    sd[i] = math.sqrt(sd[i] / f.length);
    if (sd[i] < 1e-9) sd[i] = 1.0;
  }
  return _map(f, (row) => [for (var i = 0; i < c; i++) (row[i] - mean[i]) / sd[i]]);
}

/// Zero-phase-ish moving average over [w] frames — kills IMU jitter that DTW
/// otherwise pays full Euclidean cost for.
List<List<double>> _smooth(List<List<double>> f, int w) {
  if (f.isEmpty || w <= 1) return f;
  final c = f.first.length;
  final out = <List<double>>[];
  for (var i = 0; i < f.length; i++) {
    final lo = math.max(0, i - w ~/ 2);
    final hi = math.min(f.length - 1, i + w ~/ 2);
    final acc = List<double>.filled(c, 0.0);
    for (var j = lo; j <= hi; j++) {
      for (var k = 0; k < c; k++) {
        acc[k] += f[j][k];
      }
    }
    final n = (hi - lo + 1).toDouble();
    out.add([for (var k = 0; k < c; k++) acc[k] / n]);
  }
  return out;
}

/// Linear resample to a fixed frame count — makes every rep the same length so
/// DTW's (n+m) normalisation stops interacting with gesture duration.
List<List<double>> _resample(List<List<double>> f, int n) {
  if (f.isEmpty) return f;
  if (f.length == n) return f;
  final c = f.first.length;
  final out = <List<double>>[];
  for (var i = 0; i < n; i++) {
    final pos = i * (f.length - 1) / (n - 1);
    final lo = pos.floor().clamp(0, f.length - 1);
    final hi = pos.ceil().clamp(0, f.length - 1);
    final t = pos - lo;
    out.add([for (var k = 0; k < c; k++) f[lo][k] * (1 - t) + f[hi][k] * t]);
  }
  return out;
}

/// Rotation-invariant magnitudes: [|accel|, |gyro|]. Immune to how the phone
/// is held.
List<List<double>> _magnitudes(List<List<double>> f) => _map(f, (row) {
      final a = math.sqrt(row[0] * row[0] + row[1] * row[1] + row[2] * row[2]);
      final g = math.sqrt(row[3] * row[3] + row[4] * row[4] + row[5] * row[5]);
      return [a, g];
    });

/// Rotation-invariant IMU features: scalars that do not change when the
/// phone is rotated in the hand. This is the representation universality
/// would need — different people hold the phone at different angles, which
/// is a rigid rotation of the whole device frame, and device-frame features
/// (ax..gz) change completely under it while these do not.
///
/// |a|, |g| are magnitudes; a·g and |a×g| capture the *relative geometry* of
/// the linear and angular motion (is the rotation aligned with the push, or
/// perpendicular to it?), which is what distinguishes e.g. a thrust from a
/// twist without reference to any external axis.
List<List<double>> _rotationInvariant(List<List<double>> f) => _map(f, (row) {
      final ax = row[0], ay = row[1], az = row[2];
      final gx = row[3], gy = row[4], gz = row[5];
      final na = math.sqrt(ax * ax + ay * ay + az * az);
      final ng = math.sqrt(gx * gx + gy * gy + gz * gz);
      final dot = ax * gx + ay * gy + az * gz;
      final cx = ay * gz - az * gy;
      final cy = az * gx - ax * gz;
      final cz = ax * gy - ay * gx;
      final cross = math.sqrt(cx * cx + cy * cy + cz * cz);
      return [na, ng, dot, cross];
    });

/// Appends log-amplitude as an extra constant channel weighted by [w] — an
/// explicit amplitude prior on top of a shape-normalised representation.
List<List<double>> _appendLogAmp(List<List<double>> shape, double rawRms, double w) {
  final v = math.log(rawRms + 1e-6) * w;
  return _map(shape, (row) => [...row, v]);
}

final transforms = <String, Transform>{
  'raw (production today)': (r) => r.frames,
  'smooth5': (r) => _smooth(r.frames, 5),
  'unitRms': (r) => _unitRms(r.frames),
  'smooth5+unitRms': (r) => _unitRms(_smooth(r.frames, 5)),
  'zscore': (r) => _zscore(r.frames),
  'smooth5+zscore': (r) => _zscore(_smooth(r.frames, 5)),
  'gyroX2+unitRms': (r) =>
      _unitRms(_scaleChannels(_smooth(r.frames, 5), [1, 1, 1, 2, 2, 2])),
  'gyroX3+unitRms': (r) =>
      _unitRms(_scaleChannels(_smooth(r.frames, 5), [1, 1, 1, 3, 3, 3])),
  'gyroX4+unitRms': (r) =>
      _unitRms(_scaleChannels(_smooth(r.frames, 5), [1, 1, 1, 4, 4, 4])),
  'gyroX6+unitRms': (r) =>
      _unitRms(_scaleChannels(_smooth(r.frames, 5), [1, 1, 1, 6, 6, 6])),
  // Normalise the accel block and the gyro block to unit RMS *separately*.
  // Same intent as the gyroXN fudge factors but with no magic constant: on
  // this device gyro magnitudes run ~1/4 of accel, so after a single global
  // unitRms the accel channels dominate the Euclidean cost and the gyro's
  // rotation signature — the thing that actually distinguishes the
  // gestures — is drowned out.
  'traj+spec(w=0.5)': (r) => _trajPlusSpectral(r.frames, 0.5),
  'traj+spec(w=1.0)': (r) => _trajPlusSpectral(r.frames, 1.0),
  'traj+spec(w=2.0)': (r) => _trajPlusSpectral(r.frames, 2.0),
  'spec2 (|a|,|g| bands)': (r) => _bandEnergyFrames(r.frames),
  'spec2+normCh': (r) => _normalizeEachChannel(_bandEnergyFrames(r.frames)),
  'spec6 (all axes)': (r) =>
      _bandEnergyFrames(r.frames, magnitudeOnly: false, bands: 4),
  'spec6+normCh': (r) => _normalizeEachChannel(
      _bandEnergyFrames(r.frames, magnitudeOnly: false, bands: 4)),
  'spec2 fine (win16 hop6)': (r) =>
      _normalizeEachChannel(_bandEnergyFrames(r.frames, win: 16, hop: 6, bands: 4)),
  'rotInv': (r) => _rotationInvariant(_smooth(r.frames, 5)),
  'rotInv+unitRms': (r) => _unitRms(_rotationInvariant(_smooth(r.frames, 5))),
  'rotInv+blockNorm4': (r) => _normalizeEachChannel(
      _rotationInvariant(_smooth(r.frames, 5))),
  'blockNorm': (r) => _blockNorm(r.frames),
  'smooth5+blockNorm': (r) => _blockNorm(_smooth(r.frames, 5)),
  'smooth5+blockNorm+logAmp(w=2)': (r) =>
      _appendLogAmp(_blockNorm(_smooth(r.frames, 5)), _rms(r.frames), 2.0),
  'accelOnly+unitRms': (r) =>
      _unitRms(_scaleChannels(_smooth(r.frames, 5), [1, 1, 1, 0, 0, 0])),
  'gyroOnly+unitRms': (r) =>
      _unitRms(_scaleChannels(_smooth(r.frames, 5), [0, 0, 0, 1, 1, 1])),
  'magnitudes': (r) => _magnitudes(_smooth(r.frames, 5)),
  'magnitudes+unitRms': (r) => _unitRms(_magnitudes(_smooth(r.frames, 5))),
  'resample64+unitRms': (r) => _unitRms(_resample(_smooth(r.frames, 5), 64)),
  'resample64+zscore': (r) => _zscore(_resample(_smooth(r.frames, 5), 64)),
  'unitRms+logAmp(w=1)': (r) =>
      _appendLogAmp(_unitRms(_smooth(r.frames, 5)), _rms(r.frames), 1.0),
  'unitRms+logAmp(w=2)': (r) =>
      _appendLogAmp(_unitRms(_smooth(r.frames, 5)), _rms(r.frames), 2.0),
  'resample64+unitRms+logAmp(w=2)': (r) => _appendLogAmp(
      _unitRms(_resample(_smooth(r.frames, 5), 64)), _rms(r.frames), 2.0),
};

// ── evaluation ──────────────────────────────────────────────────────────────

class Result {
  Result(this.name, this.cap, this.margin, this.trueAccept, this.falseAccept,
      this.loo, this.distSpread, this.worstTrue, this.bestFalse);
  final String name;
  final double cap;
  final double margin;
  final double trueAccept;
  final int falseAccept;
  final double loo;
  final String distSpread;

  /// Hardest genuine rep: the largest LOO distance from a gesture rep to its
  /// own class. A usable cap must sit ABOVE this.
  final double worstTrue;

  /// Closest impostor: the smallest distance from any rep to a class it does
  /// not belong to (wrong gesture, or any confusable). A usable cap must sit
  /// BELOW this. bestFalse > worstTrue means a perfectly separating cap
  /// exists, and (bestFalse / worstTrue) is the headroom on it.
  final double bestFalse;
}

Result evaluate(String name, Transform t, List<Rep> reps) {
  final feats = {for (final r in reps) r.id: t(r)};

  // Full distance matrix: every rep vs every gesture rep (LOO — never itself).
  // dist[queryId][gestureLabel] = min DTW over that label's reps.
  final dist = <String, Map<String, double>>{};
  for (final q in reps) {
    final byLabel = <String, double>{};
    for (final g in gestureNames) {
      var best = double.infinity;
      for (final r in reps) {
        if (r.label != g) continue;
        if (r.id == q.id) continue; // leave-one-out
        final d = DtwMatcher.distance(feats[q.id]!, feats[r.id]!);
        if (d < best) best = d;
      }
      byLabel[g] = best;
    }
    dist[q.id] = byLabel;
  }

  // LOO top-1 accuracy over gestures only (ignoring the accept rule).
  var correct = 0, total = 0;
  for (final q in reps.where((r) => r.isGesture)) {
    final ranked = dist[q.id]!.entries.toList()
      ..sort((a, b) => a.value.compareTo(b.value));
    if (ranked.first.key == q.label) correct++;
    total++;
  }

  // Grid-search the accept rule for the best zero-false-accept point.
  final allDists = <double>[];
  for (final q in reps) {
    allDists.addAll(dist[q.id]!.values.where((d) => d.isFinite));
  }
  allDists.sort();
  final lo = allDists.first, hi = allDists.last;

  var bestTrue = -1.0;
  var bestCap = 0.0, bestMargin = 0.0;
  for (var ci = 0; ci <= 60; ci++) {
    final cap = lo + (hi - lo) * ci / 60;
    for (var mi = 0; mi <= 40; mi++) {
      final margin = (hi - lo) * mi / 200;
      var ta = 0, fa = 0;
      for (final q in reps) {
        final ranked = dist[q.id]!.entries.toList()
          ..sort((a, b) => a.value.compareTo(b.value));
        final best = ranked.first;
        final second = ranked.length > 1 ? ranked[1].value : double.infinity;
        final accepted = best.value < cap && (second - best.value) > margin;
        if (!accepted) continue;
        if (q.isGesture && best.key == q.label) {
          ta++;
        } else {
          fa++;
        }
      }
      if (fa == 0 && ta > bestTrue) {
        bestTrue = ta.toDouble();
        bestCap = cap;
        bestMargin = margin;
      }
    }
  }

  // Headroom: hardest genuine rep vs closest impostor.
  var worstTrue = 0.0;
  var bestFalse = double.infinity;
  for (final q in reps) {
    for (final e in dist[q.id]!.entries) {
      if (!e.value.isFinite) continue;
      final isOwnClass = q.isGesture && e.key == q.label;
      if (isOwnClass) {
        if (e.value > worstTrue) worstTrue = e.value;
      } else {
        if (e.value < bestFalse) bestFalse = e.value;
      }
    }
  }

  final gestureCount = reps.where((r) => r.isGesture).length;
  return Result(
    name,
    bestCap,
    bestMargin,
    bestTrue < 0 ? 0.0 : bestTrue / gestureCount,
    0,
    total == 0 ? 0 : correct / total,
    '${lo.toStringAsFixed(2)}..${hi.toStringAsFixed(2)}',
    worstTrue,
    bestFalse,
  );
}

/// Distances from every rep to every gesture class, leave-one-out.
Map<String, Map<String, double>> distanceMatrix(Transform t, List<Rep> reps) {
  final feats = {for (final r in reps) r.id: t(r)};
  final dist = <String, Map<String, double>>{};
  for (final q in reps) {
    final byLabel = <String, double>{};
    for (final g in gestureNames) {
      var best = double.infinity;
      for (final r in reps) {
        if (r.label != g || r.id == q.id) continue;
        final d = DtwMatcher.distance(feats[q.id]!, feats[r.id]!);
        if (d < best) best = d;
      }
      byLabel[g] = best;
    }
    dist[q.id] = byLabel;
  }
  return dist;
}

/// Honest threshold estimate: fit (cap, margin) on one half of the reps,
/// score the other half, both ways. The sweep table's numbers are fit
/// in-sample; these are not.
void crossValidateThresholds(
    String name, Transform t, List<Rep> reps) {
  final dist = distanceMatrix(t, reps);

  ({double cap, double margin}) fit(List<Rep> train) {
    final all = <double>[];
    for (final q in reps) {
      all.addAll(dist[q.id]!.values.where((d) => d.isFinite));
    }
    all.sort();
    final lo = all.first, hi = all.last;
    var bestTa = -1;
    var bc = 0.0, bm = 0.0;
    for (var ci = 0; ci <= 60; ci++) {
      final cap = lo + (hi - lo) * ci / 60;
      for (var mi = 0; mi <= 40; mi++) {
        final margin = (hi - lo) * mi / 200;
        var ta = 0, fa = 0;
        for (final q in train) {
          final ranked = dist[q.id]!.entries.toList()
            ..sort((a, b) => a.value.compareTo(b.value));
          final best = ranked.first;
          final second = ranked.length > 1 ? ranked[1].value : double.infinity;
          if (!(best.value < cap && (second - best.value) > margin)) continue;
          if (q.isGesture && best.key == q.label) {
            ta++;
          } else {
            fa++;
          }
        }
        if (fa == 0 && ta > bestTa) {
          bestTa = ta;
          bc = cap;
          bm = margin;
        }
      }
    }
    return (cap: bc, margin: bm);
  }

  ({int ta, int fa, int n}) score(List<Rep> test, double cap, double margin) {
    var ta = 0, fa = 0, n = 0;
    for (final q in test) {
      if (q.isGesture) n++;
      final ranked = dist[q.id]!.entries.toList()
        ..sort((a, b) => a.value.compareTo(b.value));
      final best = ranked.first;
      final second = ranked.length > 1 ? ranked[1].value : double.infinity;
      if (!(best.value < cap && (second - best.value) > margin)) continue;
      if (q.isGesture && best.key == q.label) {
        ta++;
      } else {
        fa++;
      }
    }
    return (ta: ta, fa: fa, n: n);
  }

  var totalTa = 0, totalFa = 0, totalN = 0;
  final caps = <double>[], margins = <double>[];
  for (var fold = 0; fold < 2; fold++) {
    final train = reps.where((r) => r.index % 2 == fold).toList();
    final test = reps.where((r) => r.index % 2 != fold).toList();
    final p = fit(train);
    caps.add(p.cap);
    margins.add(p.margin);
    final s = score(test, p.cap, p.margin);
    totalTa += s.ta;
    totalFa += s.fa;
    totalN += s.n;
  }
  stdout.writeln('${name.padRight(32)}'
      'cap≈${caps.map((c) => c.toStringAsFixed(2)).join('/')}  '
      'margin≈${margins.map((m) => m.toStringAsFixed(2)).join('/')}  '
      'held-out accept=${(100 * totalTa / totalN).toStringAsFixed(0)}%  '
      'held-out FALSE ACCEPTS=$totalFa');
}

/// The safety curve: how much genuine-gesture acceptance you buy at each cap,
/// and where the first false accept appears. The design stance is
/// never-false-advance, so the right pick is the largest cap comfortably
/// BELOW the first-false-accept cap — not the one that maximises acceptance.
void printOperatingCurve(String name, Transform t, List<Rep> reps,
    {double margin = 0.15}) {
  final dist = distanceMatrix(t, reps);
  stdout.writeln('\n── operating curve for "$name" (margin=$margin) ──');
  stdout.writeln('${'cap'.padLeft(6)}${'accept'.padLeft(9)}${'falseAcc'.padLeft(10)}'
      '   first offender');
  for (var cap = 0.50; cap <= 1.30001; cap += 0.05) {
    var ta = 0, fa = 0, n = 0;
    String offender = '';
    for (final q in reps) {
      if (q.isGesture) n++;
      final ranked = dist[q.id]!.entries.toList()
        ..sort((a, b) => a.value.compareTo(b.value));
      final best = ranked.first;
      final second = ranked.length > 1 ? ranked[1].value : double.infinity;
      if (!(best.value < cap && (second - best.value) > margin)) continue;
      if (q.isGesture && best.key == q.label) {
        ta++;
      } else {
        fa++;
        if (offender.isEmpty) offender = '${q.id}->${best.key}';
      }
    }
    stdout.writeln('${cap.toStringAsFixed(2).padLeft(6)}'
        '${'${(100 * ta / n).toStringAsFixed(0)}%'.padLeft(9)}'
        '${fa.toString().padLeft(10)}   $offender');
  }
}

/// Handedness study. Two questions, neither of which needs new captures:
///
///  (1) Is the mirror an exact isometry through the whole feature pipeline?
///      If so, a left-handed player on mirrored templates gets provably
///      IDENTICAL accuracy to the right-handed player it was derived from —
///      no recapture, no recalibration, no separate corpus.
///  (2) Can we skip the settings toggle by matching against templates AND
///      their mirrors, taking the min? That is handedness-agnostic with no
///      user setting, but it doubles the number of things a garbage motion
///      can latch onto — so it has to be paid for in false accepts.
void handednessStudy(String name, Transform t, List<Rep> reps,
    {double cap = 0.80, double margin = 0.15}) {
  stdout.writeln('\n══ handedness study under "$name" ══');

  // (1) isometry check: does mirroring both sides preserve DTW exactly?
  var worstDelta = 0.0;
  final sample = reps.take(12).toList();
  for (var i = 0; i < sample.length; i++) {
    for (var j = i + 1; j < sample.length; j++) {
      final a = sample[i], b = sample[j];
      final plain = DtwMatcher.distance(t(a), t(b));
      final mirrored = DtwMatcher.distance(
        t(Rep(a.label, a.index, a.rateHz, _mirror(a.frames))),
        t(Rep(b.label, b.index, b.rateHz, _mirror(b.frames))),
      );
      final d = (plain - mirrored).abs();
      if (d > worstDelta) worstDelta = d;
    }
  }
  stdout.writeln('(1) mirror-both isometry: worst |d(a,b) - d(mirror a, '
      'mirror b)| = ${worstDelta.toStringAsExponential(2)}');
  stdout.writeln('    ${worstDelta < 1e-9 ? 'EXACT — a mirrored template set '
      'reproduces right-handed accuracy bit for bit.' : 'NOT exact — the '
      'pipeline is not orthogonal; mirrored templates would need their own '
      'calibration.'}');

  // How different is a mirrored gesture from its original? If ~0, the
  // gesture is laterally symmetric and handedness is moot for it.
  stdout.writeln('(2) self-vs-mirror distance per gesture '
      '(0 = laterally symmetric, handedness irrelevant):');
  for (final g in gestureNames) {
    var sum = 0.0;
    var n = 0;
    for (final r in reps.where((x) => x.label == g)) {
      sum += DtwMatcher.distance(
          t(r), t(Rep(r.label, r.index, r.rateHz, _mirror(r.frames))));
      n++;
    }
    final own = reps.where((x) => x.label == g).length;
    stdout.writeln('    ${g.padRight(8)} mean self-vs-mirror = '
        '${(sum / n).toStringAsFixed(3)}   (reps=$own)');
  }

  // (3) Does matching against templates ∪ mirrors cost us false accepts?
  final feats = <String, List<List<double>>>{};
  final mirrorFeats = <String, List<List<double>>>{};
  for (final r in reps) {
    feats[r.id] = t(r);
    mirrorFeats[r.id] = t(Rep(r.label, r.index, r.rateHz, _mirror(r.frames)));
  }

  ({int ta, int fa, int n, String offender}) run(bool includeMirrors) {
    var ta = 0, fa = 0, n = 0;
    var offender = '';
    for (final q in reps) {
      if (q.isGesture) n++;
      final byLabel = <String, double>{};
      for (final g in gestureNames) {
        var best = double.infinity;
        for (final r in reps) {
          if (r.label != g || r.id == q.id) continue;
          final d = DtwMatcher.distance(feats[q.id]!, feats[r.id]!);
          if (d < best) best = d;
          if (includeMirrors) {
            final dm = DtwMatcher.distance(feats[q.id]!, mirrorFeats[r.id]!);
            if (dm < best) best = dm;
          }
        }
        byLabel[g] = best;
      }
      final ranked = byLabel.entries.toList()
        ..sort((a, b) => a.value.compareTo(b.value));
      final best = ranked.first;
      final second = ranked.length > 1 ? ranked[1].value : double.infinity;
      if (!(best.value < cap && (second - best.value) > margin)) continue;
      if (q.isGesture && best.key == q.label) {
        ta++;
      } else {
        fa++;
        if (offender.isEmpty) offender = '${q.id}->${best.key}';
      }
    }
    return (ta: ta, fa: fa, n: n, offender: offender);
  }

  final plain = run(false);
  final both = run(true);
  stdout.writeln('(3) cost of a handedness-agnostic classifier '
      '(cap=$cap, margin=$margin):');
  stdout.writeln('    templates only        : accept='
      '${(100 * plain.ta / plain.n).toStringAsFixed(0)}%  falseAccepts='
      '${plain.fa}  ${plain.offender}');
  stdout.writeln('    templates + mirrors   : accept='
      '${(100 * both.ta / both.n).toStringAsFixed(0)}%  falseAccepts='
      '${both.fa}  ${both.offender}');
}

/// Generalization probe — the closest available proxy for "will ONE person's
/// templates recognize ANOTHER person's performance?" without a second
/// person in the room.
///
/// Enrol only reps [0..4] and classify only reps [5..9]. Within this corpus
/// the later reps drift systematically (water reps 5-9 run ~40% slower than
/// 0-4, earth likewise), so this measures survival across a real style shift
/// rather than across interleaved samples of one steady style. It is a LOWER
/// bound on difficulty — a different body is a bigger shift than a different
/// half-hour — so a representation that FAILS here will certainly not
/// generalize across people. Passing here is necessary, not sufficient.
void generalizationProbe(List<Rep> reps, {double margin = 0.15}) {
  stdout.writeln('\n══ generalization probe: enrol reps 0-4, test reps 5-9 ══');
  stdout.writeln('(does a template set survive a systematic style shift?)');
  stdout.writeln('${'transform'.padRight(32)}${'top-1'.padLeft(8)}'
      '${'bestCap'.padLeft(9)}${'accept'.padLeft(9)}${'falseAcc'.padLeft(10)}');

  for (final entry in transforms.entries) {
    final t = entry.value;
    final feats = {for (final r in reps) r.id: t(r)};
    final enrol = reps.where((r) => r.isGesture && r.index <= 4).toList();
    // Test set: held-out gesture reps AND every confusable (confusables are
    // never templates, so all 30 stay available as impostors).
    final test = reps
        .where((r) => (r.isGesture && r.index >= 5) || !r.isGesture)
        .toList();

    final dist = <String, Map<String, double>>{};
    for (final q in test) {
      final byLabel = <String, double>{};
      for (final g in gestureNames) {
        var best = double.infinity;
        for (final r in enrol) {
          if (r.label != g) continue;
          final d = DtwMatcher.distance(feats[q.id]!, feats[r.id]!);
          if (d < best) best = d;
        }
        byLabel[g] = best;
      }
      dist[q.id] = byLabel;
    }

    var top1 = 0, n = 0;
    for (final q in test.where((r) => r.isGesture)) {
      n++;
      final ranked = dist[q.id]!.entries.toList()
        ..sort((a, b) => a.value.compareTo(b.value));
      if (ranked.first.key == q.label) top1++;
    }

    // Best zero-false-accept cap on the held-out set.
    var bestAccept = 0, bestFa = 0;
    var bestCap = 0.0;
    for (var ci = 0; ci <= 120; ci++) {
      final cap = 0.05 * ci;
      var ta = 0, fa = 0;
      for (final q in test) {
        final ranked = dist[q.id]!.entries.toList()
          ..sort((a, b) => a.value.compareTo(b.value));
        final best = ranked.first;
        final second = ranked.length > 1 ? ranked[1].value : double.infinity;
        if (!(best.value < cap && (second - best.value) > margin)) continue;
        if (q.isGesture && best.key == q.label) {
          ta++;
        } else {
          fa++;
        }
      }
      if (fa == 0 && ta > bestAccept) {
        bestAccept = ta;
        bestCap = cap;
        bestFa = fa;
      }
    }

    stdout.writeln('${entry.key.padRight(32)}'
        '${'${(100 * top1 / n).toStringAsFixed(0)}%'.padLeft(8)}'
        '${bestCap.toStringAsFixed(2).padLeft(9)}'
        '${'${(100 * bestAccept / n).toStringAsFixed(0)}%'.padLeft(9)}'
        '${bestFa.toString().padLeft(10)}');
  }
}

/// Best length-normalised alignment cost of every PREFIX of [query] against
/// any prefix of [ref] — i.e. "how well am I tracking this template so far?"
/// evaluated after each incoming frame, with the template end left open.
///
/// This is the signal a real-time haptic guide would drive: it exists at
/// frame 10 of a 150-frame gesture, not just at the end. Same cost/steps
/// normalisation StreamingPhonemeScorer uses on the vocal side
/// (DtwMatcher.distanceWithSteps) — raw accumulated cost grows with path
/// length, so it must be divided by the step count or a slow performance
/// looks like a bad one.
List<double> prefixCurve(List<List<double>> query, List<List<double>> ref) {
  final n = query.length, m = ref.length;
  if (n == 0 || m == 0) return const [];
  var prevCost = List<double>.filled(m, double.infinity);
  var prevSteps = List<int>.filled(m, 1);
  final out = <double>[];

  for (var i = 0; i < n; i++) {
    final cost = List<double>.filled(m, double.infinity);
    final steps = List<int>.filled(m, 1);
    for (var j = 0; j < m; j++) {
      var d = 0.0;
      for (var k = 0; k < query[i].length; k++) {
        final delta = query[i][k] - ref[j][k];
        d += delta * delta;
      }
      d = math.sqrt(d);

      if (i == 0 && j == 0) {
        cost[0] = d;
        steps[0] = 1;
        continue;
      }
      var best = double.infinity;
      var bestSteps = 1;
      if (i > 0) {
        if (prevCost[j] < best) {
          best = prevCost[j];
          bestSteps = prevSteps[j];
        }
        if (j > 0 && prevCost[j - 1] < best) {
          best = prevCost[j - 1];
          bestSteps = prevSteps[j - 1];
        }
      }
      if (j > 0 && cost[j - 1] < best) {
        best = cost[j - 1];
        bestSteps = steps[j - 1];
      }
      if (best.isFinite) {
        cost[j] = best + d;
        steps[j] = bestSteps + 1;
      }
    }
    // Template end open: best normalised cost over any template position.
    var bestNorm = double.infinity;
    for (var j = 0; j < m; j++) {
      if (!cost[j].isFinite) continue;
      final v = cost[j] / steps[j];
      if (v < bestNorm) bestNorm = v;
    }
    out.add(bestNorm);
    prevCost = cost;
    prevSteps = steps;
  }
  return out;
}

/// Can a haptic guide give useful feedback DURING the motion?
///
/// For every gesture rep, track the running prefix cost against its own
/// class and against the best competing class, sampled at 25/50/75/100% of
/// the way through. If own-class cost is already separated from
/// other-class cost early, a fading-haptic trainer has a real signal to
/// drive from the first quarter of the gesture — the player feels the drift
/// as it happens rather than being told afterwards.
void streamingFeedbackStudy(String name, Transform t, List<Rep> reps) {
  stdout.writeln('\n══ streaming feedback viability under "$name" ══');
  stdout.writeln('running prefix cost (lower = tracking the template better)');
  stdout.writeln('${'gesture'.padRight(10)}${'@25%'.padLeft(18)}'
      '${'@50%'.padLeft(18)}${'@75%'.padLeft(18)}${'@100%'.padLeft(18)}');
  stdout.writeln('${''.padRight(10)}${'own / other'.padLeft(18)}'
      '${'own / other'.padLeft(18)}${'own / other'.padLeft(18)}'
      '${'own / other'.padLeft(18)}');

  final feats = {for (final r in reps) r.id: t(r)};
  for (final g in gestureNames) {
    final quart = [0.25, 0.50, 0.75, 1.0];
    final ownAcc = List<double>.filled(4, 0.0);
    final othAcc = List<double>.filled(4, 0.0);
    var count = 0;
    for (final q in reps.where((r) => r.label == g)) {
      final own = <double>[];
      final oth = <double>[];
      List<double>? ownBest;
      List<double>? othBest;
      for (final r in reps.where((x) => x.isGesture && x.id != q.id)) {
        final curve = prefixCurve(feats[q.id]!, feats[r.id]!);
        if (r.label == g) {
          if (ownBest == null) {
            ownBest = [...curve];
          } else {
            for (var i = 0; i < curve.length; i++) {
              if (curve[i] < ownBest[i]) ownBest[i] = curve[i];
            }
          }
        } else {
          if (othBest == null) {
            othBest = [...curve];
          } else {
            for (var i = 0; i < curve.length; i++) {
              if (curve[i] < othBest[i]) othBest[i] = curve[i];
            }
          }
        }
      }
      if (ownBest == null || othBest == null) continue;
      own.addAll(ownBest);
      oth.addAll(othBest);
      for (var qi = 0; qi < 4; qi++) {
        final idx = ((own.length - 1) * quart[qi]).round();
        ownAcc[qi] += own[idx];
        othAcc[qi] += oth[idx];
      }
      count++;
    }
    if (count == 0) continue;
    final cells = <String>[];
    for (var qi = 0; qi < 4; qi++) {
      final o = ownAcc[qi] / count;
      final x = othAcc[qi] / count;
      cells.add('${o.toStringAsFixed(2)} / ${x.toStringAsFixed(2)}'
          '${x > o ? ' ✓' : ' ✗'}'.padLeft(0));
    }
    stdout.writeln('${g.padRight(10)}'
        '${cells.map((c) => c.padLeft(18)).join()}');
  }
}

/// Per-gesture crispness: mean own-class distance vs mean nearest-other-class
/// distance, and their ratio. Ratio >> 1 means the gesture is a tight,
/// well-isolated cluster; ratio near 1 means it barely stands apart from its
/// neighbours under this representation.
///
/// This is the view that separates "the player performed it inconsistently"
/// from "the matcher is wrong for this KIND of gesture" — a tremor scores
/// badly under trajectory DTW no matter how well it is performed, because
/// successive shake cycles have arbitrary phase.
void perGestureSeparability(List<String> names, List<Rep> reps) {
  stdout.writeln('\n══ per-gesture crispness (own / nearest-other, ratio) ══');
  stdout.write('transform'.padRight(26));
  for (final g in gestureNames) {
    stdout.write(g.padLeft(16));
  }
  stdout.writeln();

  for (final name in names) {
    final t = transforms[name]!;
    final feats = <String, List<List<double>>>{};
    var usable = true;
    for (final r in reps) {
      final f = t(r);
      if (f.isEmpty) usable = false;
      feats[r.id] = f;
    }
    if (!usable) {
      stdout.writeln('${name.padRight(26)}  (some reps too short for this '
          'window — skipped)');
      continue;
    }

    stdout.write(name.padRight(26));
    for (final g in gestureNames) {
      var ownSum = 0.0, othSum = 0.0;
      var n = 0;
      for (final q in reps.where((r) => r.label == g)) {
        var own = double.infinity, oth = double.infinity;
        for (final r in reps.where((x) => x.isGesture && x.id != q.id)) {
          final d = DtwMatcher.distance(feats[q.id]!, feats[r.id]!);
          if (r.label == g) {
            if (d < own) own = d;
          } else {
            if (d < oth) oth = d;
          }
        }
        if (!own.isFinite || !oth.isFinite) continue;
        ownSum += own;
        othSum += oth;
        n++;
      }
      if (n == 0) {
        stdout.write('—'.padLeft(16));
        continue;
      }
      final own = ownSum / n, oth = othSum / n;
      stdout.write('${own.toStringAsFixed(2)}/${oth.toStringAsFixed(2)}='
              '${(oth / own).toStringAsFixed(2)}'
          .padLeft(16));
    }
    stdout.writeln();
  }
}

void printPerRep(String name, Transform t, List<Rep> reps, double cap, double margin) {
  final dist = distanceMatrix(t, reps);
  stdout.writeln('\n── per-rep detail under "$name" '
      '(cap=$cap, margin=$margin) ──');
  stdout.writeln('${'rep'.padRight(22)}${'own'.padLeft(8)}${'nearestOther'.padLeft(14)}'
      '${'margin'.padLeft(9)}   verdict');
  for (final label in [...gestureNames, ...confusableNames]) {
    for (final q in reps.where((r) => r.label == label)) {
      final ranked = dist[q.id]!.entries.toList()
        ..sort((a, b) => a.value.compareTo(b.value));
      final best = ranked.first;
      final second = ranked.length > 1 ? ranked[1].value : double.infinity;
      final m = second - best.value;
      final accepted = best.value < cap && m > margin;
      final verdict = accepted ? best.key : 'neutral';
      final own = q.isGesture ? dist[q.id]![q.label]! : double.nan;
      final wrong = accepted && verdict != q.label;
      stdout.writeln('${q.id.padRight(22)}'
          '${own.isNaN ? '   -' : own.toStringAsFixed(3).padLeft(8)}'
          '${'${best.key} ${best.value.toStringAsFixed(3)}'.padLeft(14)}'
          '${m.toStringAsFixed(3).padLeft(9)}   $verdict'
          '${wrong ? '   <<< FALSE ACCEPT' : ''}'
          '${!accepted && q.isGesture ? '   (missed)' : ''}');
    }
  }
}

void printConfusion(String name, Transform t, List<Rep> reps) {
  final feats = {for (final r in reps) r.id: t(r)};
  stdout.writeln('\n── nearest-gesture confusion under "$name" '
      '(LOO, no accept rule) ──');
  stdout.writeln('${'query'.padRight(20)}${gestureNames.map((g) => g.padLeft(9)).join()}'
      '   -> nearest');
  for (final label in [...gestureNames, ...confusableNames]) {
    final rows = reps.where((r) => r.label == label);
    final tally = <String, int>{};
    final meanD = <String, double>{for (final g in gestureNames) g: 0.0};
    for (final q in rows) {
      final byLabel = <String, double>{};
      for (final g in gestureNames) {
        var best = double.infinity;
        for (final r in reps) {
          if (r.label != g || r.id == q.id) continue;
          final d = DtwMatcher.distance(feats[q.id]!, feats[r.id]!);
          if (d < best) best = d;
        }
        byLabel[g] = best;
        meanD[g] = meanD[g]! + best;
      }
      final nearest =
          byLabel.entries.reduce((a, b) => a.value <= b.value ? a : b).key;
      tally[nearest] = (tally[nearest] ?? 0) + 1;
    }
    final n = rows.length;
    final cells =
        gestureNames.map((g) => (meanD[g]! / n).toStringAsFixed(2).padLeft(9)).join();
    final t2 = (tally.entries.toList()
          ..sort((a, b) => b.value.compareTo(a.value)))
        .map((e) => '${e.key}×${e.value}')
        .join(', ');
    stdout.writeln('${label.padRight(20)}$cells   $t2');
  }
}

void main(List<String> args) {
  final dir = args.isNotEmpty ? args.first : 'gest';
  final reps = loadCorpus(dir);
  if (reps.isEmpty) {
    stderr.writeln('No corpus found in $dir');
    exit(1);
  }
  stdout.writeln('Loaded ${reps.length} reps from $dir');

  stdout.writeln('\n── per-class mean-square energy (the stillness gate\'s scale) ──');
  for (final label in [...gestureNames, ...confusableNames]) {
    final es = reps
        .where((r) => r.label == label)
        .map((r) => _meanSquareEnergy(r.frames))
        .toList()
      ..sort();
    stdout.writeln('${label.padRight(20)} min=${es.first.toStringAsFixed(2).padLeft(9)}'
        '  median=${es[es.length ~/ 2].toStringAsFixed(2).padLeft(9)}'
        '  max=${es.last.toStringAsFixed(2).padLeft(9)}');
  }

  // What production does TODAY: raw frames, energyFloor 0.02, cap 4.0,
  // margin 0.5 — the exact defaults in GestureClassifier's const ctor, which
  // is what practice_screen's "test last capture" button constructs.
  stdout.writeln('\n── production defaults today '
      '(raw frames, floor=0.02, cap=4.0, margin=0.5) ──');
  {
    final dist = distanceMatrix(transforms['raw (production today)']!, reps);
    final tally = <String, int>{};
    for (final q in reps) {
      final energy = _meanSquareEnergy(q.frames);
      String verdict;
      if (energy < 0.02) {
        verdict = 'neutral (stillness)';
      } else {
        final ranked = dist[q.id]!.entries.toList()
          ..sort((a, b) => a.value.compareTo(b.value));
        final best = ranked.first;
        final second = ranked.length > 1 ? ranked[1].value : double.infinity;
        final accepted =
            best.value < 4.0 && (second - best.value) > 0.5;
        verdict = accepted ? best.key : 'neutral';
      }
      final correct = q.isGesture ? q.label : 'neutral';
      final key = '${q.label} -> $verdict'
          '${verdict != correct && verdict != 'neutral' && verdict != 'neutral (stillness)' ? '  <<< FALSE ACCEPT' : ''}'
          '${verdict.startsWith('neutral') && q.isGesture ? '  (missed)' : ''}';
      tally[key] = (tally[key] ?? 0) + 1;
    }
    final keys = tally.keys.toList()..sort();
    for (final k in keys) {
      stdout.writeln('  ${tally[k].toString().padLeft(2)}x  $k');
    }
  }

  stdout.writeln('\n── representation sweep '
      '(LOO acc = nearest-gesture; accept = best zero-false-accept point) ──');
  stdout.writeln('${'transform'.padRight(32)}'
      '${'LOO acc'.padLeft(9)}${'cap'.padLeft(8)}${'margin'.padLeft(8)}'
      '${'accept@0FA'.padLeft(12)}${'worstTrue'.padLeft(11)}'
      '${'bestFalse'.padLeft(11)}${'headroom'.padLeft(10)}');
  final results = <Result>[];
  for (final e in transforms.entries) {
    final r = evaluate(e.key, e.value, reps);
    results.add(r);
    final headroom = r.worstTrue <= 0 ? 0.0 : r.bestFalse / r.worstTrue;
    stdout.writeln('${r.name.padRight(32)}'
        '${(r.loo * 100).toStringAsFixed(0).padLeft(8)}%'
        '${r.cap.toStringAsFixed(2).padLeft(8)}'
        '${r.margin.toStringAsFixed(2).padLeft(8)}'
        '${(r.trueAccept * 100).toStringAsFixed(0).padLeft(11)}%'
        '${r.worstTrue.toStringAsFixed(3).padLeft(11)}'
        '${r.bestFalse.toStringAsFixed(3).padLeft(11)}'
        '${headroom.toStringAsFixed(2).padLeft(9)}x');
  }

  results.sort((a, b) => b.trueAccept.compareTo(a.trueAccept));
  final winner = results.first;
  stdout.writeln('\nBest representation: "${winner.name}" — '
      '${(winner.trueAccept * 100).toStringAsFixed(0)}% of real gesture reps '
      'accepted with zero false accepts.');
  printConfusion(winner.name, transforms[winner.name]!, reps);
  printConfusion('raw (production today)', transforms['raw (production today)']!, reps);

  stdout.writeln('\n── held-out threshold cross-validation (2-fold by rep index) ──');
  for (final name in [
    'raw (production today)',
    'unitRms',
    'smooth5+unitRms',
    'gyroX3+unitRms',
    'gyroX4+unitRms',
    'gyroOnly+unitRms',
    'unitRms+logAmp(w=2)',
    'blockNorm',
    'smooth5+blockNorm',
    'smooth5+blockNorm+logAmp(w=2)',
  ]) {
    crossValidateThresholds(name, transforms[name]!, reps);
  }

  for (final name in ['smooth5+blockNorm', 'gyroX4+unitRms']) {
    printOperatingCurve(name, transforms[name]!, reps);
  }

  perGestureSeparability([
    'gyroX4+unitRms',
    'traj+spec(w=0.5)',
    'traj+spec(w=1.0)',
    'traj+spec(w=2.0)',
    'spec2 (|a|,|g| bands)',
    'spec2+normCh',
    'spec6 (all axes)',
    'spec6+normCh',
    'spec2 fine (win16 hop6)',
  ], reps);

  handednessStudy('gyroX4+unitRms', transforms['gyroX4+unitRms']!, reps);
  generalizationProbe(reps);
  streamingFeedbackStudy('gyroX4+unitRms', transforms['gyroX4+unitRms']!, reps);

  printPerRep(winner.name, transforms[winner.name]!, reps, winner.cap, winner.margin);
}
