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
// Also shipped (2026-07-16): PerUserEnrolledTemplateSource — the player's
// own recorded voice as the reference template, falling back to the Piper
// voice per-word until enrolled. Built because offline measurement showed
// the DTW metric's contrastive ranking is reliable same-voice (5/5) but
// not cross-voice (2/5) — see docs/M4_findings.md 2026-07-16 and
// vocal_enrollment.dart.
//
// Deliberately NOT built yet (fast-follow, pending playtest data):
//   - MultiVoiceTemplateSource — same phoneme input through several Piper
//     voice models, to average out single-voice speaker bias for players
//     who haven't enrolled.

import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import '../sorcerer/vocal_score.dart';
import 'latin_phonemes.dart';
import 'vocal_enrollment.dart';

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

/// [VocalTemplateSource] backed by the player's own enrolled recordings
/// (see vocal_enrollment.dart for why same-voice templates are load-bearing
/// for word discrimination), falling back to [fallback] (the Piper voice)
/// per-word until that word is enrolled.
///
/// Not cached across enrollments: call [invalidate] after saving or
/// clearing an enrollment so the next beginFormula picks up the new
/// template.
class PerUserEnrolledTemplateSource implements VocalTemplateSource {
  PerUserEnrolledTemplateSource({
    required this.enrollment,
    VocalTemplateSource? fallback,
  }) : fallback = fallback ?? SingleVoiceTemplateSource();

  final VocalEnrollment enrollment;
  final VocalTemplateSource fallback;

  final Map<VocalWord, VocalTemplate> _cache = {};

  void invalidate() => _cache.clear();

  @override
  Future<VocalTemplate> templateFor(VocalWord word) async {
    final cached = _cache[word];
    if (cached != null) return cached;

    final frames = await enrollment.loadFrames(word);
    if (frames == null) return fallback.templateFor(word);

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
