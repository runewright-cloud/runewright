// SPDX-License-Identifier: GPL-3.0-or-later
//
// summon_ability.dart — the Summon special-ability VOCABULARY: what abilities
// exist, what they are called, what they do, what their ordinary patterns are,
// and their canonical consensus codes.
//
// ## Why it is its own file (Slice F)
//
// It was `creature_spec.dart`'s, and moved here for the same reason
// `incantation_meaning.dart` was split out of `leyline_codebook.dart`: ordinary
// code needs to *name* an ability long before anything may derive a Mutable
// dictionary, and `SummonLexicon` needs the vocabulary without `creature_spec`
// needing the lexicon. The move is a dependency boundary, not a semantic one —
// `creature_spec.dart` re-exports every name below, so no importer changed.
//
// ## The ordinary language, which a Mutable Leyline does not restructure
//
// Eight abilities, one four-element pattern each, matched as a contiguous
// window anywhere in the sequence. Windows may overlap, elements may be reused
// between abilities, and each ability is granted at most once no matter how
// many times its pattern occurs. R-8 keeps every word of that under a Mutable
// leyline and rekeys only WHICH pattern names which ability
// (`summon_lexicon.dart`).

import 'package:rune_duel/engine/border_zone.dart';

// ── The vocabulary ────────────────────────────────────────────────────────────

/// The 8 element-sequence-pattern abilities ("Abilities" table). Pattern
/// length defaults to 4 ("Defaulting to 4 long for all for initial play
/// testing"); matches allow element reuse ("An element may be used more than
/// one time when searching for ability patterns") — plain substring search
/// over the initials string already gives this for free.
enum SummonAbility {
  flying, // AAAA
  cleave, // FFFF
  big, // EEEE
  morphic, // WWWW
  charger, // FAFA
  stealthy, // AWAW
  muddy, // WEWE
  moltenCarapace, // EFEF
}

/// The ORDINARY pattern of each ability — the fixed table, the game's
/// accumulated scholarship, and never seed-dependent.
const Map<SummonAbility, String> kSummonAbilityPattern = {
  SummonAbility.flying: 'AAAA',
  SummonAbility.cleave: 'FFFF',
  SummonAbility.big: 'EEEE',
  SummonAbility.morphic: 'WWWW',
  SummonAbility.charger: 'FAFA',
  SummonAbility.stealthy: 'AWAW',
  SummonAbility.muddy: 'WEWE',
  SummonAbility.moltenCarapace: 'EFEF',
};

/// The consensus code of each summon ability (audit R-8).
///
/// Explicit codes, not `SummonAbility.index`, for the same reason
/// `kIncantationEffectCode` is explicit: these bytes enter a hash preimage, so
/// reordering the enum — a legitimate, purely cosmetic edit — must not be able
/// to reroll every mutable leyline's summon dictionary. The values match
/// today's declaration order, which is the point: adopting them changes nothing
/// and freezes it.
///
/// **The hazard is currently invisible**, which is why it is written down:
/// `summonAbilityCode(a) == a.index` for all eight today, so a regression that
/// swapped one for the other would move no vector. A test asserts the
/// coincidence explicitly so whoever reorders the enum is stopped here.
///
/// (Unrelated but adjacent: `BattleState.toCanonicalBytes` packs a minion's
/// abilities as `1 << a.index`. That is a *different* consensus surface with
/// the same hazard and its own pinning; reordering this enum moves it too.)
const Map<SummonAbility, int> kSummonAbilityCode = {
  SummonAbility.flying: 0,
  SummonAbility.cleave: 1,
  SummonAbility.big: 2,
  SummonAbility.morphic: 3,
  SummonAbility.charger: 4,
  SummonAbility.stealthy: 5,
  SummonAbility.muddy: 6,
  SummonAbility.moltenCarapace: 7,
};

/// [kSummonAbilityCode] as a total function. Throws rather than defaulting: an
/// ability with no pinned code is a consensus hole, and a silent 0 would
/// collide with Flying.
int summonAbilityCode(SummonAbility ability) {
  final code = kSummonAbilityCode[ability];
  if (code == null) {
    throw ArgumentError('no canonical summon ability code pinned for $ability');
  }
  return code;
}

/// The ability whose canonical code is [code], or null if none.
SummonAbility? summonAbilityForCode(int code) {
  for (final entry in kSummonAbilityCode.entries) {
    if (entry.value == code) return entry.key;
  }
  return null;
}

// ── The ordinary matcher ──────────────────────────────────────────────────────

/// The initials-string spelling of [sequence] — `FFAW` — which is what the
/// ordinary patterns are written in.
String summonInitials(List<BorderZone> sequence) =>
    sequence.map(summonInitial).join();

/// One element's initial.
String summonInitial(BorderZone z) => switch (z) {
      BorderZone.fire => 'F',
      BorderZone.air => 'A',
      BorderZone.water => 'W',
      BorderZone.earth => 'E',
    };

/// The abilities [sequence] spells under the ORDINARY tradition.
///
/// THE one ordinary implementation, so `CreatureSpec.fromElements` and
/// `SummonLexicon.ordinary` cannot drift apart: contiguous substring search
/// over the whole flat sequence, overlaps allowed, each ability at most once.
/// A Mutable leyline reuses this structure with a different table
/// (`summon_lexicon.dart`); it never reaches this function.
Set<SummonAbility> ordinarySummonAbilities(List<BorderZone> sequence) {
  final initials = summonInitials(sequence);
  final found = <SummonAbility>{};
  for (final entry in kSummonAbilityPattern.entries) {
    if (initials.contains(entry.value)) found.add(entry.key);
  }
  return found;
}

// ── Display ───────────────────────────────────────────────────────────────────

/// Friendly ability names for [SummonAbility] (design doc "Abilities" table).
const Map<SummonAbility, String> kSummonAbilityLabel = {
  SummonAbility.flying: 'Flying',
  SummonAbility.cleave: 'Cleave',
  SummonAbility.big: 'Big',
  SummonAbility.morphic: 'Morphic',
  SummonAbility.charger: 'Charger',
  SummonAbility.stealthy: 'Stealthy',
  SummonAbility.muddy: 'Muddy',
  SummonAbility.moltenCarapace: 'Molten Carapace',
};

/// Ability flavor-text, transcribed from the "Abilities" table in
/// docs/runewright_design_v3_0.md (§Abilities). Used by the spell card's
/// rules-text box for summons.
const Map<SummonAbility, String> kSummonAbilityDescription = {
  SummonAbility.flying:
      'May move through other entities as if they were not there, but still '
          'not end its move in the same tile as another entity. Unaffected by '
          'modified terrain (though still by clouds).',
  SummonAbility.cleave:
      'Attack damage will be applied to a second enemy entity if that second '
          'entity is adjacent to both the primary target and this creature.',
  SummonAbility.big:
      'Occupies 3 adjacent hexes (forming a triangle) and cannot be moved by '
          'exterior forces. Its range, and the range of things affecting it, '
          'applies from any of its tiles.',
  SummonAbility.morphic:
      'Upon death, reforms into a new creature with half its elements '
          '(rounded down), selected at random.',
  SummonAbility.charger:
      'Adds damage equal to half the distance it moved before attacking, '
          'rounded up.',
  SummonAbility.stealthy:
      'Other summons will treat this creature as if it doesn\'t exist unless '
          'it\'s within an adjacent tile.',
  SummonAbility.muddy: 'Attack will reduce move speed of target by 1 for 1 turn.',
  SummonAbility.moltenCarapace:
      'Attacks from sources within 1 range of this creature cause 1 fire '
          'damage to be reflected.',
};
