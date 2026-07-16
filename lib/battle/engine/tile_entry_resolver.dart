// SPDX-License-Identifier: GPL-3.0-or-later
//
// tile_entry_resolver.dart — what happens when an entity (wizard avatar or
// minion) enters a tile, regardless of cause: voluntary movement's final
// tile, a knockback/push landing them there, or a conveyor tile pushing them
// into another. Single source of truth for FloorIsLava-on-entry damage and
// ConveyorTile cascading pushes, including closed-loop detection.
//
// Callers own the actual entity (WizardAvatar/Minion) and are responsible
// for applying the returned TileEntryOutcome back onto it -- this file only
// computes the outcome against BattleState, entity-agnostically.
//
// Loop mechanic (design intent, see docs/M4_findings.md / conversation with
// Soren): a chain of conveyor tiles can form a closed loop. On entering one,
// the entity traverses the whole loop, then exits into a random adjacent
// tile not part of the loop, taking (loopLength + extraTilesSearched) ~/ 3
// damage. If the first loop tile searched has no valid exit (all neighbors
// occupied/impassable/out of bounds), the search continues to the next tile
// around the loop, adding to the damage divisor. If no tile in the loop has
// any valid exit and the loop is long enough to ever deal damage
// (loopLength ~/ 3 > 0), the entity is killed -- dealt lethal damage across
// repeated loop passes for the animation. If the loop is too short to ever
// deal damage that way (loopLength ~/ 3 == 0, i.e. a fully-blocked 2-tile
// loop) it instead crashes into whichever entity is blocking an exit with
// the lowest current HP: both deal damage equal to their own pre-collision
// HP to the other simultaneously, guaranteeing the lower-HP entity of the
// pair dies (a tie kills both) -- either freeing the exit so the looped
// entity escapes onto the dead blocker's tile, or killing the looped entity
// where it stands. See _resolveCrashIntoBlocker.

import 'dart:math';

import 'package:rune_duel/engine/hex_grid.dart';
import 'package:rune_duel/battle/models/battle_state.dart';
import 'package:rune_duel/battle/models/hex_battlefield.dart' show hexDistance;
import 'package:rune_duel/battle/models/terrain.dart';

/// Result of resolving tile-entry effects (lava damage, conveyor pushes,
/// including cascades and closed loops) starting from one entered tile.
class TileEntryOutcome {
  const TileEntryOutcome({
    required this.finalPosition,
    required this.totalDamage,
    required this.killed,
    required this.animationPath,
  });

  final HexCoord finalPosition;
  final int totalDamage;
  final bool killed;

  /// Every tile visited, in order, starting with the entered tile -- for the
  /// UI to animate a "riding the belt" / loop-traversal playback.
  final List<HexCoord> animationPath;
}

/// Emitted whenever [resolveTileEntry] actually moves an entity through one
/// or more conveyor tiles (straight cascade or a closed loop), for the UI to
/// animate a "riding the belt" / loop-traversal playback. Not emitted for a
/// tile-entry resolution that didn't involve any conveyor tile at all.
class ConveyorChainEvent {
  const ConveyorChainEvent({
    required this.entityId,
    required this.path,
    required this.damage,
    required this.killed,
  });

  /// playerId for a wizard avatar, Minion.id for a minion.
  final String entityId;
  final List<HexCoord> path;
  final int damage;
  final bool killed;
}

/// Safety cap on how many full loop passes get animated in a death-spiral
/// resolution -- the damage math is always fully lethal regardless of this
/// cap; it only bounds how long [TileEntryOutcome.animationPath] gets.
const int _kMaxAnimatedLoopPasses = 4;

const List<HexCoord> _kNeighborDirs = [
  HexCoord(1, 0), HexCoord(1, -1), HexCoord(0, -1),
  HexCoord(-1, 0), HexCoord(-1, 1), HexCoord(0, 1),
];

HexCoord _add(HexCoord a, HexCoord b) => HexCoord(a.q + b.q, a.r + b.r);

List<HexCoord> _neighborsOf(HexCoord h) =>
    _kNeighborDirs.map((d) => _add(h, d)).toList();

bool _isOccupied(BattleState state, HexCoord hex) =>
    state.avatars.any((a) => a.isAlive && a.position == hex) ||
    state.minions.any((m) => m.isAlive && m.occupiedTiles.contains(hex));

/// Resolves tile-entry effects starting at [enteredTile]. Pure/deterministic
/// given [rng] -- does not mutate [state] or any entity; the caller applies
/// the returned [TileEntryOutcome] back onto whichever entity moved.
///
/// [applyEntryLava] should be false when the caller already separately
/// charges lava damage for the entered tile (e.g. avatars'/minions' own
/// per-tile-traversed voluntary-movement damage) to avoid double-counting;
/// true (default) everywhere else (knockback, cascading pushes). This only
/// ever matters for [enteredTile] itself -- every subsequent tile in a
/// cascade is by construction a ConveyorTile, never lava.
///
/// [footprintValid] lets multi-tile (Big/EEEE) minions reject a candidate
/// tile whose full footprint wouldn't fit; null for single-tile entities.
TileEntryOutcome resolveTileEntry({
  required BattleState state,
  required Random rng,
  required HexCoord enteredTile,
  required bool flying,
  required int currentHp,
  bool applyEntryLava = true,
  bool Function(HexCoord)? footprintValid,
}) {
  var totalDamage = 0;
  final enterEffect = state.tileEffects[enteredTile];
  if (enterEffect is FloorIsLava && !flying && applyEntryLava) {
    totalDamage += enterEffect.damage;
  }

  final chain = _walkChain(
    state: state, start: enteredTile, flying: flying, footprintValid: footprintValid);
  if (chain.loop != null) {
    return _resolveLoop(
      state: state,
      rng: rng,
      loop: chain.loop!,
      pathSoFar: chain.path,
      damageSoFar: totalDamage,
      currentHp: currentHp,
      footprintValid: footprintValid,
    );
  }

  return TileEntryOutcome(
    finalPosition: chain.current,
    totalDamage: totalDamage,
    killed: false,
    animationPath: chain.path,
  );
}

/// Walks a conveyor chain from [start] until it stops (not a directed
/// conveyor, flying, or the next tile is blocked) or detects a closed loop.
/// Shared by [resolveTileEntry] (which resolves a detected loop with [rng])
/// and [predictTileEntry] (which can't -- RNG isn't available client-side
/// before entropy reveal -- and just reports that a loop was hit).
({HexCoord current, List<HexCoord> path, List<HexCoord>? loop}) _walkChain({
  required BattleState state,
  required HexCoord start,
  required bool flying,
  bool Function(HexCoord)? footprintValid,
}) {
  bool canEnter(HexCoord hex) {
    if (!state.battlefield.isInBounds(hex)) return false;
    if (state.tileEffects[hex] is ImpassableTile) return false;
    if (footprintValid != null && !footprintValid(hex)) return false;
    return true;
  }

  var current = start;
  final path = <HexCoord>[current];
  final visited = <HexCoord>[current];

  while (true) {
    final effect = state.tileEffects[current];
    if (flying || effect is! ConveyorTile || !effect.directionSet) break;

    final next = _add(current, effect.direction);
    if (visited.contains(next)) {
      // Closed loop: visited[loopStart..] is the cyclic tile sequence.
      final loopStart = visited.indexOf(next);
      return (current: current, path: path, loop: visited.sublist(loopStart));
    }
    if (!canEnter(next)) break; // blocked -- stop here, no cascade
    current = next;
    path.add(current);
    visited.add(current);
  }

  return (current: current, path: path, loop: null);
}

/// A deterministic (no-RNG) preview of what [resolveTileEntry] would do
/// entering [enteredTile] right now, for client-side move-path planning
/// before a turn is submitted -- entropy (and so the seeded RNG loop
/// resolution needs) isn't known until after both players commit their
/// actions. Shares [_walkChain] with the real resolver, so the deterministic
/// portion (no loop involved) is guaranteed byte-identical to what actually
/// happens; if the chain would enter a closed loop, this stops there and
/// reports it as indeterminate rather than guessing at RNG-dependent output.
TileEntryPrediction predictTileEntry({
  required BattleState state,
  required HexCoord enteredTile,
  required bool flying,
  bool Function(HexCoord)? footprintValid,
}) {
  final chain = _walkChain(
    state: state, start: enteredTile, flying: flying, footprintValid: footprintValid);
  return TileEntryPrediction(
    finalPosition: chain.current,
    path: chain.path,
    enteredIndeterminateLoop: chain.loop != null,
  );
}

/// Result of [predictTileEntry].
class TileEntryPrediction {
  const TileEntryPrediction({
    required this.finalPosition,
    required this.path,
    required this.enteredIndeterminateLoop,
  });

  /// Position after the deterministic portion of the walk. If
  /// [enteredIndeterminateLoop] is true, this is the tile where the loop was
  /// first detected -- the true final position depends on RNG not knowable
  /// client-side.
  final HexCoord finalPosition;

  /// Every tile visited, in order, starting with the entered tile.
  final List<HexCoord> path;

  /// True if the chain would enter a closed loop -- its true resolution
  /// (exit tile or crash-into-blocker) depends on post-entropy RNG this
  /// preview can't know.
  final bool enteredIndeterminateLoop;
}

/// Client-side prediction of [TurnLoop._walkAvatar]'s real walk, for
/// interactive move-path planning. Mirrors the same budget/terrain rules
/// (SlowTile cost, ImpassableTile blocking, ConveyorTile pushes -- via
/// [predictTileEntry] -- with any remaining budget then continuing to walk
/// [declaredPath] from wherever the push left off); stops early and reports
/// [MovePathPrediction.indeterminate] the moment a conveyor chain would
/// enter a closed loop.
MovePathPrediction predictAvatarMove({
  required BattleState state,
  required HexCoord origin,
  required List<HexCoord> declaredPath,
  required int budget,
}) {
  var current = origin;
  var remaining = budget;
  final path = <HexCoord>[origin];

  for (final step in declaredPath) {
    if (remaining <= 0) break;
    if (!state.battlefield.isInBounds(step)) break;
    if (hexDistance(current, step) != 1) break;
    final effect = state.tileEffects[step];
    if (effect is ImpassableTile) break;
    final cost = 1 + (effect is SlowTile ? effect.extraMoveCost : 0);
    if (cost > remaining) break;
    remaining -= cost;
    current = step;
    path.add(current);

    if (effect is ConveyorTile && effect.directionSet) {
      final prediction = predictTileEntry(state: state, enteredTile: current, flying: false);
      current = prediction.finalPosition;
      path.addAll(prediction.path.skip(1));
      if (prediction.enteredIndeterminateLoop) {
        return MovePathPrediction(path: path, budgetRemaining: remaining, indeterminate: true);
      }
    }
  }
  return MovePathPrediction(path: path, budgetRemaining: remaining, indeterminate: false);
}

/// Result of [predictAvatarMove].
class MovePathPrediction {
  const MovePathPrediction({
    required this.path,
    required this.budgetRemaining,
    required this.indeterminate,
  });

  /// Every tile visited, in order, starting with the origin -- voluntary
  /// steps AND any tiles a conveyor pushed through for free.
  final List<HexCoord> path;

  /// Movement budget left unspent (0 if exhausted, blocked, or stopped at an
  /// indeterminate loop).
  final int budgetRemaining;

  /// True if the walk stopped early because a conveyor chain entered a
  /// closed loop -- the true outcome needs RNG not available client-side.
  final bool indeterminate;
}

/// Finds a random valid exit tile among [loopTile]'s neighbors that are not
/// part of [loop] itself, in bounds, not impassable, not occupied, and
/// (for footprint-constrained entities) footprint-valid. Null if none.
HexCoord? _findLoopExit(
  BattleState state,
  Random rng,
  HexCoord loopTile,
  List<HexCoord> loop,
  bool Function(HexCoord)? footprintValid,
) {
  final candidates = _neighborsOf(loopTile).where((n) {
    if (loop.contains(n)) return false;
    if (!state.battlefield.isInBounds(n)) return false;
    if (state.tileEffects[n] is ImpassableTile) return false;
    if (_isOccupied(state, n)) return false;
    if (footprintValid != null && !footprintValid(n)) return false;
    return true;
  }).toList();
  if (candidates.isEmpty) return null;
  return candidates[rng.nextInt(candidates.length)];
}

TileEntryOutcome _resolveLoop({
  required BattleState state,
  required Random rng,
  required List<HexCoord> loop,
  required List<HexCoord> pathSoFar,
  required int damageSoFar,
  required int currentHp,
  bool Function(HexCoord)? footprintValid,
}) {
  final loopLen = loop.length;
  for (var extra = 0; extra < loopLen; extra++) {
    final exit = _findLoopExit(state, rng, loop[extra], loop, footprintValid);
    if (exit != null) {
      final damage = (loopLen + extra) ~/ 3;
      return TileEntryOutcome(
        finalPosition: exit,
        totalDamage: damageSoFar + damage,
        killed: false,
        animationPath: [...pathSoFar, ...loop, exit],
      );
    }
  }

  // No exit anywhere in the loop.
  final dmgPerPass = loopLen ~/ 3;
  if (dmgPerPass <= 0) {
    // A loop this short (2 tiles) can never deal damage by the per-pass
    // formula -- crash into the weakest blocker instead of stalling forever.
    return _resolveCrashIntoBlocker(
      state: state,
      rng: rng,
      loop: loop,
      pathSoFar: pathSoFar,
      damageSoFar: damageSoFar,
      currentHp: currentHp,
      footprintValid: footprintValid,
    );
  }

  final passesToDie = (currentHp / dmgPerPass).ceil();
  final animatedPasses = passesToDie.clamp(1, _kMaxAnimatedLoopPasses);
  return TileEntryOutcome(
    finalPosition: loop.first, // irrelevant -- entity dies
    totalDamage: damageSoFar + dmgPerPass * passesToDie,
    killed: true,
    animationPath: [
      ...pathSoFar,
      for (var i = 0; i < animatedPasses; i++) ...loop,
    ],
  );
}

/// The living avatar or minion occupying [hex], if any.
({String id, int hp, bool isAvatar})? _entityAt(BattleState state, HexCoord hex) {
  final av = state.avatars.where((a) => a.isAlive && a.position == hex).firstOrNull;
  if (av != null) return (id: av.playerId, hp: av.hp, isAvatar: true);
  final m = state.minions.where((m) => m.isAlive && m.occupiedTiles.contains(hex)).firstOrNull;
  if (m != null) return (id: m.id, hp: m.hp, isAvatar: false);
  return null;
}

void _damageEntityById(BattleState state, String id, bool isAvatar, int amount) {
  if (amount <= 0) return;
  if (isAvatar) {
    state.avatars.firstWhere((a) => a.playerId == id).absorbDamage(amount);
  } else {
    state.minions.firstWhere((m) => m.id == id).takeDamage(amount);
  }
}

/// A fully-blocked loop too short to ever deal damage by the per-pass
/// formula (loopLength ~/ 3 == 0, i.e. a 2-tile loop): the looped entity
/// crashes into whichever entity is occupying a would-be exit tile anywhere
/// around the loop with the lowest current HP (ties broken by [rng]).
///
/// Both combatants deal damage equal to their own pre-collision HP to the
/// other, simultaneously -- this directly mutates the blocker's HP in
/// [state] (the one place this file reaches outside the looped entity,
/// since the caller only ever applies the returned [TileEntryOutcome] back
/// onto the looped entity, not onto a third party). The looped entity's own
/// damage is folded into the returned outcome as usual, for the caller to
/// apply.
TileEntryOutcome _resolveCrashIntoBlocker({
  required BattleState state,
  required Random rng,
  required List<HexCoord> loop,
  required List<HexCoord> pathSoFar,
  required int damageSoFar,
  required int currentHp,
  bool Function(HexCoord)? footprintValid,
}) {
  final candidates = <({HexCoord tile, String id, int hp, bool isAvatar})>[];
  final seen = <HexCoord>{};
  for (final loopTile in loop) {
    for (final n in _neighborsOf(loopTile)) {
      if (loop.contains(n) || !seen.add(n)) continue;
      if (!state.battlefield.isInBounds(n)) continue;
      if (state.tileEffects[n] is ImpassableTile) continue;
      if (footprintValid != null && !footprintValid(n)) continue;
      final occ = _entityAt(state, n);
      if (occ != null) {
        candidates.add((tile: n, id: occ.id, hp: occ.hp, isAvatar: occ.isAvatar));
      }
    }
  }

  if (candidates.isEmpty) {
    // Nothing to crash into (every exit is terrain-blocked or
    // footprint-invalid, not occupied) -- stuck, but not an infinite loop.
    return TileEntryOutcome(
      finalPosition: loop.first,
      totalDamage: damageSoFar,
      killed: false,
      animationPath: [...pathSoFar, ...loop],
    );
  }

  final minHp = candidates.map((c) => c.hp).reduce(min);
  final lowest = candidates.where((c) => c.hp == minHp).toList();
  final blocker = lowest[rng.nextInt(lowest.length)];

  // Simultaneous mutual collision, both using pre-collision HP: the looped
  // entity deals its own current HP to the blocker (applied here, directly);
  // the blocker deals its own current HP back to the looped entity (folded
  // into totalDamage for the caller to apply). currentHp > blocker.hp
  // guarantees the blocker dies (freeing its tile) AND the looped entity
  // survives; currentHp <= blocker.hp guarantees the looped entity dies
  // (an exact tie kills both).
  _damageEntityById(state, blocker.id, blocker.isAvatar, currentHp);
  final loopedSurvives = currentHp > blocker.hp;

  if (!loopedSurvives) {
    return TileEntryOutcome(
      finalPosition: loop.first, // irrelevant -- entity dies
      totalDamage: damageSoFar + blocker.hp,
      killed: true,
      animationPath: [...pathSoFar, ...loop],
    );
  }
  return TileEntryOutcome(
    finalPosition: blocker.tile,
    totalDamage: damageSoFar + blocker.hp,
    killed: false,
    animationPath: [...pathSoFar, ...loop, blocker.tile],
  );
}
