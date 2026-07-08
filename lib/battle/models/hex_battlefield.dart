// SPDX-License-Identifier: GPL-3.0-or-later
//
// hex_battlefield.dart — Battlefield and movement for the battle layer.
//
// Reuses HexCoord (axial q,r) from lib/engine/hex_grid.dart; the battlefield
// is separate from the CA rune grid (HexGrid) — same coordinate system,
// different purpose.
//
// Movement validation is REAL: up to 2 tiles/turn, collision resolved by
// speed (higher speed claims contested tile; ties bounce both back).
// Pathing UI and movement-intent serialisation are stubbed.
//
// Chapter selection belongs here per the subsystem grouping (the player
// selects a Chapter — a subset of their spell library — before entering
// battle). Library source is a stub; the model is real.
//
// See docs/BATTLE_PROTOCOL.md §7 (spell resolution ordering uses Hex distance
// as a tiebreak element in rare edge cases — not implemented here yet).

import 'dart:math';

import 'package:rune_duel/engine/hex_grid.dart';
import 'package:rune_duel/battle/models/terrain.dart'
    show TileEffect, ImpassableTile, SlowTile, ConveyorTile;

// ── Hex distance / neighbor helpers ──────────────────────────────────────────

/// Axial (cube) distance between two hex coordinates.
int hexDistance(HexCoord a, HexCoord b) {
  final dq = a.q - b.q;
  final dr = a.r - b.r;
  return (dq.abs() + dr.abs() + (dq + dr).abs()) ~/ 2;
}

/// The six axial neighbor directions (same order as HexGrid.directions).
const List<HexCoord> _kHexDirs = [
  HexCoord(1, 0),
  HexCoord(1, -1),
  HexCoord(0, -1),
  HexCoord(-1, 0),
  HexCoord(-1, 1),
  HexCoord(0, 1),
];

List<HexCoord> hexNeighbors(HexCoord h) =>
    _kHexDirs.map((d) => HexCoord(h.q + d.q, h.r + d.r)).toList();

// ── Movement result ───────────────────────────────────────────────────────────

/// Side-effect produced when a player enters a tile with a terrain effect.
sealed class TileEntryEvent {
  const TileEntryEvent(this.playerId);
  final String playerId;
}

/// Player entered a SlowTile: drain [manaDrain] mana on entry.
class SlowTileEntryEvent extends TileEntryEvent {
  const SlowTileEntryEvent(super.playerId, {required this.manaDrain});
  final int manaDrain;
}

/// Player was pushed by a ConveyorTile from [from] to [to].
class ConveyorPushEvent extends TileEntryEvent {
  const ConveyorPushEvent(super.playerId, {required this.from, required this.to});
  final HexCoord from;
  final HexCoord to;
}

/// Return value from [Battlefield.resolveMovement].
class MovementResult {
  const MovementResult({
    required this.positions,
    required this.events,
    required this.traversedPaths,
  });

  /// playerId → resolved position (after terrain side-effects).
  final Map<String, HexCoord> positions;

  /// Terrain entry events: mana drains, conveyor pushes, etc. Apply in order.
  final List<TileEntryEvent> events;

  /// playerId → full path taken this turn, starting with the origin and ending
  /// at the final resolved position (including any conveyor push destination).
  /// A player who did not move has a single-entry list [origin].
  /// Used by TurnLoop for per-tile terrain damage and by EffectApplicator for
  /// path-based knockback bounce.
  final Map<String, List<HexCoord>> traversedPaths;
}

// ── Battlefield ───────────────────────────────────────────────────────────────

/// The in-battle hex grid: tracks occupancy, validates movement, resolves
/// collisions. Distinct from HexGrid (the CA rune grid).
class Battlefield {
  Battlefield({this.radius = 4}) : occupancy = {};

  final int radius;

  /// playerId → current HexCoord. Absent = not on field (dead / not placed).
  final Map<String, HexCoord> occupancy;

  int get tileCount => 1 + 3 * radius * (radius + 1);

  bool isInBounds(HexCoord h) => hexDistance(const HexCoord(0, 0), h) <= radius;

  List<HexCoord> neighbors(HexCoord h) =>
      hexNeighbors(h).where(isInBounds).toList();

  // ── Movement validation ───────────────────────────────────────────────────

  /// Resolves simultaneous movement and returns updated positions, terrain
  /// entry events, and each player's fully traversed path.
  ///
  /// Rules (design doc §movement):
  ///   - Each player supplies an ordered list of tiles to enter ([paths]).
  ///     Each step must be adjacent to the previous; the first step is adjacent
  ///     to the player's origin. An empty list means "stay put".
  ///   - [ImpassableTile]: a step into an impassable tile truncates the path at
  ///     the previous tile.
  ///   - [SlowTile]: each SlowTile entered costs 1 + [extraMoveCost] budget and
  ///     drains mana (one [SlowTileEntryEvent] per tile entered).
  ///   - [ConveyorTile]: after the path is walked the player is pushed one step
  ///     in the conveyor direction from the landing tile.
  ///   - [FloorIsLava]: passable; per-tile damage is applied by the TurnLoop
  ///     using [MovementResult.traversedPaths].
  ///   - Contested destination: highest speed wins; ties bounce both to origin.
  ///
  /// [paths] maps playerId → ordered list of tiles to enter (not including origin).
  /// [speeds] maps playerId → effective move speed (base 2 + status effects).
  MovementResult resolveMovement(
    Map<String, List<HexCoord>> paths,
    Map<String, int> speeds, {
    int maxTilesPerTurn = 2,
    Map<HexCoord, TileEffect> tileEffects = const {},
  }) {
    final origins = Map<String, HexCoord>.from(occupancy);

    // ── Step 1: Walk each path step-by-step ───────────────────────────────────
    // walkedPaths[id] = [origin, step1, step2, ...] after budget/blocker clamp.
    final walkedPaths = <String, List<HexCoord>>{};

    for (final id in origins.keys) {
      final origin = origins[id]!;
      final path   = paths[id] ?? const [];
      final budget = max(0, maxTilesPerTurn + ((speeds[id] ?? maxTilesPerTurn) - maxTilesPerTurn));
      var remaining = budget;
      var current   = origin;
      final walked  = <HexCoord>[origin];

      for (final step in path) {
        if (remaining <= 0) break;
        if (!isInBounds(step)) break;
        if (hexDistance(current, step) != 1) break; // path must be step-adjacent
        final effect = tileEffects[step];
        if (effect is ImpassableTile) break;
        final cost = 1 + (effect is SlowTile ? effect.extraMoveCost : 0);
        if (cost > remaining) break;
        current    = step;
        remaining -= cost;
        walked.add(step);
      }

      walkedPaths[id] = walked;
    }

    // ── Step 2: Collision resolution ─────────────────────────────────────────
    final destToPlayers = <HexCoord, List<String>>{};
    for (final entry in walkedPaths.entries) {
      destToPlayers.putIfAbsent(entry.value.last, () => []).add(entry.key);
    }

    final resolved = Map<String, HexCoord>.from(origins);
    final bounced  = <String>{};

    for (final entry in destToPlayers.entries) {
      final dest        = entry.key;
      final contestants = entry.value;
      if (contestants.length == 1) {
        resolved[contestants.first] = dest;
        continue;
      }
      final maxSpeed = contestants
          .map((id) => speeds[id] ?? maxTilesPerTurn)
          .reduce(max);
      final winners = contestants
          .where((id) => (speeds[id] ?? maxTilesPerTurn) == maxSpeed)
          .toList();
      if (winners.length == 1) {
        resolved[winners.first] = dest;
        for (final loser in contestants.where((id) => id != winners.first)) {
          resolved[loser] = origins[loser]!;
          bounced.add(loser);
        }
      } else {
        for (final id in contestants) {
          resolved[id] = origins[id]!;
          bounced.add(id);
        }
      }
    }

    // ── Step 3: Terrain entry events + conveyor pushes ────────────────────────
    final events       = <TileEntryEvent>[];
    final finalPaths   = Map<String, List<HexCoord>>.from(walkedPaths);

    for (final id in origins.keys) {
      if (bounced.contains(id)) {
        // Bounced: reset path to origin-only, no terrain events.
        finalPaths[id] = [origins[id]!];
        resolved[id]   = origins[id]!;
        continue;
      }

      final walked = walkedPaths[id]!;
      if (walked.length <= 1) continue; // stayed put

      // SlowTile mana drains: one event per SlowTile entered along path.
      for (final hex in walked.skip(1)) {
        final effect = tileEffects[hex];
        if (effect is SlowTile) {
          events.add(SlowTileEntryEvent(id, manaDrain: effect.manaDrainOnEntry));
        }
      }

      // Conveyor push from landing tile.
      final landing = walked.last;
      final landEffect = tileEffects[landing];
      if (landEffect is ConveyorTile) {
        final pushed = HexCoord(
            landing.q + landEffect.direction.q,
            landing.r + landEffect.direction.r);
        final pushedEffect = tileEffects[pushed];
        if (isInBounds(pushed) && pushedEffect is! ImpassableTile) {
          resolved[id]   = pushed;
          finalPaths[id] = [...walked, pushed];
          events.add(ConveyorPushEvent(id, from: landing, to: pushed));
        }
      }
    }

    return MovementResult(
      positions:      resolved,
      events:         events,
      traversedPaths: finalPaths,
    );
  }

  /// Apply a [MovementResult.positions] map back to [occupancy].
  void applyMovement(Map<String, HexCoord> resolved) {
    occupancy.addAll(resolved);
  }

  // ── Pathfinding ───────────────────────────────────────────────────────────

  /// BFS shortest path from [from] to [to] within [maxBudget] move budget.
  ///
  /// Returns the ordered list of tiles entered (not including [from]), or null
  /// if [to] is unreachable within the budget. Returns an empty list when
  /// [from] == [to] (no movement). SlowTile costs are included in the budget
  /// check on the reconstructed path; a slower path may succeed where a
  /// faster-looking one fails.
  List<HexCoord>? shortestPath(
    HexCoord from,
    HexCoord to,
    int maxBudget, {
    Map<HexCoord, TileEffect> tileEffects = const {},
  }) {
    if (from == to) return const [];
    if (!isInBounds(to)) return null;
    if (tileEffects[to] is ImpassableTile) return null;

    // BFS tracking previous-tile for path reconstruction.
    final prev  = <HexCoord, HexCoord?>{from: null};
    final queue = <HexCoord>[from];

    HexCoord? found;
    outer:
    while (queue.isNotEmpty) {
      final current = queue.removeAt(0);
      for (final next in neighbors(current)) {
        if (tileEffects[next] is ImpassableTile) continue;
        if (prev.containsKey(next)) continue;
        prev[next] = current;
        if (next == to) {
          found = next;
          break outer;
        }
        queue.add(next);
      }
    }

    if (found == null) return null;

    // Reconstruct path (tiles entered, not including origin).
    final path = <HexCoord>[];
    HexCoord? cur = found;
    while (cur != null && cur != from) {
      path.insert(0, cur);
      cur = prev[cur];
    }

    // Verify the path fits within the move budget (SlowTile adds cost).
    var budget = 0;
    for (final hex in path) {
      final effect = tileEffects[hex];
      budget += 1 + (effect is SlowTile ? effect.extraMoveCost : 0);
    }

    return budget <= maxBudget ? path : null;
  }

  // ── Spawn positions ───────────────────────────────────────────────────────

  /// Returns initial spawn [HexCoord]s ordered by player index.
  ///
  /// Index 0 is always the local player's position (bottom vertex). Each
  /// player sees themselves at the bottom on their own screen.
  ///
  /// Rules by player count:
  ///   1  — bottom vertex only (solo practice).
  ///   2  — opposite vertices: bottom ↔ top.
  ///   3  — every other vertex (equilateral triangle), local at bottom.
  ///   4  — two opposite pairs, local at bottom.
  ///   5  — five of six vertices; one non-local vertex left empty at random.
  ///   6+ — all six vertices, local at bottom.
  List<HexCoord> spawnPositions(int playerCount, {Random? rng}) {
    // Vertices in visual clockwise order. Index 3 (bottom) is the local-player
    // slot and is always present regardless of player count.
    final v = [
      HexCoord(0, -radius),       // 0: top
      HexCoord(radius, -radius),  // 1: upper-right
      HexCoord(radius, 0),        // 2: lower-right
      HexCoord(0, radius),        // 3: bottom  ← local player
      HexCoord(-radius, radius),  // 4: lower-left
      HexCoord(-radius, 0),       // 5: upper-left
    ];

    if (playerCount == 5) {
      // Leave one of the five non-local vertices empty at random.
      final others = [0, 1, 2, 4, 5]..shuffle(rng ?? Random());
      final skip = others.last;
      return [v[3], for (int i = 0; i < 6; i++) if (i != 3 && i != skip) v[i]];
    }

    return switch (playerCount) {
      1    => [v[3]],
      2    => [v[3], v[0]],
      3    => [v[3], v[1], v[5]],
      4    => [v[3], v[0], v[2], v[5]],
      _    => [v[3], v[0], v[1], v[2], v[4], v[5]],  // 6+: all vertices
    };
  }
}
