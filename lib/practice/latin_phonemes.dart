// SPDX-License-Identifier: GPL-3.0-or-later
//
// latin_phonemes.dart — hardcoded per-word phoneme sequence for the five
// Sorcerer-mode incantation words (VocalWord), for Practice Mode only.
//
// The vocabulary is closed (5 words, never extended at runtime), so this is
// a lookup table, not a general G2P engine. Each entry was derived by
// running the actual English voice/phonemizer Practice Mode's trainer audio
// is rendered with (espeak-ng -v en-us, bundled inside the Piper release
// used by scripts/generate_practice_assets.dart), not hand-guessed:
//
//   $ espeak-ng --path=<piper>/espeak-ng-data -v en-us --ipa -q ignisse  -> ɪɡnˈɪs
//   $ espeak-ng --path=<piper>/espeak-ng-data -v en-us --ipa -q ventus   -> vˈɛntəs
//   $ espeak-ng --path=<piper>/espeak-ng-data -v en-us --ipa -q aqua     -> ˈækwə
//   $ espeak-ng --path=<piper>/espeak-ng-data -v en-us --ipa -q terra    -> tˈɛɹə
//   $ espeak-ng --path=<piper>/espeak-ng-data -v en-us --ipa -q finitus  -> fˈɪnɪɾəs
//
// Switched from Italian to English 2026-07-22 per Soren's direction: most
// players will map Latin spelling onto English pronunciation habits anyway
// (that's what their speech naturally does), so the trainer should teach
// the sound they'll actually produce rather than one they'd have to
// suppress. See docs/M4_findings.md for the full rationale.
//
// ignis is phonemized from "ignisse", NOT the literal word — a deliberate
// spelling override (kTtsTextOverride in scripts/generate_practice_assets.dart),
// not a natural rule outcome. Plain "ignis" gives /ɪɡnˈiz/ ("IG-neez",
// word-final "s" voiced to /z/ the way English does "his") — reported
// 2026-07-22 as reading like "digging knees." Iterated twice: first target
// was "like ignite but ending in /s/" ("ignyce" -> /ˈɪɡnaɪs/, stress
// wouldn't shift off the first syllable); revised target was "last syllable
// rhymes with kiss" (/kˈɪs/) — "ignisse" -> /ɪɡnˈɪs/ ("ig-NISS") hits that
// exactly and, as a bonus, lands stress on the second syllable. Players
// still see/say "ignis" everywhere else; only the TTS input string differs.
//
// Other notable non-classical outcomes from the en-us letter-to-sound rules
// (accepted, same spirit — "a Latin professor would frown; that's fine"):
//   - Unstressed word-final "-us"/"-a" reduce to schwa /ə/ across all four
//     affected words (ventus, aqua, terra, finitus) — standard English
//     vowel reduction, matching how "campus" or "aqua" (already an English
//     loanword) are actually said.
//   - finitus: the medial "t" flaps to /ɾ/ between vowels ("fih-NIH-ruhs"),
//     the same rule that makes American "water" -> /wɔɾɚ/. The trainer clip
//     and the scorer target both come from this same phonemization (see
//     scripts/generate_practice_assets.dart), so they can't silently diverge.
//
// [PracticePhoneme.weight] is a coarse relative-duration heuristic (vowel
// ~1.0, reduced/schwa vowel ~0.7, plosive/flap ~0.4-0.5, nasal/liquid
// ~0.6-0.8) used only to divide a word's reference MFCC frames into
// checkpoint segments proportionally rather than uniformly by count. It is
// not measured acoustic-phone duration — this is a practice-tool
// approximation, not a forced-alignment ground truth.

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
      PracticePhoneme('ɪ', 1.0),
      PracticePhoneme('ɡ', 0.5),
      PracticePhoneme('n', 0.6),
      PracticePhoneme('ɪ', 1.0),
      PracticePhoneme('s', 0.8),
    ],
    VocalWord.ventus: [
      PracticePhoneme('v', 0.6),
      PracticePhoneme('ɛ', 1.0),
      PracticePhoneme('n', 0.6),
      PracticePhoneme('t', 0.4),
      PracticePhoneme('ə', 0.7),
      PracticePhoneme('s', 0.8),
    ],
    VocalWord.aqua: [
      PracticePhoneme('æ', 1.0),
      PracticePhoneme('k', 0.5),
      PracticePhoneme('w', 0.5),
      PracticePhoneme('ə', 0.7),
    ],
    VocalWord.terra: [
      PracticePhoneme('t', 0.4),
      PracticePhoneme('ɛ', 1.0),
      PracticePhoneme('ɹ', 0.6),
      PracticePhoneme('ə', 0.7),
    ],
    VocalWord.finitus: [
      PracticePhoneme('f', 0.6),
      PracticePhoneme('ɪ', 1.0),
      PracticePhoneme('n', 0.6),
      PracticePhoneme('ɪ', 1.0),
      PracticePhoneme('ɾ', 0.4),
      PracticePhoneme('ə', 0.7),
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
