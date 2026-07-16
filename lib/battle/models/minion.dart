// SPDX-License-Identifier: GPL-3.0-or-later
//
// minion.dart — Minion: a summoned creature (design doc v3.0 "Summons").
//
// Replaces the earlier Sprite/Hound (v2.4) model: a single concrete
// creature class whose identity is fully derived from the inscribing
// spell's element sequence via CreatureSpec.fromElements (creature_spec.dart)
// — affinity, stats, and abilities — plus a personality assigned separately
// (glyph-assigned per design; no UI this pass, see SpellAsset.summonPersonality).
//
// Summon open TODOs (design doc "Summons", all [TODO — playtest]):
//   - Lifespan: indefinite (no expiry turn) until destroyed.
//   - Cap: none for now.
//   - AoE friendly fire: possible (affects caster's own summons).

import 'dart:math' show min;

import 'package:rune_duel/engine/hex_grid.dart';
import 'package:rune_duel/engine/border_zone.dart';
import 'package:rune_duel/battle/models/barrier.dart';
import 'package:rune_duel/battle/models/creature_spec.dart';
import 'package:rune_duel/battle/models/effect_kind.dart' show SpellAffinity;
import 'package:rune_duel/battle/models/hex_battlefield.dart' show hexDistance, hexNeighbors;
import 'package:rune_duel/battle/models/status_effect_ids.dart';
import 'package:rune_duel/battle/models/wizard_avatar.dart' show StatusEffect;

export 'creature_spec.dart' show MinionStats, SummonAbility;

// ── Personality ───────────────────────────────────────────────────────────────

/// Battlefield behavior assigned to a summon (design doc "Personalities").
/// Glyph-assigned at inscription time in the design; no picker UI exists yet
/// this pass — [SpellAsset.summonPersonality] defaults to [aggressive].
enum SummonPersonality {
  /// "Move on path most directly to nearest enemy... not particularly
  /// intelligent." The v2.4 hound's behavior generalized to all creatures.
  aggressive,

  /// "Try to put themselves at a distance from all enemies while still being
  /// in attack range of at least one. Prefer targeting players in ties."
  evasive,

  /// "Prioritize trying to insert themselves between their summoner and
  /// other hostile entities."
  protective,

  /// "Prioritize trying to slay targets with the fewest hitpoints. Factoring
  /// in resistances and vulnerabilities."
  tactical,
}

/// Friendly display names for [SummonPersonality] -- for the inscription-time
/// picker (design doc: "glyphs may be added to force a particular
/// personality"). Lives here rather than creature_spec.dart to avoid an
/// import cycle (this file already imports creature_spec.dart).
const Map<SummonPersonality, String> kSummonPersonalityLabel = {
  SummonPersonality.aggressive: 'Aggressive',
  SummonPersonality.evasive: 'Evasive',
  SummonPersonality.protective: 'Protective',
  SummonPersonality.tactical: 'Tactical',
};

// ── Footprint geometry (Big / EEEE) ───────────────────────────────────────────

/// The tiles a creature with [abilities] occupies when centered at [center].
/// Non-Big creatures occupy a single tile. Big creatures occupy a
/// deterministic 3-tile triangle: [center] plus its first two neighbors in
/// [hexNeighbors] order (consecutive hex directions are 60° apart, so those
/// two neighbors are themselves mutually adjacent — a true triangle, not an
/// arbitrary pair).
List<HexCoord> footprintFor(HexCoord center, Set<SummonAbility> abilities) {
  if (!abilities.contains(SummonAbility.big)) return [center];
  final ns = hexNeighbors(center);
  return [center, ns[0], ns[1]];
}

// ── Minion ────────────────────────────────────────────────────────────────────

class Minion {
  Minion({
    required this.id,
    required this.ownerId,
    required this.teamId,
    required this.position,
    required this.affinity,
    required this.stats,
    required this.elementSequence,
    Set<SummonAbility>? abilities,
    this.personality = SummonPersonality.aggressive,
    int? hp,
    List<StatusEffect>? activeStatusEffects,
    Map<SpellAffinity, BarrierState>? barriers,
    this.actedThisTurn = false,
    this.forceCloseToAttack = false,
  })  : abilities = abilities ?? const {},
        hp = hp ?? stats.maxHp,
        activeStatusEffects = activeStatusEffects ?? [],
        barriers = barriers ?? {};

  final String id;
  final String ownerId;
  final String teamId;
  HexCoord position;

  /// Elemental affinity — the most-common element in [elementSequence]
  /// (first-appearance tiebreak). Drives the token colour, the damage type
  /// this creature deals, and its own resistance-wheel weakness/resistance.
  final SpellAffinity affinity;

  final MinionStats stats;

  /// Set once at creation from [CreatureSpec.abilities]; see SummonAbility.
  final Set<SummonAbility> abilities;

  /// The full element activation sequence this creature was derived from —
  /// retained (not just the derived spec) so Morphic (WWWW) can re-derive a
  /// smaller creature from a random half of it on death.
  final List<BorderZone> elementSequence;

  SummonPersonality personality;

  int hp;
  bool actedThisTurn;

  /// Water-Air Illusions (Fire flavor): an illusory clone that always closes
  /// to attack rather than following its personality's normal positioning
  /// (e.g. an Evasive original's kiting is skipped for its clone).
  final bool forceCloseToAttack;

  final List<StatusEffect> activeStatusEffects;
  final Map<SpellAffinity, BarrierState> barriers;

  bool get isAlive => hp > 0;

  /// Tiles this creature occupies. See [footprintFor].
  List<HexCoord> get occupiedTiles => footprintFor(position, abilities);

  /// Minimum hex distance from any of this creature's occupied tiles to [point].
  int distanceTo(HexCoord point) =>
      occupiedTiles.map((t) => hexDistance(t, point)).reduce(min);

  /// Applies the elemental resistance wheel (if [attackType] is given), then
  /// absorbs through active barriers, then real HP.
  void takeDamage(int amount, {SpellAffinity? attackType}) {
    var remaining =
        attackType != null ? applyResistance(amount, attackType, affinity) : amount;
    for (final element in SpellAffinity.values) {
      final b = barriers[element];
      if (b == null || !b.isAlive || remaining <= 0) continue;
      remaining = b.absorb(remaining);
      if (!b.isAlive) barriers.remove(element);
    }
    if (remaining > 0) hp = (hp - remaining).clamp(0, stats.maxHp);
  }

  int get effectiveMoveSpeed {
    var speed = stats.moveSpeed;
    for (final fx in activeStatusEffects) {
      if (fx.isDormant) continue;
      if (fx.effectTypeId == StatusEffectId.speedUp ||
          fx.effectTypeId == StatusEffectId.speedDown) {
        speed += fx.modifiers['speedDelta'] ?? 0;
      }
    }
    return speed.clamp(0, 999);
  }

  int get effectiveAttackRange {
    var range = stats.attackRange;
    for (final fx in activeStatusEffects) {
      if (fx.isDormant) continue;
      if (fx.effectTypeId == StatusEffectId.rangeUp ||
          fx.effectTypeId == StatusEffectId.rangeDown) {
        range += fx.modifiers['rangeDelta'] ?? 0;
      }
    }
    return range.clamp(1, 999);
  }

  /// Morphic (WWWW): on death, reforms into a new creature derived from half
  /// (rounded down) of [elementSequence], chosen at random via [nextInt]
  /// (pass a seeded HashRng.nextInt so both battle clients reform
  /// identically). Returns an empty list if this creature isn't Morphic, or
  /// if the halved sequence would be empty (nothing coalesces).
  ///
  /// The reformed creature spawns on this creature's own tile (or its
  /// footprint's first tile) with a fresh id built from [newId].
  List<Minion> onDeath(int Function(int max) nextInt, String newId) {
    if (!abilities.contains(SummonAbility.morphic)) return const [];
    final reduced = morphicReducedSequence(elementSequence, nextInt);
    if (reduced == null) return const [];
    final spec = CreatureSpec.fromElements(reduced);
    if (spec == null) return const [];
    return [
      Minion(
        id: newId,
        ownerId: ownerId,
        teamId: teamId,
        position: occupiedTiles.first,
        affinity: spec.affinity,
        stats: spec.stats,
        elementSequence: reduced,
        abilities: spec.abilities,
        personality: personality,
      ),
    ];
  }
}
