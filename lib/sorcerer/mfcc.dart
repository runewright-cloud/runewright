// SPDX-License-Identifier: GPL-3.0-or-later
//
// mfcc.dart — MFCC feature extraction and DTW matching utilities.
//
// MfccExtractor converts raw PCM-16 LE mono audio into a sequence of
// 13-coefficient MFCC feature vectors (one per 10 ms frame) using the
// standard pipeline: pre-emphasis → framing → Hamming window → FFT →
// mel filterbank → log → DCT.
//
// DtwMatcher computes a Dynamic Time Warping distance between two MFCC
// sequences and converts that distance to a pronunciation score in [0.0, 1.0].
//
// Both classes are pure computation (no I/O). They are used only by
// ReferenceMatchVocalScorer; the battle layer never imports this file.

import 'dart:math' as math;
import 'dart:typed_data';

// ── MFCC extraction ───────────────────────────────────────────────────────────

class MfccExtractor {
  MfccExtractor._();

  static const int sampleRate = 16000;  // Hz
  static const int numFilters = 26;     // mel filterbank size
  static const int numCoeffs  = 13;     // MFCCs kept (c0–c12)
  static const int _frameSize = 400;    // 25 ms at 16 kHz
  static const int _hopSize   = 160;    // 10 ms at 16 kHz (frame stride)
  static const int _fftSize   = 512;    // ≥ frameSize, power of 2
  static const double _preEmph = 0.97;  // pre-emphasis coefficient

  // These are computed once and cached for the process lifetime.
  static List<double>? _hamming;
  static List<List<double>>? _filterbank;

  /// Extracts MFCC feature vectors from raw PCM-16 LE mono [pcmBytes].
  ///
  /// Returns one 13-element vector per 10 ms frame. Returns an empty list if
  /// the audio is shorter than one frame (< 25 ms at 16 kHz).
  static List<List<double>> extract(Uint8List pcmBytes) {
    if (pcmBytes.length < _frameSize * 2) return [];

    final samples   = _pcm16ToFloat(pcmBytes);
    final emphasised = _preEmphasise(samples);
    final window    = _hammingWindow();
    final filters   = _melFilterbank();
    final frames    = <List<double>>[];

    for (int offset = 0;
        offset + _frameSize <= emphasised.length;
        offset += _hopSize) {
      // Zero-pad frame to FFT size and apply Hamming window.
      final re = List<double>.generate(
        _fftSize,
        (i) => i < _frameSize ? emphasised[offset + i] * window[i] : 0.0,
      );
      final im = List<double>.filled(_fftSize, 0.0);
      _fft(re, im);

      // Power spectrum (first N/2+1 bins, symmetric).
      final power = List<double>.generate(
        _fftSize ~/ 2 + 1,
        (k) => re[k] * re[k] + im[k] * im[k],
      );

      // Mel filterbank energies → log (eps guard avoids -inf).
      final logE = List<double>.generate(numFilters, (m) {
        var e = 0.0;
        final filt = filters[m];
        for (int k = 0; k < power.length && k < filt.length; k++) {
          e += power[k] * filt[k];
        }
        return math.log(e + 1e-8);
      });

      frames.add(_dct(logE, numCoeffs));
    }
    return frames;
  }

  /// First-order delta (regression) coefficients over [frames], one delta
  /// vector per input frame, using the standard N=2 regression window
  /// (Furui 1986 / HTK convention):
  ///   delta[t] = sum_{n=1..N} n·(frame[t+n] − frame[t−n]) / (2·sum n²)
  /// Frame indices outside [0, frames.length) are clamped to the nearest
  /// boundary frame (replicate padding) rather than zero-padded, so edge
  /// deltas reflect the nearest real transition instead of an artificial
  /// jump to/from silence.
  ///
  /// Captures the trajectory (onset/offset dynamics) static coefficients
  /// miss — e.g. a stop-glide transition like aqua's /kw/ — which is why
  /// they exist: measured 2026-07-22 that static-only MFCC+DTW leaves some
  /// vowel-heavy word pairs essentially tied (aqua vs terra, negative
  /// margins) even with matched-pace, same-speaker templates. See
  /// docs/M4_findings.md.
  ///
  /// Dimension-agnostic — works on any per-frame vector width, so callers
  /// can compute delta-delta by calling this again on its own output.
  static List<List<double>> deltas(List<List<double>> frames, {int n = 2}) {
    if (frames.isEmpty) return frames;
    final dims = frames[0].length;
    final len = frames.length;
    final denom = 2.0 *
        List<int>.generate(n, (i) => i + 1)
            .fold<int>(0, (sum, k) => sum + k * k);
    return List<List<double>>.generate(len, (t) {
      final out = List<double>.filled(dims, 0.0);
      for (int k = 1; k <= n; k++) {
        final plus = frames[math.min(t + k, len - 1)];
        final minus = frames[math.max(t - k, 0)];
        for (int d = 0; d < dims; d++) {
          out[d] += k * (plus[d] - minus[d]);
        }
      }
      for (int d = 0; d < dims; d++) {
        out[d] /= denom;
      }
      return out;
    });
  }

  /// RMS of [pcmBytes] (PCM-16 LE mono), normalised to the ±1.0 float range.
  ///
  /// Returns 0.0 for input shorter than 2 bytes.
  static double computeRms(Uint8List pcmBytes) {
    if (pcmBytes.length < 2) return 0.0;
    var sumSq = 0.0;
    var count = 0;
    for (int i = 0; i + 1 < pcmBytes.length; i += 2) {
      final raw = pcmBytes[i] | (pcmBytes[i + 1] << 8);
      final s = raw > 32767 ? raw - 65536 : raw;
      sumSq += s * s;
      count++;
    }
    return count > 0 ? math.sqrt(sumSq / count) / 32768.0 : 0.0;
  }

  // ── Private DSP helpers ───────────────────────────────────────────────────

  static List<double> _pcm16ToFloat(Uint8List bytes) {
    final n = bytes.length ~/ 2;
    final out = List<double>.filled(n, 0.0);
    for (int i = 0; i < n; i++) {
      final raw = bytes[i * 2] | (bytes[i * 2 + 1] << 8);
      out[i] = (raw > 32767 ? raw - 65536 : raw) / 32768.0;
    }
    return out;
  }

  static List<double> _preEmphasise(List<double> x) {
    // Process right-to-left to avoid needing a copy.
    final y = List<double>.from(x);
    for (int i = y.length - 1; i > 0; i--) {
      y[i] -= _preEmph * y[i - 1];
    }
    return y;
  }

  static List<double> _hammingWindow() {
    return _hamming ??= List<double>.generate(
      _frameSize,
      (n) => 0.54 - 0.46 * math.cos(2.0 * math.pi * n / (_frameSize - 1)),
    );
  }

  static List<List<double>> _melFilterbank() {
    if (_filterbank != null) return _filterbank!;

    double hzToMel(double hz) =>
        2595.0 * math.log(1.0 + hz / 700.0) / math.ln10;
    double melToHz(double mel) =>
        700.0 * (math.pow(10.0, mel / 2595.0) - 1.0);

    final lowMel  = hzToMel(80.0);
    final highMel = hzToMel(sampleRate / 2.0);
    final step    = (highMel - lowMel) / (numFilters + 1);
    final mel     = List<double>.generate(numFilters + 2, (i) => lowMel + i * step);
    final hz      = mel.map(melToHz).toList();
    final bins    = hz
        .map((f) => ((_fftSize + 1) * f / sampleRate).floor())
        .toList();

    final specLen = _fftSize ~/ 2 + 1;
    _filterbank = List<List<double>>.generate(numFilters, (m) {
      final f = List<double>.filled(specLen, 0.0);
      final lo = bins[m], mid = bins[m + 1], hi = bins[m + 2];
      for (int k = lo; k < mid && k < specLen; k++) {
        if (mid > lo) f[k] = (k - lo) / (mid - lo).toDouble();
      }
      for (int k = mid; k < hi && k < specLen; k++) {
        if (hi > mid) f[k] = (hi - k) / (hi - mid).toDouble();
      }
      return f;
    });
    return _filterbank!;
  }

  /// In-place Cooley-Tukey FFT; [re] and [im] must have length = power of 2.
  static void _fft(List<double> re, List<double> im) {
    final n = re.length;
    // Bit-reversal permutation.
    for (int i = 1, j = 0; i < n; i++) {
      int bit = n >> 1;
      for (; j & bit != 0; bit >>= 1) {
        j ^= bit;
      }
      j ^= bit;
      if (i < j) {
        double t = re[i]; re[i] = re[j]; re[j] = t;
        t = im[i]; im[i] = im[j]; im[j] = t;
      }
    }
    // Butterfly stages.
    for (int len = 2; len <= n; len <<= 1) {
      final ang  = -2.0 * math.pi / len;
      final cosA = math.cos(ang);
      final sinA = math.sin(ang);
      for (int i = 0; i < n; i += len) {
        double wrRe = 1.0, wrIm = 0.0;
        for (int j = 0; j < len >> 1; j++) {
          final uRe = re[i + j], uIm = im[i + j];
          final h   = i + j + (len >> 1);
          final vRe = re[h] * wrRe - im[h] * wrIm;
          final vIm = re[h] * wrIm + im[h] * wrRe;
          re[i + j] = uRe + vRe;  im[i + j] = uIm + vIm;
          re[h]     = uRe - vRe;  im[h]     = uIm - vIm;
          final nx = wrRe * cosA - wrIm * sinA;
          wrIm = wrRe * sinA + wrIm * cosA;
          wrRe = nx;
        }
      }
    }
  }

  /// Orthonormal DCT-II of [x]; returns the first [numC] coefficients.
  static List<double> _dct(List<double> x, int numC) {
    final n = x.length;
    return List<double>.generate(numC, (k) {
      var sum = 0.0;
      for (int i = 0; i < n; i++) {
        sum += x[i] * math.cos(math.pi * k * (2 * i + 1) / (2.0 * n));
      }
      // Orthonormal scaling: c[0] uses 1/sqrt(N), c[k>0] uses sqrt(2/N).
      return k == 0
          ? sum * math.sqrt(1.0 / n)
          : sum * math.sqrt(2.0 / n);
    });
  }
}

// ── DTW matcher ───────────────────────────────────────────────────────────────

class DtwMatcher {
  DtwMatcher._();

  /// Standard DTW distance between MFCC sequences [query] and [ref].
  ///
  /// Returns the accumulated Euclidean path cost normalised by (|query|+|ref|).
  /// Lower = better match. Returns [double.infinity] if either sequence is empty.
  static double distance(List<List<double>> query, List<List<double>> ref) {
    if (query.isEmpty || ref.isEmpty) return double.infinity;
    final n = query.length, m = ref.length;

    final dtw = List<List<double>>.generate(
      n, (_) => List<double>.filled(m, double.infinity),
    );
    dtw[0][0] = _euclidean(query[0], ref[0]);
    for (int i = 1; i < n; i++) {
      dtw[i][0] = dtw[i - 1][0] + _euclidean(query[i], ref[0]);
    }
    for (int j = 1; j < m; j++) {
      dtw[0][j] = dtw[0][j - 1] + _euclidean(query[0], ref[j]);
    }
    for (int i = 1; i < n; i++) {
      for (int j = 1; j < m; j++) {
        dtw[i][j] = _euclidean(query[i], ref[j]) +
            math.min(dtw[i - 1][j],
                math.min(dtw[i][j - 1], dtw[i - 1][j - 1]));
      }
    }
    return dtw[n - 1][m - 1] / (n + m);
  }

  /// Maps a DTW [distance] to a pronunciation score in [0.0, 1.0].
  ///
  /// score = exp(−distance / scale). Lower distance → higher score.
  ///
  // TODO(sorcerer): calibrate [scale] against reference recordings.
  // 10.0 is a placeholder; measure typical MFCC-DTW distances for correct
  // and incorrect pronunciations of the five incantation words at 16 kHz.
  static double score(double distance, {double scale = 10.0}) {
    if (!distance.isFinite) return 0.0;
    return math.exp(-distance / scale).clamp(0.0, 1.0);
  }

  /// Corner-anchored DTW between [query] and [ref], returning both the
  /// accumulated path cost and the path's step count (length in cells).
  ///
  /// Used by IncantationRecallScorer to derive a
  /// length-normalized (cost / steps) local match quality — accumulated
  /// cost alone rises with path length (more warping/more frames), which
  /// would penalize slower deliveries even when every frame matches well.
  /// Dividing by steps removes that bias. Not used by [distance]/[score]
  /// above, which real Sorcerer-mode casting depends on unchanged.
  static ({double cost, int steps}) distanceWithSteps(
    List<List<double>> query,
    List<List<double>> ref,
  ) {
    if (query.isEmpty || ref.isEmpty) return (cost: double.infinity, steps: 1);
    final n = query.length, m = ref.length;

    final dtw = List<List<double>>.generate(
      n, (_) => List<double>.filled(m, double.infinity),
    );
    final steps = List<List<int>>.generate(n, (_) => List<int>.filled(m, 1));

    dtw[0][0] = _euclidean(query[0], ref[0]);
    for (int i = 1; i < n; i++) {
      dtw[i][0] = dtw[i - 1][0] + _euclidean(query[i], ref[0]);
      steps[i][0] = steps[i - 1][0] + 1;
    }
    for (int j = 1; j < m; j++) {
      dtw[0][j] = dtw[0][j - 1] + _euclidean(query[0], ref[j]);
      steps[0][j] = steps[0][j - 1] + 1;
    }
    for (int i = 1; i < n; i++) {
      for (int j = 1; j < m; j++) {
        final up = dtw[i - 1][j], left = dtw[i][j - 1], diag = dtw[i - 1][j - 1];
        final best = math.min(up, math.min(left, diag));
        dtw[i][j] = _euclidean(query[i], ref[j]) + best;
        steps[i][j] = 1 +
            (best == diag ? steps[i - 1][j - 1] : (best == up ? steps[i - 1][j] : steps[i][j - 1]));
      }
    }
    return (cost: dtw[n - 1][m - 1], steps: steps[n - 1][m - 1]);
  }

  static double _euclidean(List<double> a, List<double> b) {
    var sum = 0.0;
    final len = math.min(a.length, b.length);
    for (int i = 0; i < len; i++) {
      final d = a[i] - b[i];
      sum += d * d;
    }
    return math.sqrt(sum);
  }
}
