// SPDX-License-Identifier: GPL-3.0-or-later
//
// incantation_recall_scorer.dart — decides WHICH slot the caster spoke at each
// position of an incantation.
//
// VOCAL_RECALL_PLAN.md §9.4. This replaces the per-word capture that scored
// pronunciation quality, and the problem it solves is a different, easier one:
// not "how well was that said" (continuous regression with no ground truth)
// but "which of these four was that" (closed-vocabulary spotting against a
// known expected count). The vocabulary is 4 for an element position and 2 for
// the opener.
//
// ── Why the whole utterance, not a stream ─────────────────────────────────
//
// Capture is press-and-hold: the caster holds the cast button, chants
// `OPENER + trajectory`, and release ends the window. So by the time anything
// needs deciding, the ENTIRE utterance is in hand — there is no reason to
// commit to a per-word decision while audio is still arriving, and every
// reason not to. Segmenting the whole recording lets the segmenter use the
// expected word count as a constraint, which is the single most useful piece
// of information available: the device always knows how many words its own
// spell requires.
//
// The alternative — a fixed window per word, as the old capture used — does
// not survive contact with the real maximum. FormulaTracker commits up to one
// activation per generation, so a tier-48 spell is 49 words; at 2.5 s each
// that is over two minutes of standing still per cast.
//
// ── Alignment never silently re-flows ─────────────────────────────────────
//
// If the segmenter finds a different number of words than expected, the
// mismatch is NOT repaired by re-aligning. Extra segments are dropped and
// missing positions become null ("no utterance"), which scores exactly as a
// wrong word. Re-flowing would let one dropped syllable quietly shift every
// later position onto its neighbour, turning a clean recital into a blank one
// for reasons no player could see — and the caster cannot appeal, because the
// peer only ever sees the decisions, never the audio.

import 'dart:typed_data';

import 'incantation_recall.dart';
import 'mfcc.dart';
import 'vocal_slot.dart';
import 'vocal_template_source.dart';

/// Decides the spoken slot at each position of one held incantation.
class IncantationRecallScorer {
  IncantationRecallScorer({
    required this.templateSource,
    this.voicedFloorRatio = defaultVoicedFloorRatio,
    this.minWordFrames = defaultMinWordFrames,
    this.minGapFrames = defaultMinGapFrames,
  });

  final VocalTemplateSource templateSource;

  /// A frame counts as voiced when its log-energy sits this far above the
  /// recording's own floor, as a fraction of its dynamic range.
  ///
  /// Relative rather than absolute on purpose: an absolute threshold is a
  /// microphone-gain and room-volume setting, which is exactly what §2 says
  /// this redesign should stop scoring people on.
  final double voicedFloorRatio;

  /// Shortest run of voiced frames that can be a word (~120 ms).
  final int minWordFrames;

  /// Silence needed to split two words (~80 ms). Below this, a brief stop
  /// inside a word does not cut it in two.
  final int minGapFrames;

  static const double defaultVoicedFloorRatio = 0.22;
  static const int defaultMinWordFrames = 12;
  static const int defaultMinGapFrames = 8;

  /// Exemplar frame sets per slot, loaded once per incantation.
  Map<VocalSlot, List<List<List<double>>>> _vocabulary = const {};

  /// Loads the templates for every slot. Call once before [score].
  ///
  /// Loads ALL slots, not just the expected ones: deciding a position means
  /// ranking it against its whole candidate set, so the competitors matter as
  /// much as the target.
  Future<void> load() async {
    final vocabulary = <VocalSlot, List<List<List<double>>>>{};
    for (final slot in VocalSlot.values) {
      vocabulary[slot] = [
        for (final template in await templateSource.templatesFor(slot))
          normalise(template.mfccFrames),
      ];
    }
    _vocabulary = vocabulary;
  }

  /// Decides what [pcm] says, given the [expectedElements] this spell needs.
  ///
  /// [expectedElements] supplies only the COUNT and the candidate sets — the
  /// expected slots themselves are never compared here. Scoring happens later,
  /// against the certified trajectory (IncantationRecall.tallyAgainst); if this
  /// method peeked at the answer it would be marking its own homework.
  IncantationRecall score(Uint8List pcm, {required int expectedElements}) {
    final frames = MfccExtractor.extract(pcm);
    if (frames.isEmpty || _vocabulary.isEmpty) return IncantationRecall.silent;

    final segments = _segment(frames);
    if (segments.isEmpty) return IncantationRecall.silent;

    // Position 0 is the opener; the rest are elements.
    final opener = _bestOf(segments.first, VocalSlot.openers);
    final elements = <VocalSlot?>[
      for (var i = 0; i < expectedElements; i++)
        if (i + 1 < segments.length)
          _bestOf(segments[i + 1], VocalSlot.elements)
        else
          null,
    ];
    return IncantationRecall(opener: opener, elements: elements);
  }

  /// The candidate in [candidates] with the smallest DTW distance to [query],
  /// minimised over that slot's whole exemplar set.
  ///
  /// Min-over-exemplars rather than a single reference: a set of the speaker's
  /// own takes captures their natural variation, where one brittle exemplar
  /// discriminates confusable words badly (docs/M4_findings.md, 2026-07-22).
  VocalSlot? _bestOf(List<List<double>> query, List<VocalSlot> candidates) {
    VocalSlot? best;
    var bestDistance = double.infinity;
    for (final slot in candidates) {
      for (final exemplar in _vocabulary[slot] ?? const []) {
        final d = DtwMatcher.distance(query, exemplar);
        if (d < bestDistance) {
          bestDistance = d;
          best = slot;
        }
      }
    }
    // Per §8.6 the best guess is returned however narrow the win. There is
    // deliberately no "too close to call" state: an ambiguity flag would be
    // self-reported, and it would buy selective opacity — crisp words for
    // accuracy, a declared coin-flip on the casts where hiding a summon pays.
    // Best-guess makes ambiguity price itself at the rate it actually occurs.
    return bestDistance.isFinite ? best : null;
  }

  /// Splits [frames] into voiced runs, each a spoken word.
  List<List<List<double>>> _segment(List<List<double>> frames) {
    // c0 tracks frame log-energy, which is what makes it the cheap voicing
    // signal here — and also why every DTW comparison drops it (an energy
    // coefficient measures loudness, not identity).
    final energies = [for (final f in frames) f.isEmpty ? 0.0 : f[0]];

    // Percentiles, not min/max. Digital silence drives c0 to an extreme
    // outlier, and anchoring the range to it collapses the threshold so far
    // below the real noise floor that EVERY frame reads as voiced — the whole
    // recording becomes one segment and decodes as a single arbitrary word.
    // p10/p90 ignore both tails and track the actual quiet/loud levels.
    final sorted = [...energies]..sort();
    double percentile(double p) =>
        sorted[(p * (sorted.length - 1)).round().clamp(0, sorted.length - 1)];
    final low = percentile(0.10);
    final high = percentile(0.90);
    if (high - low < 1e-9) return const []; // silence, or a constant tone
    final threshold = low + (high - low) * voicedFloorRatio;

    final segments = <List<List<double>>>[];
    var start = -1;
    var lastVoiced = -1;
    var gap = 0;
    for (var i = 0; i < frames.length; i++) {
      if (energies[i] >= threshold) {
        if (start < 0) start = i;
        lastVoiced = i;
        gap = 0;
      } else if (start >= 0) {
        gap++;
        if (gap >= minGapFrames) {
          final end = i - gap + 1;
          if (end - start >= minWordFrames) {
            segments.add(normalise(frames.sublist(start, end)));
          }
          start = -1;
          gap = 0;
        }
      }
    }
    // Close the final run at the last VOICED frame, not at the end of the
    // buffer. A recording ends in silence (the player releases the button
    // after speaking), and measuring to the buffer's end pads that silence
    // onto the last word — enough to push a too-short blip over
    // [minWordFrames] and turn a cough into a word.
    if (start >= 0 && lastVoiced + 1 - start >= minWordFrames) {
      segments.add(normalise(frames.sublist(start, lastVoiced + 1)));
    }
    return segments;
  }

  /// Conditions frames for identity comparison. Applied to BOTH the query and
  /// every template — a mismatch here silently compares different feature
  /// spaces, which is the kind of bug that reads as "the recogniser is bad"
  /// rather than "the recogniser is wrong".
  ///
  /// Two steps, both carried over from the calibrated practice scorer:
  ///   1. Drop c0. It is frame log-energy, so it measures how loudly a word
  ///      was said, not which word it was. Keeping it would score volume,
  ///      which is the thing §2 set out to stop scoring.
  ///   2. Cepstral mean normalisation — subtract each coefficient's mean over
  ///      the segment. This cancels the fixed channel response of the
  ///      microphone and room, which is otherwise a large constant offset
  ///      between a player's live audio and any template.
  static List<List<double>> normalise(List<List<double>> frames) {
    if (frames.isEmpty) return const [];
    final width = frames.first.length - 1;
    if (width <= 0) return const [];
    final means = List<double>.filled(width, 0.0);
    for (final f in frames) {
      for (var i = 0; i < width; i++) {
        means[i] += f[i + 1];
      }
    }
    for (var i = 0; i < width; i++) {
      means[i] /= frames.length;
    }
    return [
      for (final f in frames)
        [for (var i = 0; i < width; i++) f[i + 1] - means[i]],
    ];
  }
}
