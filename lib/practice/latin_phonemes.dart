// SPDX-License-Identifier: GPL-3.0-or-later
//
// latin_phonemes.dart — hardcoded phoneme sequence for the six DEFAULT
// Sorcerer-mode incantation words, one per VocalSlot.
//
// SCOPE (VOCAL_RECALL_PLAN.md §8): this table covers the shipped Latin
// defaults ONLY. Words are now player-chosen, and a custom word has no
// entry here and needs none — templates come from the player's enrolled
// recordings, and VocalTemplate uses whole-word checkpoints
// (vocal_template_source.dart), which need no phoneme segmentation. This
// table is retained for the G2P derivation trail below and as the base for
// a future forced-alignment source; nothing in the scoring path reads it.
//
// The default vocabulary is closed (6 words), so this is a lookup table, not
// a general G2P engine. Each entry was derived by running the actual English
// voice/phonemizer the default templates are rendered with (espeak-ng -v
// en-us, bundled inside the Piper release used by
// scripts/generate_practice_assets.dart), not hand-guessed:
//
//   $ espeak-ng --path=<piper>/espeak-ng-data -v en-us --ipa -q ignisse     -> ɪɡnˈɪs
//   $ espeak-ng --path=<piper>/espeak-ng-data -v en-us --ipa -q ventus      -> vˈɛntəs
//   $ espeak-ng --path=<piper>/espeak-ng-data -v en-us --ipa -q aqua        -> ˈækwə
//   $ espeak-ng --path=<piper>/espeak-ng-data -v en-us --ipa -q terra       -> tˈɛɹə
//   $ espeak-ng --path=<piper>/espeak-ng-data -v en-us --ipa -q reformahray -> ɹᵻfˈoːɹmɑːɹˌeɪ
//   $ espeak-ng --path=<piper>/espeak-ng-data -v en-us --ipa -q invoco      -> ɪnvˈoʊkoʊ
//
// The two openers replace the retired `finitus` (§8.4 — a terminator marks
// ends, and a listener needs STARTS marked). Chosen 2026-08-04, closing
// §8.11's first open item: `reformare` (general cast) / `invoco` (summon).
//
// reformare is phonemized from "reformahray", NOT the literal word — a
// deliberate spelling override (kTtsTextOverride in
// scripts/generate_practice_assets.dart), same mechanism as ignis below.
// Plain "reformare" gives /ɹᵻfˈoːɹmɛɹ/, which is the English word
// "reformer" — the "-are" collapses to /ɛɹ/ and the Latin is lost entirely.
// "reformahray" -> /ɹᵻfˈoːɹmɑːɹˌeɪ/ ("ruh-FOR-mah-ray") restores the Latin
// four-syllable shape. invoco needs no override: /ɪnvˈoʊkoʊ/ ("in-VOH-koh")
// is already close to the Latin.
//
// Opener separation matters more than any other pair in the table (§8.7):
// it is the one distance a player is actively motivated to collapse, so a
// summon can't be told from an incantation. The defaults are deliberately
// far apart — different onset (/ɹ/ vs /ɪn/), different syllable count (4 vs
// 3), different stress shape.
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
//   - Unstressed word-final "-us"/"-a" reduce to schwa /ə/ across the
//     affected words (ventus, aqua, terra) — standard English vowel
//     reduction, matching how "campus" or "aqua" (already an English
//     loanword) are actually said.
//   - reformare's first vowel reduces to /ᵻ/ rather than a clear /ɛ/, so it
//     is "ruh-FOR-mah-ray", not "reh-". Accepted: it is what an English
//     speaker reading the word aloud actually produces, which is the sound
//     the template should teach. The scorer target comes from this same
//     phonemization (see scripts/generate_practice_assets.dart), so the
//     rendered template and the phoneme trail can't silently diverge.
//
// [PracticePhoneme.weight] is a coarse relative-duration heuristic (vowel
// ~1.0, reduced/schwa vowel ~0.7, plosive/flap ~0.4-0.5, nasal/liquid
// ~0.6-0.8) used only to divide a word's reference MFCC frames into
// checkpoint segments proportionally rather than uniformly by count. It is
// not measured acoustic-phone duration — this is a practice-tool
// approximation, not a forced-alignment ground truth.

import '../sorcerer/vocal_slot.dart';

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

  static const Map<VocalSlot, List<PracticePhoneme>> _table = {
    VocalSlot.fire: [
      PracticePhoneme('ɪ', 1.0),
      PracticePhoneme('ɡ', 0.5),
      PracticePhoneme('n', 0.6),
      PracticePhoneme('ɪ', 1.0),
      PracticePhoneme('s', 0.8),
    ],
    VocalSlot.air: [
      PracticePhoneme('v', 0.6),
      PracticePhoneme('ɛ', 1.0),
      PracticePhoneme('n', 0.6),
      PracticePhoneme('t', 0.4),
      PracticePhoneme('ə', 0.7),
      PracticePhoneme('s', 0.8),
    ],
    VocalSlot.water: [
      PracticePhoneme('æ', 1.0),
      PracticePhoneme('k', 0.5),
      PracticePhoneme('w', 0.5),
      PracticePhoneme('ə', 0.7),
    ],
    VocalSlot.earth: [
      PracticePhoneme('t', 0.4),
      PracticePhoneme('ɛ', 1.0),
      PracticePhoneme('ɹ', 0.6),
      PracticePhoneme('ə', 0.7),
    ],
    // reformare, via the "reformahray" TTS override -> ɹᵻfˈoːɹmɑːɹˌeɪ.
    VocalSlot.openerGeneral: [
      PracticePhoneme('ɹ', 0.6),
      PracticePhoneme('ᵻ', 0.7),
      PracticePhoneme('f', 0.6),
      PracticePhoneme('oː', 1.0),
      PracticePhoneme('ɹ', 0.6),
      PracticePhoneme('m', 0.6),
      PracticePhoneme('ɑː', 1.0),
      PracticePhoneme('ɹ', 0.6),
      PracticePhoneme('eɪ', 1.0),
    ],
    // invoco -> ɪnvˈoʊkoʊ. No spelling override needed.
    VocalSlot.openerSummon: [
      PracticePhoneme('ɪ', 1.0),
      PracticePhoneme('n', 0.6),
      PracticePhoneme('v', 0.6),
      PracticePhoneme('oʊ', 1.0),
      PracticePhoneme('k', 0.5),
      PracticePhoneme('oʊ', 1.0),
    ],
  };

  /// The phoneme sequence for [word], in order.
  static List<PracticePhoneme> phonemesFor(VocalSlot word) => _table[word]!;

  /// Cumulative weight fractions in (0.0, 1.0], one per phoneme boundary,
  /// e.g. [0.35, 0.7, 1.0] for a 3-phoneme word with equal weights. Used to
  /// map a word's reference MFCC frame count to checkpoint frame indices
  /// (see VocalTemplate.checkpointFrameIndices in vocal_template_source.dart).
  static List<double> cumulativeWeightFractions(VocalSlot word) {
    final phonemes = phonemesFor(word);
    final total = phonemes.fold<double>(0.0, (sum, p) => sum + p.weight);
    var running = 0.0;
    return [
      for (final p in phonemes) (running += p.weight) / total,
    ];
  }
}
