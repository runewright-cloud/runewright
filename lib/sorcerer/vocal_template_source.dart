// SPDX-License-Identifier: GPL-3.0-or-later
//
// vocal_template_source.dart — VocalTemplate value type and the thin,
// swappable VocalTemplateSource abstraction in front of
// IncantationRecallScorer.
//
// Shipped now: SingleVoiceTemplateSource, one Piper voice (en_US-lessac-medium)
// per VocalSlot, generated offline by scripts/generate_practice_assets.dart
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

import 'vocal_slot.dart';
import 'vocal_enrollment.dart';
import 'vocabulary_profile.dart';

/// Reference data for scoring one [VocalSlot]: the target MFCC frame
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

  final VocalSlot word;

  /// One 13-element MFCC vector per ~10 ms frame (MfccExtractor convention).
  final List<List<double>> mfccFrames;

  /// Frame index (inclusive) where each checkpoint completes, in order,
  /// length == checkpointLabels.length. Always length 1 (the whole word) in
  /// the shipped [SingleVoiceTemplateSource] — kept as a list, not a single
  /// int, so a future forced-alignment-based source could reintroduce real
  /// sub-word checkpoints without changing the scorer.
  final List<int> checkpointFrameIndices;

  /// Human-readable label per checkpoint, for feedback UI.
  final List<String> checkpointLabels;
}

/// Supplies the reference [VocalTemplate] for a [VocalSlot].
///
/// Implementations must not be imported by battle-layer code — Practice Mode
/// is consensus-invisible and self-contained under lib/practice/ + lib/ui/.
abstract class VocalTemplateSource {
  Future<VocalTemplate> templateFor(VocalSlot word);

  /// The full exemplar SET for [word] — the references the scorer takes the
  /// min DTW distance over (2026-07-22: a set of the
  /// speaker's own takes discriminates confusable words where a single
  /// brittle exemplar can't; see docs/M4_findings.md). Battle-portable: the
  /// whole-utterance path can call this and min over the same set.
  ///
  /// Default: the single [templateFor] template as a one-element list, so
  /// single-template sources (e.g. [SingleVoiceTemplateSource]) need no
  /// change.
  Future<List<VocalTemplate>> templatesFor(VocalSlot word) async =>
      [await templateFor(word)];
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

  final Map<VocalSlot, VocalTemplate> _cache = {};

  @override
  Future<VocalTemplate> templateFor(VocalSlot word) async {
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

  @override
  Future<List<VocalTemplate>> templatesFor(VocalSlot word) async =>
      [await templateFor(word)];
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
    this.vocabulary,
    VocalTemplateSource? fallback,
  }) : fallback = fallback ?? SingleVoiceTemplateSource();

  final VocalEnrollment enrollment;
  final VocalTemplateSource fallback;

  /// The player's CURRENT words. When set, a slot's enrolled takes are used
  /// only if they were recorded for the word the profile now names.
  ///
  /// This is the read half of atomic re-keying (§8.8). Committing a new
  /// vocabulary touches several enrollment files plus the profile, so a crash
  /// part-way could leave a slot holding audio of the old word under the new
  /// word's name. Scoring against that would cost the player mana every cast,
  /// for a reason invisible to them. Falling back to the bundled default is
  /// worse at recognition but honest about it — and it self-heals the moment
  /// they re-record.
  ///
  /// Null disables the check (Practice Mode's pre-§8 enrollment screen, and
  /// any file written before labels existed).
  final VocabularyProfile? vocabulary;

  final Map<VocalSlot, List<VocalTemplate>> _cache = {};

  void invalidate() => _cache.clear();

  VocalTemplate _templateFrom(VocalSlot word, List<List<double>> frames) =>
      VocalTemplate(
        word: word,
        mfccFrames: frames,
        checkpointFrameIndices: [frames.length - 1],
        checkpointLabels: [word.name],
      );

  /// The player's enrolled take set for [word], or the fallback's set when
  /// that word isn't enrolled yet. Cached until [invalidate].
  @override
  Future<List<VocalTemplate>> templatesFor(VocalSlot word) async {
    final cached = _cache[word];
    if (cached != null) return cached;

    final takes = _isStale(word) ? null : await enrollment.loadTakes(word);
    final templates = takes == null
        ? await fallback.templatesFor(word)
        : [for (final frames in takes) _templateFrom(word, frames)];
    _cache[word] = templates;
    return templates;
  }

  /// Whether [word]'s enrolled takes were recorded for a DIFFERENT word than
  /// the profile now names — see [vocabulary].
  ///
  /// An unlabelled file is trusted: it predates labels, so there is no
  /// evidence against it, and distrusting it would silently discard every
  /// recording made before this check existed.
  bool _isStale(VocalSlot word) {
    final profile = vocabulary;
    if (profile == null) return false;
    final recorded = enrollment.labelFor(word);
    return recorded != null && recorded != profile.labelFor(word);
  }

  /// Back-compat single template: the first enrolled take (or fallback).
  @override
  Future<VocalTemplate> templateFor(VocalSlot word) async =>
      (await templatesFor(word)).first;
}
