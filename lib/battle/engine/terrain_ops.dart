// SPDX-License-Identifier: GPL-3.0-or-later
//
// terrain_ops.dart — damaging, barriering, and destroying spell-placed terrain.
//
// The one place terrain takes damage (docs/WALL_LOS_PLAN.md §2.2). Everything
// that can hurt a tile — a Blast landing on it, the 1-damage fallback from a
// non-applicable effect (§2.4), a Firey terrain barrier's own aura — funnels
// through [damageTerrain] so the resistance wheel, the barrier layers, and the
// destruction bookkeeping all happen exactly once and in one order.
//
// The layering mirrors Minion.takeDamage exactly, which is the point: terrain
// is damaged "exactly as creatures do" (§2.2/§3.8), so there is no second
// damage model to keep in sync.
//
//   1. resistance wheel, against the tile type's fixed affinity (§2.2)
//   2. barrier layers, in element order (fire → earth → water → air)
//   3. the tile's own HP pool
//
// The maps live on BattleState (terrainHp / terrainBarriers) rather than on
// TileEffect, which is deliberately immutable — see BattleState.placeTerrain /
// .removeTerrain, which are the only sanctioned way to add or drop a tile.

import 'dart:math';

import 'package:rune_duel/engine/hex_grid.dart';
import 'package:rune_duel/battle/models/barrier.dart';
import 'package:rune_duel/battle/models/battle_state.dart';
import 'package:rune_duel/battle/models/creature_spec.dart' show applyResistance;
import 'package:rune_duel/battle/models/effect_kind.dart' show SpellAffinity;
import 'package:rune_duel/battle/models/hex_battlefield.dart'
    show hexDistance, hexNeighbors;
import 'package:rune_duel/battle/models/minion.dart' show SummonAbility;
import 'package:rune_duel/battle/models/terrain.dart';
import 'package:rune_duel/battle/models/wizard_avatar.dart' show WizardAvatar;

import 'tile_entry_resolver.dart';

/// What one hit on a terrain tile actually did.
class TerrainHit {
  const TerrainHit({
    required this.hitSomething,
    required this.destroyed,
    required this.hpDealt,
  });

  /// There was destructible terrain (or an illusory copy) on the tile at all.
  /// False means the damage found nothing — the caller should not report a
  /// terrain hit to the UI, and the tile is unchanged.
  final bool hitSomething;

  /// The tile was destroyed by this hit and has been removed from every map.
  final bool destroyed;

  /// Damage that reached the tile's own HP pool, after the resistance wheel
  /// and after any barrier layers absorbed their share. Purely informational.
  final int hpDealt;

  static const none =
      TerrainHit(hitSomething: false, destroyed: false, hpDealt: 0);
}

/// Deals [amount] of [attackType]-typed damage to whatever terrain occupies
/// [hex].
///
/// An illusory copy (Earthen Illusions) dies to any damage at all, before the
/// wheel is even consulted — it is 1 HP by design and must never inherit the
/// real type's pool (§3.7).
///
/// [rng] is only consumed when an Airy terrain barrier collapses and its
/// knockback lands someone on a conveyor (see [_collapseKnockback]); pass the
/// caller's shared deterministic per-turn RNG so both peers replay identically.
TerrainHit damageTerrain(
  BattleState state,
  HexCoord hex,
  int amount,
  SpellAffinity attackType,
  Random rng,
) {
  if (amount <= 0) return TerrainHit.none;

  // Illusory terrain: 1 HP, destroyed by any damage touching its tile.
  if (state.illusionTerrainTiles.containsKey(hex)) {
    state.removeTerrain(hex);
    return const TerrainHit(hitSomething: true, destroyed: true, hpDealt: 1);
  }

  final effect = state.tileEffects[hex];
  if (!tileIsDestructibleTerrain(effect)) return TerrainHit.none;
  final affinity = terrainAffinityOf(effect)!;

  var remaining = applyResistance(amount, attackType, affinity);

  final barriers = state.terrainBarriers[hex];
  if (barriers != null) {
    for (final element in SpellAffinity.values) {
      final b = barriers[element];
      if (b == null || !b.isAlive || remaining <= 0) continue;
      remaining = b.absorb(remaining);
      if (!b.isAlive) {
        barriers.remove(element);
        // Airy terrain barrier: on collapse, shove every wizard and summon
        // adjacent to the tile one step out (§2.6). Replaces the caster's
        // free-move rider, which made no sense on remote terrain that may
        // collapse turns later on somebody else's turn.
        if (b.freeMoveOnCollapse) _collapseKnockback(state, hex, rng);
      }
    }
    if (barriers.isEmpty) state.terrainBarriers.remove(hex);
  }

  if (remaining <= 0) {
    return const TerrainHit(hitSomething: true, destroyed: false, hpDealt: 0);
  }

  final hp = (state.terrainHp[hex] ?? terrainMaxHpOf(effect)) - remaining;
  if (hp <= 0) {
    state.removeTerrain(hex);
    return TerrainHit(hitSomething: true, destroyed: true, hpDealt: remaining);
  }
  state.terrainHp[hex] = hp;
  return TerrainHit(hitSomething: true, destroyed: false, hpDealt: remaining);
}

/// Imbues [hex]'s terrain with [barrier], replacing any barrier of the same
/// element (not stacking) exactly as a barrier on an avatar does.
///
/// Silently no-ops on a tile with no destructible terrain: a barrier needs an
/// HP pool to sit in front of.
bool addTerrainBarrier(BattleState state, HexCoord hex, BarrierState barrier) {
  if (!tileIsDestructibleTerrain(state.tileEffects[hex])) return false;
  // An illusory copy is 1 HP by design; armoring it would make Earthen
  // Illusions a way to mint real terrain (§3.7).
  if (state.illusionTerrainTiles.containsKey(hex)) return false;
  (state.terrainBarriers[hex] ??= {})[barrier.element] = barrier;
  return true;
}

/// Ticks every terrain barrier's duration by one turn and drops the collapsed
/// ones, mirroring WizardAvatar.tickBarriers. An Airy barrier that runs out of
/// *time* rather than HP knocks back the same way (§2.6 says "on collapse",
/// not "on burst").
void tickTerrainBarriers(BattleState state, Random rng) {
  // Sorted so both peers resolve collapses (and their knockbacks) in one
  // order — the map is keyed by coord, but the knockbacks mutate shared
  // occupancy, so the order is observable.
  final coords = state.terrainBarriers.keys.toList()..sort(_byCoord);
  for (final hex in coords) {
    final barriers = state.terrainBarriers[hex];
    if (barriers == null) continue;
    for (final element in SpellAffinity.values) {
      final b = barriers[element];
      if (b == null) continue;
      if (b.tick()) continue;
      barriers.remove(element);
      if (b.freeMoveOnCollapse) _collapseKnockback(state, hex, rng);
    }
    if (barriers.isEmpty) state.terrainBarriers.remove(hex);
  }
}

/// End-of-turn riders carried by terrain barriers (§2.6):
///   - Firey: a burning wall deals 1 fire damage to every adjacent tile.
///   - Watery: mana regen to whoever occupies the tile. Inert on a wall
///     nobody can stand in, live on lava/slow/conveyor — which is precisely
///     why the scope covers all four terrain types and not just walls (§4).
///
/// [manaGain] is the caller's mana-award closure (TurnLoop._applyManaGain), so
/// terrain regen goes through the same clamping and bookkeeping every other
/// mana source does.
void tickTerrainBarrierAuras(
  BattleState state,
  Random rng,
  void Function(WizardAvatar avatar, int amount) manaGain,
) {
  final coords = state.terrainBarriers.keys.toList()..sort(_byCoord);
  for (final hex in coords) {
    final barriers = state.terrainBarriers[hex];
    if (barriers == null) continue;

    final fire = barriers[SpellAffinity.fire];
    if (fire != null && fire.isAlive && fire.fireAura) {
      for (final n in hexNeighbors(hex)) {
        for (final av in state.avatars) {
          if (av.isAlive && av.position == n) av.absorbDamage(1);
        }
        for (final m in state.minions) {
          if (m.isAlive && m.occupiedTiles.contains(n)) {
            m.takeDamage(1, attackType: SpellAffinity.fire);
          }
        }
        // The aura is fire damage like any other, so it erodes neighbouring
        // terrain too — a burning wall chews through the lava next to it.
        damageTerrain(state, n, 1, SpellAffinity.fire, rng);
      }
    }

    final water = barriers[SpellAffinity.water];
    if (water != null && water.isAlive && water.manaRegenBonusPct > 0) {
      for (final av in state.avatars) {
        if (!av.isAlive || av.position != hex) continue;
        manaGain(av, (av.maxMana * water.manaRegenBonusPct / 100).round());
      }
    }
  }
}

/// Shoves every wizard and summon adjacent to [hex] one tile directly away
/// from it, at the moment an Airy terrain barrier collapses.
///
/// Multi-tile bodies are immovable by exterior forces, the same rule
/// EffectApplicator._knockbackMinion applies. A push that would leave the
/// battlefield or land on movement-blocking terrain simply doesn't happen —
/// there is nowhere to go.
void _collapseKnockback(BattleState state, HexCoord hex, Random rng) {
  // Sorted by id so both peers push in the same order: a push can be blocked
  // by another entity's post-push position, so the order is observable.
  final avatars = state.avatars.where((a) => a.isAlive).toList()
    ..sort((a, b) => a.playerId.compareTo(b.playerId));
  for (final av in avatars) {
    if (hexDistance(av.position, hex) != 1) continue;
    final landed = _pushTarget(state, hex, av.position);
    if (landed == null) continue;
    final outcome = resolveTileEntry(
      state: state,
      rng: rng,
      enteredTile: landed,
      flying: false,
      currentHp: av.hp,
    );
    av.position = outcome.finalPosition;
    state.battlefield.occupancy[av.playerId] = outcome.finalPosition;
    if (outcome.totalDamage > 0) av.absorbDamage(outcome.totalDamage);
  }

  final minions = state.minions.where((m) => m.isAlive).toList()
    ..sort((a, b) => a.id.compareTo(b.id));
  for (final m in minions) {
    if (m.occupiedTiles.length > 1) continue; // immovable body
    if (m.distanceTo(hex) != 1) continue;
    final landed = _pushTarget(state, hex, m.position);
    if (landed == null) continue;
    final outcome = resolveTileEntry(
      state: state,
      rng: rng,
      enteredTile: landed,
      flying: m.abilities.contains(SummonAbility.flying),
      currentHp: m.hp,
    );
    m.position = outcome.finalPosition;
    if (outcome.totalDamage > 0) m.takeDamage(outcome.totalDamage);
  }
}

/// One tile further along the [source] → [from] direction, or null when that
/// tile is off the field or blocked.
HexCoord? _pushTarget(BattleState state, HexCoord source, HexCoord from) {
  final dq = from.q - source.q;
  final dr = from.r - source.r;
  if (dq == 0 && dr == 0) return null;
  HexCoord? best;
  var bestDot = -1 << 30;
  for (final d in HexGrid.directions) {
    final dot = dq * d.q + dr * d.r;
    if (dot > bestDot) {
      bestDot = dot;
      best = d;
    }
  }
  final pushed = HexCoord(from.q + best!.q, from.r + best.r);
  if (!state.battlefield.isInBounds(pushed)) return null;
  if (tileBlocksMovement(state.tileEffects[pushed])) return null;
  return pushed;
}

int _byCoord(HexCoord a, HexCoord b) {
  final qc = a.q.compareTo(b.q);
  return qc != 0 ? qc : a.r.compareTo(b.r);
}
