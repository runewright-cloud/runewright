// SPDX-License-Identifier: GPL-3.0-or-later
//
// armor_lexicon.dart — THE seam where a leyline decides which four-element
// runs name which Aetherial Armor keywords
// (docs/LEYLINE_SEED_PLAN.md §9; audit R-8, Slice F).
//
// ## What this is
//
// One object, built once from the match's canonical [LeylineConfig], that
// answers the only leyline-dependent question an armor has:
//
//   **Which keywords does this dominance sequence spell?** ([keywordsOf])
//
// Everything else an armor is stays put. §9 is explicit about the split, and it
// is worth naming the two halves because conflating them is the review gate's
// first listed failure:
//
//   * **intrinsic, and leyline-INDEPENDENT** — certified T, slot cost
//     (`ceil(T/4)`), the four element counts, and every curved stat bonus off
//     them: melee (Fire), move speed (Air), spell range (Water) and armor HP
//     (Earth). All of these are arithmetic over the certified trajectory and
//     none of them consults a dictionary;
//   * **pattern-derived, and leyline-REKEYED** — the keyword set, and nothing
//     else.
//
// So the same proof yields the same T, the same slot cost and the same stat
// bonuses under every tradition, and a different keyed keyword set under a
// different one. An armor with no keyed keyword under a mutable leyline is
// still exactly as strong as its ladders say.
//
// ## What a Mutable leyline does NOT change here (R-8)
//
//   * **the recogniser.** Still a four-element contiguous run over
//     `TrajectoryParser.certifiedPerGenerationDominantSequence` — which is NOT
//     the formula sequence — still overlapping, still granting each keyword at
//     most once. `LeylineConfig.formulaLength` is the incantation grammar's
//     length and must never become this window's width;
//   * **how many runs mean something.** Seven of 256, one per keyword, exactly
//     as ordinarily. Incantation's noise density does not apply to a sliding
//     language;
//   * **the vocabulary.** The same seven keywords (Morphic is still absent).
//     There is no `ArmorKeyword.noise`.
//
// ## Derivation happens HERE and only here
//
// A mutable lexicon derives its [LeylinePatternCodebook] once, in the factory,
// under [kLeylineArmorDomain] alone. Ordinary lexicons derive nothing.
//
// ## Both peers, one reading
//
// `CertifiedArmor.fromOutputs` takes a lexicon and both sides pass the leyline
// they agreed at the handshake, so one proof plus one accepted `LeylineConfig`
// is one armor on both devices. **No derived keyword crosses the wire** — the
// armor envelope still carries a proof and a routing tier and nothing else, and
// a peer's opinion about its own keywords is not asked for and would not be
// believed.
//
// ## What this does NOT do
//
//   * **It does not serve Summons.** Different certified sequence, different
//     vocabulary, different domain tag; §9 requires the dictionaries be
//     independently derived. A posture test forbids this file from importing
//     `summon_lexicon.dart`.
//   * **It does not touch the proof.** No public input, no circuit, no VK, and
//     no new field: everything here is derived from data both devices already
//     have.

import 'package:rune_duel/battle/models/armor_keyword.dart';
import 'package:rune_duel/battle/models/leyline_config.dart' show LeylineConfig;
import 'package:rune_duel/battle/models/leyline_pattern_codebook.dart';
import 'package:rune_duel/battle/models/leyline_stream.dart'
    show kLeylineArmorDomain;
import 'package:rune_duel/engine/border_zone.dart';

/// What dominance runs mean to an armor under one leyline.
///
/// Construct with [ArmorLexicon.of] and hold it for the life of the
/// certification context. Two lexicons built from equal configs answer every
/// question identically — pinned by test.
class ArmorLexicon {
  const ArmorLexicon._(this.leyline, this._codebook);

  /// The lexicon for [leyline].
  ///
  /// An ordinary config yields an ordinary lexicon and derives nothing; a
  /// mutable one derives its dictionary here, once.
  factory ArmorLexicon.of(LeylineConfig leyline) => ArmorLexicon._(
        leyline,
        leyline.mutableMagic
            ? LeylinePatternCodebook.derive(
                config: leyline,
                domainTag: kLeylineArmorDomain,
                outputCodes: [
                  for (final k in ArmorKeyword.values) armorKeywordCode(k),
                ],
              )
            : null,
      );

  /// The canonical ordinary lexicon — the fixed seven-pattern table. `const`,
  /// so it can be a default parameter value, which is what keeps every existing
  /// `CertifiedArmor.fromOutputs` call reading exactly as it always has.
  static const ArmorLexicon ordinary = ArmorLexicon._(
    LeylineConfig.ordinaryDefault,
    null,
  );

  /// The leyline this lexicon speaks for.
  final LeylineConfig leyline;

  /// The derived dictionary, or null under an ordinary leyline.
  final LeylinePatternCodebook? _codebook;

  /// Whether this lexicon reinterprets runs through a derived dictionary.
  bool get isMutable => _codebook != null;

  /// Elements in a keyword pattern. Four under every leyline.
  int get patternLength => kLeylinePatternLength;

  /// The keywords [sequence] spells under this leyline.
  ///
  /// [sequence] must be the certified PER-GENERATION DOMINANT sequence, which
  /// is what an armor scores: one element per non-neutral generation, repeats
  /// kept. That is a different reading of the certified trajectory from the
  /// formula-commit sequence a summon or an incantation consumes, and passing
  /// the wrong one produces confident nonsense rather than an error.
  Set<ArmorKeyword> keywordsOf(List<BorderZone> sequence) {
    final codebook = _codebook;
    if (codebook == null) return ordinaryArmorKeywords(sequence);

    final found = <ArmorKeyword>{};
    for (var start = 0;
        start + kLeylinePatternLength <= sequence.length;
        start++) {
      final window = sequence.sublist(start, start + kLeylinePatternLength);
      final code = codebook.codeFor(window);
      if (code == null) continue; // inert run — the ordinary case
      final keyword = armorKeywordForCode(code);
      if (keyword != null) found.add(keyword);
    }
    return found;
  }

  /// The run that names [keyword] under this leyline, for preview surfaces.
  List<BorderZone>? patternFor(ArmorKeyword keyword) {
    final codebook = _codebook;
    if (codebook == null) return armorKeywordPatterns[keyword];
    return codebook.patternFor(armorKeywordCode(keyword));
  }

  @override
  String toString() =>
      'ArmorLexicon(${leyline.displayName}, mutable: $isMutable)';
}
