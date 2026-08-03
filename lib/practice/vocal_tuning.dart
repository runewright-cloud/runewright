// SPDX-License-Identifier: GPL-3.0-or-later
//
// vocal_tuning.dart — VocalTuning: a single player-facing "strictness" dial
// (0.0 easiest .. 1.0 strictest) mapping to StreamingPhonemeScorer's three
// raw constants (checkpointFloor, contrastiveMargin, debounceFrames).
//
// Why one dial instead of three (2026-07-22): the three constants were
// tuned once against Piper synthetic voices; multi-exemplar real-voice data
// shows the right operating point is voice- and context-dependent (quiet
// solo practice vs a noisy multi-caster battle) and is best found
// empirically during playtesting rather than re-guessed offline. A single
// slider ("try different levels till something feels right") is what you
// hand a playtester — three abstract DTW knobs are not.
//
// Persisted at <app documents>/vocal_tuning.json so the Settings screen and
// Practice screen's own slider (both expose it, per Soren's 2026-07-22 ask)
// stay in sync regardless of which one last changed it.
//
// 1.0 (strictest) reproduces the original shipped constants exactly, so an
// untouched dial changes nothing relative to pre-slider behaviour. 0.0
// (easiest) is deliberately forgiving — per Soren's "err on the too easy
// side a little" direction, since battle casting may be noisy/simultaneous.

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'streaming_phoneme_scorer.dart';

class VocalTuning {
  VocalTuning(double strictness) : strictness = strictness.clamp(0.0, 1.0);

  /// 0.0 (easiest) .. 1.0 (strictest, the original shipped operating point).
  final double strictness;

  /// Starting point for the playtest: medium, erring slightly easy — see
  /// file header. Soren adjusts from here via the slider during playtests;
  /// this is a starting point, not a conclusion.
  static const double defaultStrictness = 0.45;

  // Interpolation endpoints. The STRICT end reproduces the pre-slider
  // shipped defaults exactly (kDefaultCheckpointFloor/kDefaultContrastive-
  // Margin/kDefaultDebounceFrames, streaming_phoneme_scorer.dart) so turning
  // the dial to max is a no-op. The EASY end is deliberately forgiving:
  // measured 2026-07-22 that correct multi-exemplar same-voice attempts can
  // lead their nearest wrong-word competitor by as little as +0.05-0.4, so
  // margin 0.3 (not lower) still discriminates while giving real headroom;
  // floor 9.5 and debounce 4 similarly loosen the anti-babble cap and
  // shorten the sustained-clearance window without removing them outright.
  static const double _strictFloor = kDefaultCheckpointFloor;
  static const double _easyFloor = 9.5;
  static const double _strictMargin = kDefaultContrastiveMargin;
  static const double _easyMargin = 0.3;
  static const int _strictDebounce = kDefaultDebounceFrames;
  static const int _easyDebounce = 4;

  double get floor => _lerp(_easyFloor, _strictFloor, strictness);
  double get margin => _lerp(_easyMargin, _strictMargin, strictness);
  int get debounceFrames =>
      (_easyDebounce + (_strictDebounce - _easyDebounce) * strictness).round();

  static double _lerp(double a, double b, double t) => a + (b - a) * t;

  static Future<VocalTuning> load() async {
    try {
      final file = await _file();
      if (!file.existsSync()) return VocalTuning(defaultStrictness);
      final json =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final value = (json['strictness'] as num?)?.toDouble();
      return VocalTuning(value ?? defaultStrictness);
    } catch (_) {
      return VocalTuning(defaultStrictness);
    }
  }

  Future<void> save() async {
    final file = await _file();
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode({'strictness': strictness}));
  }

  static Future<File> _file() async {
    final docs = await getApplicationDocumentsDirectory();
    return File('${docs.path}/vocal_tuning.json');
  }
}
