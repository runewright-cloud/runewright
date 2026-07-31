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

/// Per-(kind, affinity) flavor-text description and per-kind flavor note
/// (duration/trigger caveat), transcribed from the Effect Table in
/// docs/runewright_design_v3_0.md §Effect Table, base values only — Potency's
/// bracketed numbers are omitted (see recipes_screen.dart's header comment).
/// Shared by the recipe reference screen and the spell card's rules-text box
/// so the flavor text lives in exactly one place.
const Map<EffectKind, Map<SpellAffinity, String>> kEffectDescription = {
  EffectKind.damage: {
    SpellAffinity.fire: '4 damage.',
    SpellAffinity.earth:
        '2 damage; also damages walls or sprites it intersects en route to the target.',
    SpellAffinity.water: '2 splash damage (area radius 2).',
    SpellAffinity.air: '2 damage and 1 knockback.',
  },
  EffectKind.barrier: {
    SpellAffinity.fire: '2 HP; adjacent tiles take 1 fire damage at end of turn.',
    SpellAffinity.earth: '4 HP.',
    SpellAffinity.water: '2 HP, plus 10% mana regen while active.',
    SpellAffinity.air: '2 HP; caster gets a free move when it collapses.',
  },
  EffectKind.reflections: {
    SpellAffinity.fire: 'Whenever the caster takes damage, the target takes equal damage.',
    SpellAffinity.earth:
        'Whenever the target creates a summon, the caster creates an identical summon under the caster\'s control.',
    SpellAffinity.water: 'Whenever the target gains mana, the caster gains equal mana.',
    SpellAffinity.air:
        'Whenever the target gains a status effect it cast on itself, the caster gains the same status effect.',
  },
  EffectKind.speedManipulation: {
    SpellAffinity.fire: 'Move n extra tiles at a cost of n(n+1)/2 health (1 tile free).',
    SpellAffinity.earth: 'Reduce target move speed by 1 for 3 turns.',
    SpellAffinity.water:
        'High Liquidity: move n extra tiles at a cost of n(n+1)/2 × 100 mana (1 tile free).',
    SpellAffinity.air: 'Increase target move speed by 1 for 2 turns.',
  },
  EffectKind.statusEffectInteraction: {
    SpellAffinity.fire: '1 damage per active status effect.',
    SpellAffinity.earth: 'All status effects go dormant for 2 turns.',
    SpellAffinity.water: 'Status effects lose 1 turn.',
    SpellAffinity.air: 'All status effects gain 1 turn.',
  },
  EffectKind.chainInteraction: {
    SpellAffinity.fire: 'Chain bonuses accumulate twice as fast for the next 2 turns.',
    SpellAffinity.earth: 'Chain bonuses grow at half speed for the next 3 turns.',
    SpellAffinity.water:
        'Gain all chain status of the affected target, overwriting your existing chains.',
    SpellAffinity.air: 'All chain bonuses removed.',
  },
  EffectKind.spellInteraction: {
    SpellAffinity.fire:
        'Next spell\'s cost is paid twice; any mana shortfall converts to health damage at 1 HP per 10 mana.',
    SpellAffinity.earth:
        '"Sluggish" — always resolves last unless others are also sluggish, for 3 turns.',
    SpellAffinity.water: 'Copy the enemy\'s spell.',
    SpellAffinity.air:
        '"Quick" — always resolves first unless others are also quick, for 2 turns.',
  },
  EffectKind.fuelTransmutation: {
    SpellAffinity.fire:
        'Wither 1 random active spell, found via bookmark; gain 1 random non-counter-charm artifact.',
    SpellAffinity.earth: 'Burn 4 life; reactivate 1 withered spell.',
    SpellAffinity.water: 'Burn 100 mana; gain 4 life.',
    SpellAffinity.air: 'Burn 1 random artifact; gain 100 mana.',
  },
  EffectKind.tileModification: {
    SpellAffinity.fire: 'Floor is Lava: 2 damage to pass through.',
    SpellAffinity.earth:
        'Impassable terrain that also blocks spells passing through it for line of sight.',
    SpellAffinity.water: 'Costs 2 movement to enter and drains mana on entry.',
    SpellAffinity.air:
        'Conveyor tile force-moves whatever stands on it; direction is chosen at effect resolution and is permanent.',
  },
  EffectKind.rangeModification: {
    SpellAffinity.fire:
        'Penetrating: spells can\'t be blocked by walls; 1 damage to anything in hexes en route.',
    SpellAffinity.earth: 'Reduce spell range by 1 for 3 turns.',
    SpellAffinity.water:
        'Turbulent: next spell fires in the intended direction but its range is randomized 1–max.',
    SpellAffinity.air: 'Increase spell range by 1.',
  },
  EffectKind.clouds: {
    SpellAffinity.fire: 'Entities entering or ending their turn in the cloud take 1 damage.',
    SpellAffinity.earth:
        'The adjacent-only targeting restriction lingers 2 turns after leaving the cloud.',
    SpellAffinity.water: 'The cloud is radius 2 instead of 1.',
    SpellAffinity.air:
        'The cloud moves 1 tile each turn, trying to center on the closest enemy (players before summons).',
  },
  EffectKind.artifactsInteraction: {
    SpellAffinity.fire:
        'Burn a random player artifact to deal 1 damage (random target via joint entropy; any artifact can be hit, including their last mana gem; burning a counter charm reveals its target).',
    SpellAffinity.earth: 'Summon 1 Absorption Totem.',
    SpellAffinity.water: 'Summon 1 mana gem.',
    SpellAffinity.air: 'Summon 1 bookmark.',
  },
  EffectKind.illusions: {
    SpellAffinity.fire:
        'Copy the summon on the target tile for yourself; the copy attacks aggressively and has 1 HP.',
    SpellAffinity.earth:
        'Copy the terrain on the target tile onto every terrain-free neighboring tile; the copies have 1 HP.',
    SpellAffinity.water:
        'Create 3 illusions of yourself spaced around your position. When you\'re subjected to a spell or '
            'attack, a chance of 1 in the number of illusions remaining means you\'re hit; otherwise a random '
            'illusion is destroyed and you\'re moved to its tile instead.',
    SpellAffinity.air: 'The non-wizard entity on the target tile is reduced to 1 HP.',
  },
  EffectKind.multiplierCycles: {
    SpellAffinity.fire: 'Your next air effect is twice as powerful.',
    SpellAffinity.earth: 'Your next fire effect is twice as powerful.',
    SpellAffinity.water: 'Your next earth effect is twice as powerful.',
    SpellAffinity.air: 'Your next water effect is twice as powerful.',
  },
  EffectKind.haymakerInteraction: {
    SpellAffinity.fire:
        'Stacking fire damage-over-time; damage equals turns remaining, 2 turns at a time.',
    SpellAffinity.earth: 'Target move speed reduced by 1.',
    SpellAffinity.water: 'Target\'s status effects lose a turn.',
    SpellAffinity.air: 'Bonus damage equal to spaces moved toward the target.',
  },
  EffectKind.divination: {
    SpellAffinity.fire:
        'See the target\'s counter-charm alignment; turns bookmarks marking those spells red for the rest of the match.',
    SpellAffinity.earth: 'Identify illusions and see through clouds, 1 turn.',
    SpellAffinity.water: 'See the target\'s available spells, 2 turns.',
    SpellAffinity.air: 'See the target\'s spell target tile, 2 turns.',
  },
};

const Map<EffectKind, String> kEffectNote = {
  EffectKind.damage: 'Instant.',
  EffectKind.barrier: 'Barrier lasts 2 turns.',
  EffectKind.reflections: '2 triggers. Only valid if the spell resolves on an enemy.',
  EffectKind.speedManipulation:
      'Self-targeted flavors are instant; targeted flavors have a duration.',
  EffectKind.statusEffectInteraction: 'Acts on active status effects.',
  EffectKind.chainInteraction: 'Acts on the caster\'s elemental chain bonuses.',
  EffectKind.spellInteraction: 'Acts on the target\'s next spell cast.',
  EffectKind.fuelTransmutation: 'Trades one resource for another.',
  EffectKind.tileModification: '',
  EffectKind.rangeModification: 'Acts on spell range, for 2 turns unless noted.',
  EffectKind.clouds:
      'Radius 1 (2 for Water), 2 turns. Entities in the cloud may only '
          'target/be targeted by adjacent entities.',
  EffectKind.artifactsInteraction: '',
  EffectKind.illusions: 'Illusory copies.',
  EffectKind.multiplierCycles: 'Self-applied immediately. Doubles the power of the caster\'s next '
      'effect of the named element -- right away if one follows later in this spell, otherwise on '
      'the caster\'s next turn. Lasts 2 turns; unused, it expires.',
  EffectKind.haymakerInteraction: 'Lasts 2 turns.',
  EffectKind.divination: 'Information effects.',
};

/// One resolved effect from a formula: the (affinity, kind) pair plus its
/// display name and flavor-text description, resolved via
/// [kAffinityLabel]/[kEffectKindLabel]/[kEffectDescription].
class FormulaEffect {
  const FormulaEffect({
    required this.affinity,
    required this.kind,
    required this.name,
    required this.description,
  });

  final SpellAffinity affinity;
  final EffectKind kind;

  /// "[flavor adjective] [base effect]", e.g. "Firey Blast".
  final String name;

  /// Flavor-text description for this (kind, affinity) pair, from
  /// [kEffectDescription].
  final String description;
}

/// Resolves a stored [formula] list (flat zone names from [SpellAsset.formula])
/// into one [FormulaEffect] per complete triplet. Residuals (1–2 leftover
/// entries) are silently dropped, matching the battle resolution behaviour in
/// TurnLoop._applySpell.
List<FormulaEffect> formulaEffects(List<String> formula) {
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
  final effects = <FormulaEffect>[];
  for (var i = 0; i + 2 < zones.length; i += 3) {
    final affinity = spellAffinityFromZone(zones[i]);
    final kind     = effectKindFromPair(zones[i + 1], zones[i + 2]);
    effects.add(FormulaEffect(
      affinity: affinity,
      kind: kind,
      name: '${kAffinityLabel[affinity]!} ${kEffectKindLabel[kind]!}',
      description: kEffectDescription[kind]![affinity]!,
    ));
  }
  return effects;
}

/// Resolves a stored [formula] list into a list of human-readable effect
/// labels (just the names), one per complete triplet. See [formulaEffects]
/// for the structured form with descriptions.
List<String> formulaEffectLabels(List<String> formula) =>
    [for (final e in formulaEffects(formula)) e.name];

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
