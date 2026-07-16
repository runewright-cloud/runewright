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
/// sequence and the frame indices where each checkpoint ends.
///
/// One checkpoint per whole word, not per phoneme — see file header on
/// [SingleVoiceTemplateSource.templateFor] for why per-phoneme segmentation
/// was tried and reverted.
class VocalTemplate {
  const VocalTemplate({
    required this.word,
    required this.mfccFrames,
    required this.checkpointFrameIndices,
    required this.checkpointLabels,
  });

  final VocalWord word;

  /// One 13-element MFCC vector per ~10 ms frame (MfccExtractor convention).
  final List<List<double>> mfccFrames;

  /// Frame index (inclusive) where each checkpoint completes, in order,
  /// length == checkpointLabels.length. Always length 1 (the whole word) in
  /// the shipped [SingleVoiceTemplateSource] — kept as a list, not a single
  /// int, so a future forced-alignment-based source could reintroduce real
  /// sub-word checkpoints without changing [StreamingPhonemeScorer].
  final List<int> checkpointFrameIndices;

  /// Human-readable label per checkpoint, for feedback UI.
  final List<String> checkpointLabels;
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
///
/// One checkpoint per whole word, not per phoneme (2026-07-10, reverted
/// from an earlier per-phoneme design). [LatinPhonemes]' weight table gave
/// static, duration-proportional boundaries within a word -- not real
/// forced alignment -- and on real speech this let the pointer race ahead
/// mid-word (e.g. crossing "terra"'s first checkpoint on just "ter", then
/// scoring the trailing "ra" against the *next* word's first checkpoint).
/// Whole-word checkpoints structurally remove that failure mode: there's
/// nothing to race ahead of within a word anymore. Matches the granularity
/// real Sorcerer-mode casting already uses successfully (one score per
/// spoken word). [LatinPhonemes] itself is kept for its G2P derivation
/// trail and as a base for a real future forced-alignment source.
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

    final template = VocalTemplate(
      word: word,
      mfccFrames: frames,
      checkpointFrameIndices: [frames.length - 1],
      checkpointLabels: [word.name],
    );
    _cache[word] = template;
    return template;
  }
}
