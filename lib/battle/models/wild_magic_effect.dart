// SPDX-License-Identifier: GPL-3.0-or-later
//
// wild_magic_effect.dart — the wild-magic effect table (docs/WILD_MAGIC_PLAN.md
// §4.4, §7.1).
//
// Wild magic is the second, parallel effect system: a spell's public proof
// outputs are hashed with a community seed word, the hex digest is scanned for
// three trigger patterns, and a match fires a GLOBAL, SYMMETRIC, double-edged
// effect that ignores tile targeting entirely.
//
// Two properties are load-bearing and everything here serves them:
//
//   1. It is a fixed property of the rune. The hash has no per-cast entropy in
//      it, so a spell either always fires its wild magic or never does.
//   2. It is SYMMETRIC. Wild-magic effects hit the caster too. Never add an
//      "except the caster" clause to any effect in this table.
//
// The table is 3 trigger rows × 4 elemental columns = 12 effects. The row is
// chosen by which pattern the hash contains; the column(s) by which element(s)
// the spell's completed formulas are most affine to (see WildMagic.eligible-
// Elements). A perfectly balanced four-element spell fires all four cells of a
// matching row at once — that is intended (design v3.0 §RESOLVED, Chaos column
// deleted).

import 'package:rune_duel/battle/models/effect_kind.dart' show SpellAffinity;

// ── Community seed ────────────────────────────────────────────────────────────

/// The leyline seed word used when a player has chosen none, and the fallback
/// for any raw seed that normalizes to the empty string (`"---"`, `"日本"`).
///
/// Lives here rather than in `wild_magic.dart` so `MatchConfig` can default to
/// it without the models layer depending on the engine layer.
const String kDefaultCommunitySeed = 'universal';

/// Design: *"case-insensitive, stripped of whitespace and punctuation"*.
///
/// THE ONE normalization implementation — `WildMagic.normalizeCommunitySeed`
/// delegates here, and `MatchConfig.matches` compares normalized forms, so two
/// duelists who typed `"Rivendell!"` and `"rivendell"` agree at the handshake
/// exactly when their spells would hash identically. A second copy of this
/// regex anywhere is a consensus bug waiting to happen.
///
/// The empty-result fallback matters: a seed of `"日本"` or `"---"` normalizes
/// to the empty string, and an empty seed must not silently become a
/// *different* magical tradition from [kDefaultCommunitySeed].
String normalizeCommunitySeed(String raw) {
  final s = raw.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  return s.isEmpty ? kDefaultCommunitySeed : s;
}

// ── Rows ──────────────────────────────────────────────────────────────────────

/// The three trigger patterns scanned for in the seed hash.
///
/// Row minimums and bracket scaling live in [WildMagic.scan]; see
/// WILD_MAGIC_PLAN.md §4.2 for the table and the rarity numbers each row was
/// tuned to (rows 1–2 ≈ 1 in 70 per spell; row 3 ≈ 1 in 1,150).
enum WildMagicRow {
  /// `000` — a maximal run of ≥3 `'0'` characters.
  repeatZero,

  /// `111` — a maximal run of ≥3 `'1'` characters.
  repeatOne,

  /// `0123` — a maximal ascending (mod 16) run of length ≥4 starting at `'0'`.
  ascendingRun,
}

// ── Effects ───────────────────────────────────────────────────────────────────

/// The twelve wild-magic effects, in row-major order (row 1 → 2 → 3, and
/// within a row `fire, earth, water, air`).
enum WildMagicEffectKind {
  // Row 1 — `000`
  burningHot,
  mountains,
  manaFlood,
  zephyr,

  // Row 2 — `111`
  spontaneousCombustion,
  chasm,
  glacier,
  updraft,

  // Row 3 — `0123`
  phoenix,
  statuesque,
  ripplingReflections,
  scatteredGusts,
}

/// The (row, element) → effect lookup. §4.4's table, transcribed.
WildMagicEffectKind wildMagicEffectFor(WildMagicRow row, SpellAffinity element) =>
    switch ((row, element)) {
      (WildMagicRow.repeatZero, SpellAffinity.fire) => WildMagicEffectKind.burningHot,
      (WildMagicRow.repeatZero, SpellAffinity.earth) => WildMagicEffectKind.mountains,
      (WildMagicRow.repeatZero, SpellAffinity.water) => WildMagicEffectKind.manaFlood,
      (WildMagicRow.repeatZero, SpellAffinity.air) => WildMagicEffectKind.zephyr,
      (WildMagicRow.repeatOne, SpellAffinity.fire) =>
        WildMagicEffectKind.spontaneousCombustion,
      (WildMagicRow.repeatOne, SpellAffinity.earth) => WildMagicEffectKind.chasm,
      (WildMagicRow.repeatOne, SpellAffinity.water) => WildMagicEffectKind.glacier,
      (WildMagicRow.repeatOne, SpellAffinity.air) => WildMagicEffectKind.updraft,
      (WildMagicRow.ascendingRun, SpellAffinity.fire) => WildMagicEffectKind.phoenix,
      (WildMagicRow.ascendingRun, SpellAffinity.earth) => WildMagicEffectKind.statuesque,
      (WildMagicRow.ascendingRun, SpellAffinity.water) =>
        WildMagicEffectKind.ripplingReflections,
      (WildMagicRow.ascendingRun, SpellAffinity.air) =>
        WildMagicEffectKind.scatteredGusts,
    };

// ── Trigger ───────────────────────────────────────────────────────────────────

/// One fired trigger: which row matched, which elemental column the spell's
/// affinity selected, and how far past the row's minimum the run ran.
///
/// [bracketSteps] is `runLength − minimumLength` (0 = the base, unbracketed
/// value). Row 3's effects carry no bracketed values, so bracketSteps is
/// computed but unused there (WILD_MAGIC_PLAN.md A4).
class WildMagicTrigger {
  const WildMagicTrigger({
    required this.row,
    required this.element,
    required this.bracketSteps,
  });

  final WildMagicRow row;
  final SpellAffinity element;
  final int bracketSteps;

  WildMagicEffectKind get effect => wildMagicEffectFor(row, element);

  @override
  String toString() =>
      'WildMagicTrigger(${effect.name}, bracketSteps: $bracketSteps)';

  @override
  bool operator ==(Object other) =>
      other is WildMagicTrigger &&
      row == other.row &&
      element == other.element &&
      bracketSteps == other.bracketSteps;

  @override
  int get hashCode => Object.hash(row, element, bracketSteps);
}

// ── In-world copy ─────────────────────────────────────────────────────────────

/// In-world names, from design v3.0 §Wild Magic System's effects table. Shown
/// on the battle screen's resolution reveal — wild magic is untelegraphed by
/// design, so that reveal is the only place either player learns it fired.
const Map<WildMagicEffectKind, String> kWildMagicEffectLabel = {
  WildMagicEffectKind.burningHot: 'Burning Hot',
  WildMagicEffectKind.mountains: 'Mountains',
  WildMagicEffectKind.manaFlood: 'Mana Flood',
  WildMagicEffectKind.zephyr: 'Zephyr',
  WildMagicEffectKind.spontaneousCombustion: 'Spontaneous Combustion',
  WildMagicEffectKind.chasm: 'Chasm',
  WildMagicEffectKind.glacier: 'Glacier',
  WildMagicEffectKind.updraft: 'Updraft',
  WildMagicEffectKind.phoenix: 'Phoenix',
  WildMagicEffectKind.statuesque: 'Statuesque',
  WildMagicEffectKind.ripplingReflections: 'Rippling Reflections',
  WildMagicEffectKind.scatteredGusts: 'Scattered Gusts',
};

/// One-line descriptions for the reveal card. Written in the symmetric voice
/// ("all players") deliberately — the player needs to read at a glance that
/// this hit them too.
const Map<WildMagicEffectKind, String> kWildMagicEffectDescription = {
  WildMagicEffectKind.burningHot:
      'The air itself ignites. Every spell effect next turn burns hotter.',
  WildMagicEffectKind.mountains:
      'Stone erupts around every wizard, walling them in.',
  WildMagicEffectKind.manaFlood:
      'A leyline bursts. Every mana bar fills to the brim.',
  WildMagicEffectKind.zephyr:
      'A gale scatters every wizard and creature across the field.',
  WildMagicEffectKind.spontaneousCombustion:
      'A marked spell tears itself loose from every wizard and casts unbidden.',
  WildMagicEffectKind.chasm: 'The ground splits. A chasm bisects the field.',
  WildMagicEffectKind.glacier:
      'Frost sheets the open ground; footing slides away.',
  WildMagicEffectKind.updraft: 'An updraft lifts every wizard off the ground.',
  WildMagicEffectKind.phoenix:
      'Every wizard is promised one return from the ashes.',
  WildMagicEffectKind.statuesque:
      'Stillness restores. Stand fast and be made whole — move or cast and lose it.',
  WildMagicEffectKind.ripplingReflections:
      'Reality stutters. Every spell now either fizzles or resolves twice.',
  WildMagicEffectKind.scatteredGusts:
      'Every cast now blows a wizard’s bookmarks loose.',
};
