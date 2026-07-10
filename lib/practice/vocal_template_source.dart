// SPDX-License-Identifier: GPL-3.0-or-later
//
// vocal_template_source.dart — VocalTemplate value type and the thin,
// swappable VocalTemplateSource abstraction in front of
// StreamingPhonemeScorer.
//
// Shipped now: SingleVoiceTemplateSource, one Piper voice (it_IT-paola-medium)
// per VocalWord, generated offline by scripts/generate_practice_assets.dart
// from the exact same render used for the trainer clip (see that script's
// header and latin_phonemes.dart's file header for the derivation trail).
//
// Deliberately NOT built yet (fast-follow, pending playtest data):
//   - MultiVoiceTemplateSource — same phoneme input through several Piper
//     voice models, to average out single-voice speaker bias (MFCC encodes
//     timbre/vocal-tract length, which DTW doesn't correct for; one voice is
//     an *impartial* bias, not one tuned to any player, which is enough for
//     a first playtest — see docs/M4_findings.md).
//   - PerUserEnrolledTemplateSource — record the player's own voice as the
//     reference template. Would remove speaker bias entirely but needs an
//     enrollment flow this pass doesn't build.
// Both would implement [VocalTemplateSource] and slot in without touching
// [StreamingPhonemeScorer].

import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import '../sorcerer/vocal_score.dart';
import 'latin_phonemes.dart';

/// Reference data for scoring one [VocalWord]: the target MFCC frame
/// sequence and the frame indices where each phoneme checkpoint ends.
class VocalTemplate {
  const VocalTemplate({
    required this.word,
    required this.mfccFrames,
    required this.checkpointFrameIndices,
    required this.phonemeLabels,
  });

  final VocalWord word;

  /// One 13-element MFCC vector per ~10 ms frame (MfccExtractor convention).
  final List<List<double>> mfccFrames;

  /// Frame index (inclusive) where each phoneme checkpoint completes, in
  /// order, length == phonemeLabels.length. Derived from
  /// [LatinPhonemes.cumulativeWeightFractions] against [mfccFrames.length]
  /// at load time, not baked into the asset, so retuning the weight table
  /// doesn't require regenerating audio.
  final List<int> checkpointFrameIndices;

  /// Human-readable label per checkpoint, for feedback UI (e.g. "ɲː").
  final List<String> phonemeLabels;
}

/// Supplies the reference [VocalTemplate] for a [VocalWord].
///
/// Implementations must not be imported by battle-layer code — Practice Mode
/// is consensus-invisible and self-contained under lib/practice/ + lib/ui/.
abstract class VocalTemplateSource {
  Future<VocalTemplate> templateFor(VocalWord word);
}

/// Single-Piper-voice [VocalTemplateSource]. The active implementation for
/// the friends playtest (see docs/M4_findings.md for the reproducibility
/// rationale over a one-off human recording).
class SingleVoiceTemplateSource implements VocalTemplateSource {
  SingleVoiceTemplateSource({
    this.assetDir = 'assets/practice_templates',
  });

  final String assetDir;

  final Map<VocalWord, VocalTemplate> _cache = {};

  @override
  Future<VocalTemplate> templateFor(VocalWord word) async {
    final cached = _cache[word];
    if (cached != null) return cached;

    final raw = await rootBundle.loadString('$assetDir/${word.name}.json');
    final json = jsonDecode(raw) as Map<String, dynamic>;
    final frames = (json['frames'] as List)
        .map((row) => (row as List).map((v) => (v as num).toDouble()).toList())
        .toList();

    final fractions = LatinPhonemes.cumulativeWeightFractions(word);
    final phonemes = LatinPhonemes.phonemesFor(word);
    final indices = [
      for (final f in fractions) (f * frames.length).round().clamp(1, frames.length) - 1,
    ];

    final template = VocalTemplate(
      word: word,
      mfccFrames: frames,
      checkpointFrameIndices: indices,
      phonemeLabels: [for (final p in phonemes) p.label],
    );
    _cache[word] = template;
    return template;
  }
}
