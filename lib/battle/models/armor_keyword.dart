// SPDX-License-Identifier: GPL-3.0-or-later
//
// armor_keyword.dart — the Aetherial Armor keyword VOCABULARY: what keywords
// exist, their ordinary patterns, and their canonical consensus codes.
//
// ## Why it is its own file (Slice F)
//
// It was `certified_armor.dart`'s, and moved here for the same reason
// `summon_ability.dart` was split out of `creature_spec.dart`: `ArmorLexicon`
// needs the vocabulary, and `CertifiedArmor` needs the lexicon, so the
// vocabulary cannot live with the armor. The move is a dependency boundary, not
// a semantic one — `certified_armor.dart` re-exports every name below, so no
// importer changed.
//
// ## The ordinary language, which a Mutable Leyline does not restructure
//
// Seven keywords, one four-element pattern each, matched as a contiguous run
// anywhere in the certified per-generation dominance sequence. Runs may
// overlap, elements may be reused between keywords, and each keyword is granted
// at most once no matter how many times its pattern occurs. R-8 keeps every
// word of that under a Mutable leyline and rekeys only WHICH pattern names
// which keyword (`armor_lexicon.dart`).

import 'package:rune_duel/engine/border_zone.dart';

// ── The vocabulary ────────────────────────────────────────────────────────────

/// A property an armor grants when its four-element pattern appears anywhere
/// in the certified dominance sequence.
///
/// Patterns are contiguous substrings of that sequence. Elements may be reused
/// between keywords and matches may overlap, but each keyword is granted at
/// most once no matter how many times its pattern occurs.
enum ArmorKeyword {
  /// AAAA
  flying,

  /// FFFF
  cleave,

  /// FAFA
  charger,

  /// WEWE
  muddy,

  /// EFEF
  moltenCarapace,

  /// AWAW
  stealthy,

  /// EEEE
  anchored,
}

/// The ORDINARY certified pattern for each keyword, as a contiguous element
/// run. The fixed table; never seed-dependent.
//
// Morphic (WWWW) is deliberately absent — it is designed but not implemented,
// so a WWWW armor grants no keyword rather than a placeholder one. Note this
// also means the armor vocabulary is SEVEN where the summon vocabulary is
// eight, which is why the two mutable dictionaries have different meaningful
// counts.
const Map<ArmorKeyword, List<BorderZone>> armorKeywordPatterns = {
  ArmorKeyword.flying: [
    BorderZone.air, BorderZone.air, BorderZone.air, BorderZone.air,
  ],
  ArmorKeyword.cleave: [
    BorderZone.fire, BorderZone.fire, BorderZone.fire, BorderZone.fire,
  ],
  ArmorKeyword.charger: [
    BorderZone.fire, BorderZone.air, BorderZone.fire, BorderZone.air,
  ],
  ArmorKeyword.muddy: [
    BorderZone.water, BorderZone.earth, BorderZone.water, BorderZone.earth,
  ],
  ArmorKeyword.moltenCarapace: [
    BorderZone.earth, BorderZone.fire, BorderZone.earth, BorderZone.fire,
  ],
  ArmorKeyword.stealthy: [
    BorderZone.air, BorderZone.water, BorderZone.air, BorderZone.water,
  ],
  ArmorKeyword.anchored: [
    BorderZone.earth, BorderZone.earth, BorderZone.earth, BorderZone.earth,
  ],
};

/// The consensus code of each armor keyword (audit R-8).
///
/// Explicit codes, not `ArmorKeyword.index`, for the same reason
/// `kSummonAbilityCode` is explicit: these bytes enter a hash preimage, so
/// reordering the enum must not be able to reroll every mutable leyline's armor
/// dictionary. The values match today's declaration order — adopting them
/// changes nothing and freezes it — and a test asserts that coincidence so
/// whoever reorders the enum is stopped here.
const Map<ArmorKeyword, int> kArmorKeywordCode = {
  ArmorKeyword.flying: 0,
  ArmorKeyword.cleave: 1,
  ArmorKeyword.charger: 2,
  ArmorKeyword.muddy: 3,
  ArmorKeyword.moltenCarapace: 4,
  ArmorKeyword.stealthy: 5,
  ArmorKeyword.anchored: 6,
};

/// [kArmorKeywordCode] as a total function. Throws rather than defaulting: a
/// keyword with no pinned code is a consensus hole, and a silent 0 would
/// collide with Flying.
int armorKeywordCode(ArmorKeyword keyword) {
  final code = kArmorKeywordCode[keyword];
  if (code == null) {
    throw ArgumentError('no canonical armor keyword code pinned for $keyword');
  }
  return code;
}

/// The keyword whose canonical code is [code], or null if none.
ArmorKeyword? armorKeywordForCode(int code) {
  for (final entry in kArmorKeywordCode.entries) {
    if (entry.value == code) return entry.key;
  }
  return null;
}

// ── The ordinary matcher ──────────────────────────────────────────────────────

/// Whether [pattern] occurs as a contiguous run anywhere in [sequence].
///
/// THE one run search both traditions use — the structural recogniser R-8
/// leaves alone. Only the table it is applied to may be rekeyed.
bool armorSequenceContainsRun(
  List<BorderZone> sequence,
  List<BorderZone> pattern,
) {
  for (var start = 0; start + pattern.length <= sequence.length; start++) {
    var matched = true;
    for (var i = 0; i < pattern.length; i++) {
      if (sequence[start + i] != pattern[i]) {
        matched = false;
        break;
      }
    }
    if (matched) return true;
  }
  return false;
}

/// The keywords [sequence] spells under the ORDINARY tradition.
///
/// THE one ordinary implementation, so `CertifiedArmor` and
/// `ArmorLexicon.ordinary` cannot drift apart.
Set<ArmorKeyword> ordinaryArmorKeywords(List<BorderZone> sequence) {
  final keywords = <ArmorKeyword>{};
  for (final entry in armorKeywordPatterns.entries) {
    if (armorSequenceContainsRun(sequence, entry.value)) keywords.add(entry.key);
  }
  return keywords;
}
