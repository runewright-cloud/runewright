// SPDX-License-Identifier: GPL-3.0-or-later
//
// effect_kind.dart — EffectKind (16 base effects), SpellAffinity, and the
// formula-pair → kind lookup.
//
// The second and third entries of a formula triplet (effectType1, effectType2)
// uniquely identify one of the 16 base effect kinds. The first entry (affinity)
// selects the flavor column within that row. Mirror pairs are preserved as
// distinct kinds (Fire-Water chains / Water-Fire clouds; Fire-Earth status
// effect interaction / Earth-Fire fuel transmutation) — the ordered-pair
// structure is a load-bearing systemic asset (design doc §mirror-pairs).

import 'package:rune_duel/engine/border_zone.dart';

// ── Effect display labels ──────────────────────────────────────────────────────

const Map<EffectKind, String> kEffectKindLabel = {
  EffectKind.damage:                  'Blast',
  EffectKind.barrier:                 'Barrier',
  EffectKind.reflections:             'Reflections',
  EffectKind.speedManipulation:       'Boost',
  EffectKind.statusEffectInteraction: 'Controlled Consumption',
  EffectKind.chainInteraction:        'Blazing Flow',
  EffectKind.spellInteraction:        'Energy Flows',
  EffectKind.fuelTransmutation:       'Fuel Consumption',
  EffectKind.tileModification:        'Terrain Sculpting',
  EffectKind.rangeModification:       'Inertia',
  EffectKind.clouds:                  'Cloud',
  EffectKind.artifactsInteraction:    'Shape Artifact',
  EffectKind.illusions:               'Illusions',
  EffectKind.multiplierCycles:        'Bellows',
  EffectKind.haymakerInteraction:     'Aura of Force',
  EffectKind.divination:              'Scrying Pool',
};

const Map<SpellAffinity, String> kAffinityLabel = {
  SpellAffinity.fire:  'Firey',
  SpellAffinity.earth: 'Earthen',
  SpellAffinity.water: 'Watery',
  SpellAffinity.air:   'Airy',
};

/// Resolves a stored [formula] list (flat zone names from [SpellAsset.formula])
/// into a list of human-readable effect labels, one per complete triplet.
/// Residuals (1–2 leftover entries) are silently dropped, matching the battle
/// resolution behaviour in TurnLoop._applySpell.
List<String> formulaEffectLabels(List<String> formula) {
  final zones = formula
      .map((n) => switch (n.toLowerCase()) {
            'fire'  => BorderZone.fire,
            'earth' => BorderZone.earth,
            'water' => BorderZone.water,
            'air'   => BorderZone.air,
            _       => null,
          })
      .whereType<BorderZone>()
      .toList();
  final labels = <String>[];
  for (var i = 0; i + 2 < zones.length; i += 3) {
    final affinity = spellAffinityFromZone(zones[i]);
    final kind     = effectKindFromPair(zones[i + 1], zones[i + 2]);
    labels.add('${kAffinityLabel[affinity]!} ${kEffectKindLabel[kind]!}');
  }
  return labels;
}

// ── Spell affinity ─────────────────────────────────────────────────────────────

/// The elemental affinity of a formula's first triplet entry.
///
/// Mirrors [BorderZone] but typed separately so the effect layer can evolve
/// independently of the CA engine enum. Affinity selects the flavor column in
/// the 4×16 effect table.
enum SpellAffinity { fire, earth, water, air }

/// Convert a [BorderZone] (CA engine) to a [SpellAffinity] (effect layer).
SpellAffinity spellAffinityFromZone(BorderZone zone) => switch (zone) {
      BorderZone.fire => SpellAffinity.fire,
      BorderZone.air => SpellAffinity.air,
      BorderZone.water => SpellAffinity.water,
      BorderZone.earth => SpellAffinity.earth,
    };

/// Resolves a completed formula [triplet] (exactly 3 zones, in the order
/// [FormulaTracker.formulas] commits them) into the (affinity, effect kind)
/// pair it selects -- the same resolution [formulaEffectLabels] performs per
/// group, exposed structured rather than pre-formatted so callers (e.g. the
/// recipe-discovery hook in main.dart) can key off it directly.
(SpellAffinity, EffectKind) formulaTripletKind(List<BorderZone> triplet) {
  assert(triplet.length == 3, 'formulaTripletKind expects a complete 3-element formula');
  return (
    spellAffinityFromZone(triplet[0]),
    effectKindFromPair(triplet[1], triplet[2]),
  );
}

/// The elemental affinity of a stored [formula]'s first activation (flat zone
/// names from [SpellAsset.formula], lowercased) — the same first-entry
/// resolution [formulaEffectLabels] and [formulaTripletKind] use. Used to
/// colour the cast-animation orb; returns null for an empty or unrecognised
/// formula.
SpellAffinity? primaryFormulaAffinity(List<String> formula) {
  if (formula.isEmpty) return null;
  return switch (formula.first.toLowerCase()) {
    'fire' => SpellAffinity.fire,
    'air' => SpellAffinity.air,
    'water' => SpellAffinity.water,
    'earth' => SpellAffinity.earth,
    _ => null,
  };
}

// ── Effect kind ────────────────────────────────────────────────────────────────

/// The 16 base effect types, keyed by their second-third formula pair.
///
/// Fire-Earth and Earth-Fire no longer summon Spirits/Hounds (design doc
/// v3.0 rework) -- creature summoning moves to a separate Rune Craft
/// "summons" mode (stats from elemental counts + formula-sequence
/// abilities), not the 16-cell incantation table. See minion.dart, which
/// keeps the Minion/SpiritMinion/HoundMinion infrastructure for that
/// upcoming mode even though no incantation formula creates one right now.
enum EffectKind {
  damage,                  // Fire-Fire
  barrier,                 // Earth-Earth
  reflections,             // Water-Water
  speedManipulation,       // Air-Air
  statusEffectInteraction, // Fire-Earth
  chainInteraction,        // Fire-Water
  spellInteraction,        // Fire-Air
  fuelTransmutation,       // Earth-Fire
  tileModification,        // Earth-Water
  rangeModification,       // Earth-Air
  clouds,                  // Water-Fire
  artifactsInteraction,    // Water-Earth
  illusions,               // Water-Air
  multiplierCycles,        // Air-Fire
  haymakerInteraction,     // Air-Earth
  divination,              // Air-Water
}

/// Resolve the base effect kind from the second and third formula triplet entries.
EffectKind effectKindFromPair(BorderZone type1, BorderZone type2) =>
    switch ((type1, type2)) {
      (BorderZone.fire, BorderZone.fire) => EffectKind.damage,
      (BorderZone.earth, BorderZone.earth) => EffectKind.barrier,
      (BorderZone.water, BorderZone.water) => EffectKind.reflections,
      (BorderZone.air, BorderZone.air) => EffectKind.speedManipulation,
      (BorderZone.fire, BorderZone.earth) => EffectKind.statusEffectInteraction,
      (BorderZone.fire, BorderZone.water) => EffectKind.chainInteraction,
      (BorderZone.fire, BorderZone.air) => EffectKind.spellInteraction,
      (BorderZone.earth, BorderZone.fire) => EffectKind.fuelTransmutation,
      (BorderZone.earth, BorderZone.water) => EffectKind.tileModification,
      (BorderZone.earth, BorderZone.air) => EffectKind.rangeModification,
      (BorderZone.water, BorderZone.fire) => EffectKind.clouds,
      (BorderZone.water, BorderZone.earth) => EffectKind.artifactsInteraction,
      (BorderZone.water, BorderZone.air) => EffectKind.illusions,
      (BorderZone.air, BorderZone.fire) => EffectKind.multiplierCycles,
      (BorderZone.air, BorderZone.earth) => EffectKind.haymakerInteraction,
      (BorderZone.air, BorderZone.water) => EffectKind.divination,
    };
