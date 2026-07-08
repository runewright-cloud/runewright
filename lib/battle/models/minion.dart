// SPDX-License-Identifier: GPL-3.0-or-later
//
// minion.dart — SpiritMinion and HoundMinion: the two summonable families.
//
// Creature family is determined by the formula ordered pair (design doc §summons
// — the ordered-pair mirror is a protected systemic asset):
//   Fire-Earth → Spirit (agile, ranged, pass-through tile, ignores terrain)
//   Earth-Fire → Hound  (melee, sturdy, occupies tile, blocked by terrain)
//
// The affinity (first triplet entry) selects a flavor variant that modifies
// the base stat block. Base stats + stated deltas are implemented; the design
// doc's arrow-notation final values (→4, →8, →12, →5) are inconsistent with
// base + delta in several cases — values marked [doc arrow says →N] for
// reconciliation during playtesting.
//
// Summon open TODOs (design doc §summons, all [TODO — playtest]):
//   - Lifespan: indefinite (no expiry turn) until destroyed.
//   - Cap: none for now.
//   - Spirits: pass-through (don't block movement).
//   - Hounds: occupy their tile (block movement).
//   - AoE friendly fire: possible (affects caster's own summons).

import 'package:rune_duel/engine/hex_grid.dart';
import 'package:rune_duel/battle/models/barrier.dart';
import 'package:rune_duel/battle/models/effect_kind.dart' show SpellAffinity;
import 'package:rune_duel/battle/models/status_effect_ids.dart';
import 'package:rune_duel/battle/models/wizard_avatar.dart' show StatusEffect;

// ── Stat block ────────────────────────────────────────────────────────────────

class MinionStats {
  const MinionStats({
    required this.maxHp,
    required this.damage,
    required this.moveSpeed,
    required this.attackRange,
    this.splashRadius = 0,
    this.knockback = 0,
    this.ignoresTerrain = false,
  });

  final int maxHp;
  final int damage;
  final int moveSpeed;

  /// Ranged attack radius in tiles. Spirits default to 4; hounds to 1 (melee).
  final int attackRange;

  /// AoE attack radius for Water flavor variants (0 = single target).
  final int splashRadius;

  /// Tiles pushed on hit for Air spirit variant (0 = no knockback).
  final int knockback;

  /// Spirits fly over terrain effects (FloorIsLava, SlowTile, ImpassableTile).
  final bool ignoresTerrain;

  MinionStats copyWith({
    int? maxHp,
    int? damage,
    int? moveSpeed,
    int? attackRange,
    int? splashRadius,
    int? knockback,
    bool? ignoresTerrain,
  }) =>
      MinionStats(
        maxHp: maxHp ?? this.maxHp,
        damage: damage ?? this.damage,
        moveSpeed: moveSpeed ?? this.moveSpeed,
        attackRange: attackRange ?? this.attackRange,
        splashRadius: splashRadius ?? this.splashRadius,
        knockback: knockback ?? this.knockback,
        ignoresTerrain: ignoresTerrain ?? this.ignoresTerrain,
      );
}

// ── Base stat blocks ──────────────────────────────────────────────────────────

const _spiritBase = MinionStats(
  maxHp: 2, damage: 1, moveSpeed: 1, attackRange: 4, ignoresTerrain: true,
);

const _houndBase = MinionStats(
  maxHp: 4, damage: 2, moveSpeed: 2, attackRange: 1,
);

// ── Flavor builders ───────────────────────────────────────────────────────────

/// Stat block for a Spirit (Fire-Earth-[affinity]) with the given flavor.
MinionStats spiritStats(SpellAffinity affinity) => switch (affinity) {
      SpellAffinity.fire => _spiritBase.copyWith(
          damage: _spiritBase.damage + 2), // +2 → 3 [doc arrow says →4]
      SpellAffinity.earth => _spiritBase.copyWith(
          maxHp: _spiritBase.maxHp + 2), // +2 → 4 [doc arrow says →8]
      SpellAffinity.water => _spiritBase.copyWith(splashRadius: 1),
      SpellAffinity.air => _spiritBase.copyWith(knockback: 1),
    };

/// Stat block for a Hound (Earth-Fire-[affinity]) with the given flavor.
MinionStats houndStats(SpellAffinity affinity) => switch (affinity) {
      SpellAffinity.fire => _houndBase.copyWith(
          damage: _houndBase.damage + 2), // +2 → 4 ✓
      SpellAffinity.earth => _houndBase.copyWith(
          maxHp: _houndBase.maxHp + 4), // +4 → 8 [doc arrow says →12]
      SpellAffinity.water => _houndBase.copyWith(splashRadius: 1),
      SpellAffinity.air => _houndBase.copyWith(
          moveSpeed: _houndBase.moveSpeed + 2), // +2 → 4 [doc arrow says →5]
    };

// ── Minion classes ────────────────────────────────────────────────────────────

sealed class Minion {
  Minion({
    required this.id,
    required this.ownerId,
    required this.teamId,
    required this.position,
    required this.affinity,
    required this.stats,
    List<StatusEffect>? activeStatusEffects,
    Map<SpellAffinity, BarrierState>? barriers,
    this.actedThisTurn = false,
    this.aggressive = false,
  })  : hp = stats.maxHp,
        activeStatusEffects = activeStatusEffects ?? [],
        barriers = barriers ?? {};

  final String id;
  final String ownerId;
  final String teamId;
  HexCoord position;

  /// Elemental affinity selected by the first triplet entry — determines the
  /// token colour and drives any affinity-keyed stat modifiers.
  final SpellAffinity affinity;

  final MinionStats stats;
  int hp;
  bool actedThisTurn;

  /// Water-Air Illusions (Fire flavor): an illusory clone that always closes
  /// to attack rather than following its normal positioning AI (a Spirit's
  /// range-kiting is skipped -- see TurnLoop._spiritTurn).
  final bool aggressive;
  final List<StatusEffect> activeStatusEffects;
  final Map<SpellAffinity, BarrierState> barriers;

  bool get isAlive => hp > 0;

  /// Absorb damage through active barriers first, then real HP.
  void takeDamage(int amount) {
    var remaining = amount;
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

  /// Summon AI priorities (design doc §summons):
  ///   Spirits — maintain attackRange distance from nearest enemy, then attack.
  ///   Hounds  — move directly toward nearest enemy, then attack.
  /// Concrete AI movement is handled by TurnLoop._resolveSummons.
}

/// Spirit — Fire-Earth formula. Ranged, fragile, ignores terrain, pass-through.
class SpiritMinion extends Minion {
  SpiritMinion({
    required super.id,
    required super.ownerId,
    required super.teamId,
    required super.position,
    required super.affinity,
    required super.stats,
    super.activeStatusEffects,
    super.barriers,
    super.actedThisTurn,
    super.aggressive,
  });

  /// Effective attack range, accounting for rangeUp/rangeDown status effects.
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
}

/// Hound — Earth-Fire formula. Melee, sturdy, occupies its tile.
class HoundMinion extends Minion {
  HoundMinion({
    required super.id,
    required super.ownerId,
    required super.teamId,
    required super.position,
    required super.affinity,
    required super.stats,
    super.activeStatusEffects,
    super.barriers,
    super.actedThisTurn,
    super.aggressive,
  });
}
