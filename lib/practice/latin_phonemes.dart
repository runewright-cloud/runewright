// SPDX-License-Identifier: GPL-3.0-or-later
//
// latin_phonemes.dart — hardcoded per-word phoneme sequence for the five
// Sorcerer-mode incantation words (VocalWord), for Practice Mode only.
//
// The vocabulary is closed (5 words, never extended at runtime), so this is
// a lookup table, not a general Italian G2P engine. Each entry was derived
// by running the actual Italian voice/phonemizer Practice Mode's trainer
// audio is rendered with (espeak-ng -v it, bundled inside the Piper release
// used by scripts/generate_practice_assets.dart), not hand-guessed:
//
//   $ espeak-ng --path=<piper>/espeak-ng-data -v it --ipa -q ignis    -> ˈiɲɲis
//   $ espeak-ng --path=<piper>/espeak-ng-data -v it --ipa -q aer      -> aˈɛr
//   $ espeak-ng --path=<piper>/espeak-ng-data -v it --ipa -q aqua     -> ˈakwa
//   $ espeak-ng --path=<piper>/espeak-ng-data -v it --ipa -q terra    -> tˈɛrɾa
//   $ espeak-ng --path=<piper>/espeak-ng-data -v it --ipa -q finitus  -> finˈitʊs
//
// Two deliberate non-classical outcomes, both accepted per design brief
// ("a Latin professor would frown; that's fine"):
//   - ignis: Italian orthographic "gn" palatalizes and geminates to /ɲː/,
//     not classical hard /gn/ — "EE-nyees", not "IG-nis". The trainer clip
//     and the scorer target both come from this same phonemization (see
//     scripts/generate_practice_assets.dart), so they can't silently diverge.
//   - finitus: the "-us" ending gets the Italian near-close back vowel /ʊ/
//     (an English-flavoured letter-to-sound fallback for an un-Italian
//     word-final cluster) rather than pure Italian /u/. Left as-is.
//
// [PracticePhoneme.weight] is a coarse relative-duration heuristic (vowel
// ~1.0, plosive ~0.5, nasal/liquid ~0.6-0.8, geminate ~1.3-1.4) used only to
// divide a word's reference MFCC frames into checkpoint segments
// proportionally rather than uniformly by count. It is not measured
// acoustic-phone duration — this is a practice-tool approximation, not a
// forced-alignment ground truth.

import '../sorcerer/vocal_score.dart';

class PracticePhoneme {
  const PracticePhoneme(this.label, this.weight);

  /// Human-readable IPA-ish label shown in feedback (e.g. "which part of
  /// 'aqua' stalled" -> shows this label, not a raw frame index).
  final String label;

  /// Coarse relative-duration weight; see file header.
  final double weight;
}

class LatinPhonemes {
  LatinPhonemes._();

  static const Map<VocalWord, List<PracticePhoneme>> _table = {
    VocalWord.ignis: [
      PracticePhoneme('i', 1.0),
      PracticePhoneme('ɲː', 1.4),
      PracticePhoneme('i', 1.0),
      PracticePhoneme('s', 0.8),
    ],
    VocalWord.aer: [
      PracticePhoneme('a', 1.0),
      PracticePhoneme('ɛ', 1.0),
      PracticePhoneme('r', 0.6),
    ],
    VocalWord.aqua: [
      PracticePhoneme('a', 1.0),
      PracticePhoneme('k', 0.5),
      PracticePhoneme('w', 0.5),
      PracticePhoneme('a', 1.0),
    ],
    VocalWord.terra: [
      PracticePhoneme('t', 0.4),
      PracticePhoneme('ɛ', 1.0),
      PracticePhoneme('rɾ', 1.3),
      PracticePhoneme('a', 1.0),
    ],
    VocalWord.finitus: [
      PracticePhoneme('f', 0.6),
      PracticePhoneme('i', 1.0),
      PracticePhoneme('n', 0.6),
      PracticePhoneme('i', 1.0),
      PracticePhoneme('t', 0.4),
      PracticePhoneme('ʊ', 1.0),
      PracticePhoneme('s', 0.8),
    ],
  };

  /// The phoneme sequence for [word], in order.
  static List<PracticePhoneme> phonemesFor(VocalWord word) => _table[word]!;

  /// Cumulative weight fractions in (0.0, 1.0], one per phoneme boundary,
  /// e.g. [0.35, 0.7, 1.0] for a 3-phoneme word with equal weights. Used to
  /// map a word's reference MFCC frame count to checkpoint frame indices
  /// (see VocalTemplate.checkpointFrameIndices in vocal_template_source.dart).
  static List<double> cumulativeWeightFractions(VocalWord word) {
    final phonemes = phonemesFor(word);
    final total = phonemes.fold<double>(0.0, (sum, p) => sum + p.weight);
    var running = 0.0;
    return [
      for (final p in phonemes) (running += p.weight) / total,
    ];
  }
}
