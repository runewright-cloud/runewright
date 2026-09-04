// SPDX-License-Identifier: GPL-3.0-or-later
//
// summon_lexicon.dart — THE seam where a leyline decides which four-element
// patterns name which summon abilities
// (docs/LEYLINE_SEED_PLAN.md §8; audit R-8, Slice F).
//
// ## What this is
//
// One object, built once from the match's canonical [LeylineConfig], that
// answers the only leyline-dependent question the summon system has:
//
//   **Which abilities does this element sequence spell?** ([abilitiesOf])
//
// Everything else about a creature — its affinity, its HP/damage/move/range,
// its elemental identity, its resistance wheel — is derived from the certified
// sequence by `CreatureSpec` and is IDENTICAL under every leyline. §8 is
// explicit: *"The leyline should not erase the underlying elemental/CA identity
// of the creature… Rekey only the pattern-to-special-ability interpretation."*
// [specOf] is that split expressed in one call.
//
// ## What a Mutable leyline does NOT change here (R-8)
//
//   * **the recogniser.** Still a four-element contiguous window, still slid
//     across the whole flat sequence, still overlapping, still granting each
//     ability at most once. `LeylineConfig.formulaLength` is the *incantation*
//     grammar's length and has no business resizing a creature's pattern
//     window — a `rivendell 6` duel still reads four-element abilities;
//   * **how many patterns mean something.** Eight of 256, exactly as ordinarily
//     — one per ability. Incantation's ~50% noise density belongs to a language
//     consumed in disjoint chunks; applying it here would make roughly half of
//     every sliding window an ability and turn every creature into a menagerie;
//   * **the vocabulary.** The same eight abilities, doing the same eight
//     things. There is no `SummonAbility.noise`: a window that matches nothing
//     is the ordinary case for a sliding language, not a decoded meaning.
//
// What it changes is exactly one thing: which pattern is which ability, and
// which eight patterns are words at all.
//
// ## Derivation happens HERE and only here
//
// A mutable lexicon derives its [LeylinePatternCodebook] once, in the factory,
// under [kLeylineSummonDomain] alone. Ordinary lexicons derive NOTHING —
// `LeylinePatternCodebook.derive` refuses an ordinary config outright, and this
// class never asks it to — so ordinary play stays completely independent of the
// seed and of every byte of the derivation machinery. That independence is
// pinned by test, not merely intended.
//
// ## What this does NOT do
//
//   * **It does not touch the certified trajectory.** A lexicon reinterprets
//     the certified element sequence; it never rewrites it. Proofs, kin keys,
//     heraldry and mana cost are untouched by anything here.
//   * **It does not serve Armor.** Armor reads a *different certified
//     sequence* (per-generation dominance, not the formula-commit sequence),
//     has a *different vocabulary* (seven keywords, no Morphic), and derives
//     under a *different domain tag*. Knowledge of this dictionary must reveal
//     nothing about that one (§9). A posture test forbids this file from so
//     much as importing `armor_lexicon.dart`.
//   * **It does not serve Incantation**, for the stronger reason that
//     incantations are not a pattern language at all.

import 'package:rune_duel/battle/models/creature_spec.dart' show CreatureSpec;
import 'package:rune_duel/battle/models/effect_kind.dart' show SpellAffinity;
import 'package:rune_duel/battle/models/leyline_config.dart' show LeylineConfig;
import 'package:rune_duel/battle/models/leyline_pattern_codebook.dart';
import 'package:rune_duel/battle/models/leyline_stream.dart'
    show kLeylineSummonDomain;
import 'package:rune_duel/battle/models/summon_ability.dart';
import 'package:rune_duel/engine/border_zone.dart';

/// What element patterns mean to a creature under one leyline.
///
/// Construct with [SummonLexicon.of] and hold it for the life of the
/// deterministic context (a match). Two lexicons built from equal configs
/// answer every question identically — pinned by test — so passing one down is
/// an optimisation, never a correctness requirement.
class SummonLexicon {
  const SummonLexicon._(this.leyline, this._codebook);

  /// The lexicon for [leyline].
  ///
  /// An ordinary config yields an ordinary lexicon and derives nothing; a
  /// mutable one derives its dictionary here, once.
  factory SummonLexicon.of(LeylineConfig leyline) => SummonLexicon._(
        leyline,
        leyline.mutableMagic
            ? LeylinePatternCodebook.derive(
                config: leyline,
                domainTag: kLeylineSummonDomain,
                outputCodes: [
                  for (final a in SummonAbility.values) summonAbilityCode(a),
                ],
              )
            : null,
      );

  /// The canonical ordinary lexicon — the fixed eight-pattern table. `const`,
  /// so it can be a default parameter value.
  static const SummonLexicon ordinary = SummonLexicon._(
    LeylineConfig.ordinaryDefault,
    null,
  );

  /// The leyline this lexicon speaks for.
  final LeylineConfig leyline;

  /// The derived dictionary, or null under an ordinary leyline — where there is
  /// no dictionary to derive, only the fixed table.
  final LeylinePatternCodebook? _codebook;

  /// Whether this lexicon reinterprets patterns through a derived dictionary.
  bool get isMutable => _codebook != null;

  /// Elements in an ability pattern. Four under every leyline — see this file's
  /// header, and do not route [LeylineConfig.formulaLength] here.
  int get patternLength => kLeylinePatternLength;

  /// The abilities [sequence] spells under this leyline.
  ///
  /// Ordinary: `ordinarySummonAbilities`, i.e. exactly the fixed table.
  ///
  /// Mutable: the same sliding four-element window against the derived
  /// dictionary. Overlapping matches and at-most-once granting are preserved
  /// because they are properties of the search, not of the table.
  Set<SummonAbility> abilitiesOf(List<BorderZone> sequence) {
    final codebook = _codebook;
    if (codebook == null) return ordinarySummonAbilities(sequence);

    final found = <SummonAbility>{};
    for (var start = 0;
        start + kLeylinePatternLength <= sequence.length;
        start++) {
      final window = sequence.sublist(start, start + kLeylinePatternLength);
      final code = codebook.codeFor(window);
      if (code == null) continue; // inert window — the ordinary case
      final ability = summonAbilityForCode(code);
      if (ability != null) found.add(ability);
    }
    return found;
  }

  /// The complete creature [sequence] describes under this leyline: CA-derived
  /// affinity and stats exactly as ordinarily, abilities through [abilitiesOf].
  ///
  /// **The one call battle resolution and any leyline-aware preview should
  /// use.** `CreatureSpec.fromElements` remains the ordinary/reference
  /// derivation for surfaces that have no leyline (the library, the inscription
  /// editor); calling it in a match would read ordinary abilities under a
  /// mutable tradition, which is the "UI says Flying / battle says nothing"
  /// failure this seam exists to prevent.
  ///
  /// Returns null for an empty sequence, exactly as `CreatureSpec.fromElements`
  /// does — a summon with no activations is a void cast.
  CreatureSpec? specOf(List<BorderZone> sequence) {
    final base = CreatureSpec.fromElements(sequence);
    if (base == null) return null;
    if (!isMutable) return base;
    return CreatureSpec(
      affinity: base.affinity,
      stats: base.stats,
      abilities: abilitiesOf(sequence),
    );
  }

  /// The pattern that names [ability] under this leyline, for teaching and
  /// preview surfaces. Ordinary: the fixed table's four-character string.
  ///
  /// Never null under either tradition today — both dictionaries are bijections
  /// over the full vocabulary — but nullable so a future vocabulary larger than
  /// its dictionary cannot silently print a wrong pattern.
  List<BorderZone>? patternFor(SummonAbility ability) {
    final codebook = _codebook;
    if (codebook == null) {
      final initials = kSummonAbilityPattern[ability];
      if (initials == null) return null;
      return [
        for (final c in initials.split(''))
          switch (c) {
            'F' => BorderZone.fire,
            'A' => BorderZone.air,
            'W' => BorderZone.water,
            'E' => BorderZone.earth,
            _ => throw ArgumentError('unknown element initial "$c"'),
          },
      ];
    }
    return codebook.patternFor(summonAbilityCode(ability));
  }

  @override
  String toString() =>
      'SummonLexicon(${leyline.displayName}, mutable: $isMutable)';
}

// ── Display (UI-facing; no Flutter dependency, just label maps + strings) ────
//
// These moved here from `creature_spec.dart` in Slice F. They read a leyline —
// the ability clause is the rekeyed half — and `CreatureSpec` deliberately does
// not: it is CA-derived identity and must stay able to answer "what creature is
// this" with no leyline in the room. A posture test pins that separation.

const Map<SpellAffinity, String> _kCreatureAffinityLabel = {
  SpellAffinity.fire: 'Fire',
  SpellAffinity.earth: 'Earth',
  SpellAffinity.water: 'Water',
  SpellAffinity.air: 'Air',
};

/// Formats [spec] for display, e.g. "Fire Creature · HP 4 · DMG 3 · Move 2 ·
/// Range 1 · Flying, Cleave" (the ability clause is omitted when empty).
String summonSummaryLabel(
  CreatureSpec spec, {
  SummonLexicon lexicon = SummonLexicon.ordinary,
}) {
  final base = '${_kCreatureAffinityLabel[spec.affinity]} Creature · '
      'HP ${spec.stats.maxHp} · DMG ${spec.stats.damage} · '
      'Move ${spec.stats.moveSpeed} · Range ${spec.stats.attackRange}';
  if (spec.abilities.isEmpty) {
    // Under a mutable leyline "no abilities" is worth saying out loud: this
    // creature spells nothing THIS tradition has a word for, and a player who
    // knows the ordinary patterns must be told which reading they are seeing.
    return lexicon.isMutable
        ? '$base · no keyed ability under ${lexicon.leyline.displayName}'
        : base;
  }
  final abilityNames = spec.abilities.map((a) => kSummonAbilityLabel[a]).join(', ');
  return '$base · $abilityNames';
}

/// [summonSummaryLabel], parsing a stored [SpellAsset.formula] (zone-name
/// strings) first. Returns null for an empty/void sequence -- callers should
/// show a "Void Summon" fallback in that case.
String? summonSummaryFromFormula(
  List<String> formula, {
  SummonLexicon lexicon = SummonLexicon.ordinary,
}) {
  final sequence = formula.map(_zoneFromName).whereType<BorderZone>().toList();
  // [lexicon] rekeys only the ability clause (audit R-8). It defaults to the
  // ordinary tradition, which is what the library wants; the cast tray, which
  // reads this INSIDE a match, must pass the match's own.
  final spec = lexicon.specOf(sequence);
  if (spec == null) return null;
  return summonSummaryLabel(spec, lexicon: lexicon);
}

BorderZone? _zoneFromName(String name) => switch (name.toLowerCase()) {
      'fire' => BorderZone.fire,
      'earth' => BorderZone.earth,
      'water' => BorderZone.water,
      'air' => BorderZone.air,
      _ => null,
    };
