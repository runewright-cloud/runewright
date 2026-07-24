// SPDX-License-Identifier: GPL-3.0-or-later
//
// creature_spec.dart — pure element-sequence -> creature derivation (design
// doc v3.0 "Summons"). Given the full flat activation sequence from a
// summon-mode spell (SpellAsset.formula, or the SNARK-certified equivalent
// from TrajectoryParser.certifiedElementSequence), derives:
//   - affinity: the most-common element, first-appearance tiebreak
//   - stats: floor(elementCount * multiplier) per the "Stats" table
//   - abilities: the 8 element-sequence patterns ("Abilities" table)
//
// No Flutter dependency; fully unit-testable in isolation (creature_spec_test.dart).
//
// Stat formula ("Stats" table, multiplier base is the tuning lever):
//   damage      = floor(fireCount  * 0.5)
//   moveSpeed   = floor(airCount   * 0.5)
//   attackRange = floor(waterCount * 1/3)   // table lists ".33"; exact 1/3 via
//                                            // integer division avoids a
//                                            // float boundary bug at multiples
//                                            // of 3 (floor(3*0.33) = 0 but
//                                            // floor(3*(1/3)) = 1)
//   maxHp       = floor(earthCount * 1) = earthCount
// No minimum floor: a formula with zero of an element yields stat 0,
// including maxHp -- a 0-HP summon dies immediately (generic isAlive/removeWhere
// death-cleanup in turn_loop.dart handles this with no special-casing). Callers
// that preview an about-to-be-cast summon should warn the player when maxHp == 0.

import 'package:rune_duel/engine/border_zone.dart';
import 'package:rune_duel/battle/models/effect_kind.dart' show SpellAffinity;

// ── Stats ─────────────────────────────────────────────────────────────────────

class MinionStats {
  const MinionStats({
    required this.maxHp,
    required this.damage,
    required this.moveSpeed,
    required this.attackRange,
  });

  final int maxHp;
  final int damage;
  final int moveSpeed;
  final int attackRange;

  MinionStats copyWith({int? maxHp, int? damage, int? moveSpeed, int? attackRange}) =>
      MinionStats(
        maxHp: maxHp ?? this.maxHp,
        damage: damage ?? this.damage,
        moveSpeed: moveSpeed ?? this.moveSpeed,
        attackRange: attackRange ?? this.attackRange,
      );

  @override
  String toString() =>
      'MinionStats(hp: $maxHp, dmg: $damage, move: $moveSpeed, range: $attackRange)';

  @override
  bool operator ==(Object other) =>
      other is MinionStats &&
      maxHp == other.maxHp &&
      damage == other.damage &&
      moveSpeed == other.moveSpeed &&
      attackRange == other.attackRange;

  @override
  int get hashCode => Object.hash(maxHp, damage, moveSpeed, attackRange);
}

// ── Abilities ─────────────────────────────────────────────────────────────────

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

// ── Creature spec ─────────────────────────────────────────────────────────────

class CreatureSpec {
  const CreatureSpec({
    required this.affinity,
    required this.stats,
    required this.abilities,
  });

  final SpellAffinity affinity;
  final MinionStats stats;
  final Set<SummonAbility> abilities;

  /// Derives a creature spec from [sequence], the full flat element
  /// activation list for a summon-mode spell (including any trailing
  /// residual — every element counts here, unlike incantation-effect
  /// resolution, which drops residuals).
  ///
  /// Returns null for an empty sequence (a summon-mode spell with no
  /// activations can't be assigned a creature).
  static CreatureSpec? fromElements(List<BorderZone> sequence) {
    if (sequence.isEmpty) return null;
    return CreatureSpec(
      affinity: _affinityOf(sequence),
      stats: _statsOf(sequence),
      abilities: _abilitiesOf(sequence),
    );
  }

  /// "Whatever element appeared the most... If there's a tie whichever
  /// element (between the elements in the tie) appeared first determines
  /// the affinity." Iterating in sequence order and only replacing the
  /// leader on a strict >, not >=, naturally keeps the first element to
  /// reach the max count.
  static SpellAffinity _affinityOf(List<BorderZone> sequence) {
    final counts = <BorderZone, int>{};
    for (final z in sequence) {
      counts[z] = (counts[z] ?? 0) + 1;
    }
    var best = sequence.first;
    var bestCount = 0;
    for (final z in sequence) {
      final c = counts[z]!;
      if (c > bestCount) {
        bestCount = c;
        best = z;
      }
    }
    return _toAffinity(best);
  }

  static MinionStats _statsOf(List<BorderZone> sequence) {
    var nFire = 0, nAir = 0, nWater = 0, nEarth = 0;
    for (final z in sequence) {
      switch (z) {
        case BorderZone.fire:
          nFire++;
        case BorderZone.air:
          nAir++;
        case BorderZone.water:
          nWater++;
        case BorderZone.earth:
          nEarth++;
      }
    }
    return MinionStats(
      maxHp: nEarth,
      damage: nFire ~/ 2,
      moveSpeed: nAir ~/ 2,
      attackRange: nWater ~/ 3,
    );
  }

  static Set<SummonAbility> _abilitiesOf(List<BorderZone> sequence) {
    final initials = sequence.map(_initial).join();
    final found = <SummonAbility>{};
    for (final entry in kSummonAbilityPattern.entries) {
      if (initials.contains(entry.value)) found.add(entry.key);
    }
    return found;
  }

  static String _initial(BorderZone z) => switch (z) {
        BorderZone.fire => 'F',
        BorderZone.air => 'A',
        BorderZone.water => 'W',
        BorderZone.earth => 'E',
      };

  static SpellAffinity _toAffinity(BorderZone z) => switch (z) {
        BorderZone.fire => SpellAffinity.fire,
        BorderZone.air => SpellAffinity.air,
        BorderZone.water => SpellAffinity.water,
        BorderZone.earth => SpellAffinity.earth,
      };
}

// ── Morphic reform (WWWW) ────────────────────────────────────────────────────

/// "Upon death will reform into new creature with half the number of
/// elements rounded down and selected at random." Selects floor(n/2)
/// elements from [original] without replacement via [rng] (must be seeded
/// deterministically — both battle clients must reform identically),
/// preserving their relative order so affinity-tiebreak and ability-pattern
/// matching on the reduced sequence stay meaningful. Returns null if the
/// halved count is 0 (nothing coalesces; the creature just dies).
///
/// One slot is always reserved for an Earth activation when [original]
/// contains at least one (chosen at random among them, same as everything
/// else) — a reform can otherwise draw zero Earth and spawn at 0 maxHp,
/// dying the instant it's created with no combat, no counterplay, and no
/// visible cause (design decision 2026-07-18: a pure-random half-draw could
/// silently kill the whole reform chain on an unlucky roll; guaranteeing one
/// Earth slot keeps the "half the elements, at random" flavor while removing
/// that feel-bad outcome). The other half-1 slots remain fully random. If
/// [original] has zero Earth to begin with, this can't help — same as an
/// original summon cast with zero Earth, which already spawns at 0 maxHp by
/// design (see [CreatureSpec] "No minimum floor" above).
List<BorderZone>? morphicReducedSequence(
    List<BorderZone> original, int Function(int max) nextInt) {
  final half = original.length ~/ 2;
  if (half == 0) return null;

  final earthIndices = [
    for (var i = 0; i < original.length; i++)
      if (original[i] == BorderZone.earth) i,
  ];
  int? reservedIndex;
  var remaining = half;
  if (earthIndices.isNotEmpty) {
    reservedIndex = earthIndices[nextInt(earthIndices.length)];
    remaining = half - 1;
  }

  final pool = [
    for (var i = 0; i < original.length; i++)
      if (i != reservedIndex) i,
  ];
  // Fisher-Yates partial shuffle using the injected RNG (HashRng-compatible;
  // avoids a hard dependency on dart:math's Random type here).
  for (var i = pool.length - 1; i > 0; i--) {
    final j = nextInt(i + 1);
    final tmp = pool[i];
    pool[i] = pool[j];
    pool[j] = tmp;
  }
  final chosen = [
    if (reservedIndex != null) reservedIndex,
    ...pool.take(remaining),
  ]..sort();
  return [for (final i in chosen) original[i]];
}

// ── Resistance wheel ──────────────────────────────────────────────────────────

/// Opposite-element pairs. "A fire summon would take half damage from fire,
/// normal from air and earth, and double damage from water" — fire<->water
/// and (by the same structure) air<->earth are the opposed pairs.
const Map<SpellAffinity, SpellAffinity> _kOpposite = {
  SpellAffinity.fire: SpellAffinity.water,
  SpellAffinity.water: SpellAffinity.fire,
  SpellAffinity.air: SpellAffinity.earth,
  SpellAffinity.earth: SpellAffinity.air,
};

/// Damage multiplier for an [attackType]-typed hit against a creature whose
/// affinity is [defenderAffinity]: same element -> half; opposite element ->
/// double; either adjacent element -> normal.
enum ResistanceTier { resistant, normal, vulnerable }

ResistanceTier resistanceTierOf(SpellAffinity attackType, SpellAffinity defenderAffinity) {
  if (attackType == defenderAffinity) return ResistanceTier.resistant;
  if (_kOpposite[attackType] == defenderAffinity) return ResistanceTier.vulnerable;
  return ResistanceTier.normal;
}

/// Applies the resistance wheel to a raw [amount] of [attackType] damage
/// landing on a creature of [defenderAffinity]. Half damage is rounded up
/// ("half damage rounded up").
int applyResistance(int amount, SpellAffinity attackType, SpellAffinity defenderAffinity) {
  return switch (resistanceTierOf(attackType, defenderAffinity)) {
    ResistanceTier.resistant => (amount + 1) ~/ 2,
    ResistanceTier.vulnerable => amount * 2,
    ResistanceTier.normal => amount,
  };
}

// ── Display (UI-facing; no Flutter dependency, just label maps + strings) ────

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

const Map<SpellAffinity, String> _kCreatureAffinityLabel = {
  SpellAffinity.fire: 'Fire',
  SpellAffinity.earth: 'Earth',
  SpellAffinity.water: 'Water',
  SpellAffinity.air: 'Air',
};

/// Formats [spec] for display, e.g. "Fire Creature · HP 4 · DMG 3 · Move 2 ·
/// Range 1 · Flying, Cleave" (the ability clause is omitted when empty).
String summonSummaryLabel(CreatureSpec spec) {
  final base = '${_kCreatureAffinityLabel[spec.affinity]} Creature · '
      'HP ${spec.stats.maxHp} · DMG ${spec.stats.damage} · '
      'Move ${spec.stats.moveSpeed} · Range ${spec.stats.attackRange}';
  if (spec.abilities.isEmpty) return base;
  final abilityNames = spec.abilities.map((a) => kSummonAbilityLabel[a]).join(', ');
  return '$base · $abilityNames';
}

/// [summonSummaryLabel], parsing a stored [SpellAsset.formula] (zone-name
/// strings) first. Returns null for an empty/void sequence -- callers should
/// show a "Void Summon" fallback in that case.
String? summonSummaryFromFormula(List<String> formula) {
  final sequence = formula.map(_zoneFromName).whereType<BorderZone>().toList();
  final spec = CreatureSpec.fromElements(sequence);
  if (spec == null) return null;
  return summonSummaryLabel(spec);
}

BorderZone? _zoneFromName(String name) => switch (name.toLowerCase()) {
      'fire' => BorderZone.fire,
      'earth' => BorderZone.earth,
      'water' => BorderZone.water,
      'air' => BorderZone.air,
      _ => null,
    };
