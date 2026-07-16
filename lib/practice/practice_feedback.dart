// SPDX-License-Identifier: GPL-3.0-or-later
//
// practice_feedback.dart — CheckpointClarity and PracticeFeedback value
// types produced by StreamingPhonemeScorer on formula completion.
//
// Deliberately richer than real-play feedback (pedagogical payoff) and
// deliberately NOT wired to the real mana-cost formula — timeToCompletion
// and loudness are informational only; see streaming_phoneme_scorer.dart.

import 'dart:math' as math;

/// Per-checkpoint (currently: per whole word) result.
class CheckpointClarity {
  const CheckpointClarity({
    required this.wordIndex,
    required this.label,
    required this.normalizedQuality,
    required this.dwellMs,
  });

  /// Index into the formula's word list this checkpoint belongs to.
  final int wordIndex;

  /// Human-readable checkpoint label — currently always the spoken word
  /// itself (e.g. "terra"), since checkpoints are whole-word; see
  /// vocal_template_source.dart for why sub-word phoneme labels were
  /// reverted.
  final String label;

  /// Length-normalized DTW cost-per-step at the moment this checkpoint
  /// cleared (lower = cleaner match). Not itself a 0-1 score — see
  /// [clarity01] for the display-friendly mapping.
  final double normalizedQuality;

  /// Wall-clock time spent on this checkpoint (from the previous
  /// checkpoint's crossing to this one's), informational.
  final int dwellMs;

  /// Maps [normalizedQuality] to a friendlier 0.0-1.0 "clarity" figure via
  /// the same exp(-x/scale) shape DtwMatcher.score uses elsewhere, so the
  /// number reads the same way pronunciation confidence already does.
  double get clarity01 {
    if (!normalizedQuality.isFinite) return 0.0;
    return math.exp(-normalizedQuality / 10.0).clamp(0.0, 1.0);
  }
}

/// Full feedback for one completed (or abandoned) practice formula.
class PracticeFeedback {
  const PracticeFeedback({
    required this.checkpoints,
    required this.timeToCompletionMs,
    required this.averageLoudness,
  });

  /// One entry per phoneme checkpoint, in formula order.
  final List<CheckpointClarity> checkpoints;

  /// Total wall-clock time from formula start to the final checkpoint
  /// clearing. Informational only — never gates completion or feeds any
  /// score; see the no-static-window / rate-invariance requirement in
  /// streaming_phoneme_scorer.dart.
  final int timeToCompletionMs;

  /// RMS-based loudness over the whole capture, 0.0-1.0ish. Informational
  /// and non-gating — the real-mode volume/crescendo mechanic is out of
  /// scope for Practice Mode.
  final double averageLoudness;

  /// The checkpoint that took the longest to clear — "where the pointer
  /// stalled" — or null if there were no checkpoints.
  CheckpointClarity? get stallPoint {
    if (checkpoints.isEmpty) return null;
    return checkpoints.reduce((a, b) => b.dwellMs > a.dwellMs ? b : a);
  }
}
