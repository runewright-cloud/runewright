// SPDX-License-Identifier: GPL-3.0-or-later
//
// hex_battlefield.dart — Battlefield and movement for the battle layer.
//
// Reuses HexCoord (axial q,r) from lib/engine/hex_grid.dart; the battlefield
// is separate from the CA rune grid (HexGrid) — same coordinate system,
// different purpose.
//
// Movement validation is REAL: up to 2 tiles/turn, collision resolved by
// speed (higher speed claims contested tile; ties bounce both back one tile
// along their own path). Pathing UI and movement-intent serialisation are
// stubbed.
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
    show TileEffect, ImpassableTile, SlowTile, tileBlocksMovement;

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

/// One contested destination arbitrated during [Battlefield.resolveMovement]:
/// [tile] is a tile two or more players tried to end their move on
/// simultaneously, [contestants] is everyone who tried (in a deterministic
/// order -- see the note below), and [winnerId] is the single claimant that
/// kept it, or null when the fastest speed tied and *everyone* gave ground.
///
/// **Purely descriptive.** Gameplay is fully determined by
/// [MovementResult.paths] and [MovementResult.bounced]; this list exists so the
/// UI can animate the lunge-and-recoil (both wizards reaching for the tile, the
/// loser knocked back) instead of silently teleporting the losers to their
/// consolation tile. Nothing in the engine reads it back.
///
/// [contestants] order is iteration order over the claim map, which is
/// insertion-ordered from `occupancy` — identical on both devices for the same
/// state, so this is safe to render from in lockstep even though it is not
/// itself consensus-critical.
class MovementContest {
  const MovementContest({
    required this.tile,
    required this.contestants,
    required this.winnerId,
  });

  final HexCoord tile;
  final List<String> contestants;
  final String? winnerId;

  /// Everyone who reached for [tile] and was pushed back off it.
  List<String> get losers =>
      contestants.where((id) => id != winnerId).toList();
}

/// Return value from [Battlefield.resolveMovement]: a deterministic,
/// no-RNG *preview* used only to decide who wins a contested destination
/// tile. It deliberately ignores terrain (SlowTile cost aside, for budget
/// purposes) and ConveyorTile entirely -- the real, terrain-aware walk
/// (budget consumption, SlowTile mana drain, FloorIsLava damage, and
/// ConveyorTile pushes/cascades/loops) runs afterward in
/// DeterministicResolution.walkAvatar, which needs a seeded RNG (loop-exit
/// randomness,
/// see tile_entry_resolver.dart) and BattleState (occupancy/avatars/minions)
/// this self-contained Battlefield class deliberately doesn't reference.
class MovementResult {
  const MovementResult({
    required this.bounced,
    required this.paths,
    this.contests = const [],
  });

  /// playerIds who lost a contested-destination collision this turn (tied or
  /// out-sped) and so stop short of the tile they declared.
  final Set<String> bounced;

  /// playerId → the declared-path prefix (tiles to enter, origin excluded)
  /// the player is cleared to walk after budget/blocker clamping *and*
  /// contested-tile arbitration. An empty list means "stay put".
  ///
  /// A collision loser is walked back one tile along their own path rather
  /// than all the way to their origin (design doc §Movement Collision:
  /// "the other remains on their previous position along their path"), and
  /// arbitration re-runs, so a chain of collisions can push a player back
  /// more than one tile.
  final Map<String, List<HexCoord>> paths;

  /// Every contested destination arbitrated this turn, in the order the
  /// fixed-point loop settled them — so a player pushed back twice appears in
  /// two entries, furthest-reached tile first. UI-only; see [MovementContest].
  final List<MovementContest> contests;
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

  /// Deterministic (no-RNG) collision preview: walks each player's declared
  /// [paths] ignoring ConveyorTile (see [MovementResult]) purely to find each
  /// player's naive intended destination, then arbitrates any tile two or
  /// more players would land on simultaneously. This does NOT mutate
  /// [occupancy] or apply any terrain side-effect (budget cost aside, for
  /// arbitration purposes) -- the caller
  /// (DeterministicResolution.resolveAvatarMovement)
  /// does the real walk afterward, along the arbitrated
  /// [MovementResult.paths] rather than the raw declared ones.
  ///
  /// Rules (design doc §movement):
  ///   - Each player supplies an ordered list of tiles to enter ([paths]).
  ///     Each step must be adjacent to the previous; the first step is adjacent
  ///     to the player's origin. An empty list means "stay put".
  ///   - [ImpassableTile]: a step into an impassable tile truncates the path at
  ///     the previous tile.
  ///   - [SlowTile]: each tile entered costs 1 + [extraMoveCost] budget here
  ///     (for arbitration only -- the real mana drain happens in the caller's
  ///     real walk).
  ///   - Contested destination: highest speed claims the tile; every loser
  ///     (out-sped, or every contestant when the top speed is tied) stops one
  ///     tile short along their own path. Arbitration then repeats, so a
  ///     player pushed back onto another contested tile keeps giving ground.
  ///     A player already back at their origin holds it -- movement can never
  ///     shove someone off the tile they started the turn on.
  ///
  /// [paths] maps playerId → ordered list of tiles to enter (not including origin).
  /// [speeds] maps playerId → effective move speed (base 2 + status effects).
  ///
  /// [flyingPlayerIds] are wizards under wild magic's Updraft: they ignore
  /// terrain entirely while moving (WILD_MAGIC_PLAN.md A11), matching
  /// DeterministicResolution.walkAvatar. They still contest destination tiles
  /// normally, and
  /// they alone may path through [blockedTiles] (design v3.0 §Flying: move
  /// through other entities, but never come to rest on one — the real walk in
  /// DeterministicResolution.walkAvatar is what enforces the second half).
  ///
  /// [blockedTiles] are tiles held by a body at the START of the movement
  /// phase — every living avatar's tile and every living minion's footprint.
  /// Bodies are exclusive, so a walker stops dead in front of one instead of
  /// stepping through it. A player's own origin is never a blocker to
  /// themselves. This is a *snapshot*, deliberately: movement is simultaneous,
  /// so resolving it against positions that shift as each player is walked in
  /// turn would hand the first player in iteration order a free pass through a
  /// tile the second hasn't vacated yet.
  ///
  /// **Ice sliding is deliberately NOT modelled here.** The returned
  /// [MovementResult.paths] are re-walked verbatim as DECLARED STEPS by
  /// DeterministicResolution.walkAvatar, so injecting the slid-through tiles
  /// would make that
  /// walk re-enter each of them — sliding the avatar back and forth. So this
  /// preview arbitrates on the pre-slide destination and the real walk slides
  /// afterwards. That costs a little arbitration accuracy on iced ground (two
  /// players may be judged not to contest a tile they both slide off anyway)
  /// and costs nothing in lockstep, because both clients run identical code on
  /// both halves, and the real walk's occupancy check stops a second slider
  /// short rather than stacking them.
  MovementResult resolveMovement(
    Map<String, List<HexCoord>> paths,
    Map<String, int> speeds, {
    int maxTilesPerTurn = 2,
    Map<HexCoord, TileEffect> tileEffects = const {},
    Set<String> flyingPlayerIds = const {},
    Set<HexCoord> blockedTiles = const {},
  }) {
    final origins = Map<String, HexCoord>.from(occupancy);

    // ── Step 1: Walk each path step-by-step ───────────────────────────────────
    // walkedPaths[id] = [origin, step1, step2, ...] after budget/blocker clamp.
    final walkedPaths = <String, List<HexCoord>>{};
    // Recorded first, before any arbitration, so that a player both stopped by
    // a body AND pushed back off a contested tile lunges at the body -- the
    // furthest they visibly reached. UI-only, exactly like the rest of
    // [contests]; see [MovementContest].
    final contests = <MovementContest>[];

    for (final id in origins.keys) {
      final origin = origins[id]!;
      final path   = paths[id] ?? const [];
      final budget = max(0, maxTilesPerTurn + ((speeds[id] ?? maxTilesPerTurn) - maxTilesPerTurn));
      var remaining = budget;
      var current   = origin;
      final walked  = <HexCoord>[origin];

      final flying = flyingPlayerIds.contains(id);

      for (final step in path) {
        if (remaining <= 0) break;
        if (!isInBounds(step)) break;
        if (hexDistance(current, step) != 1) break; // path must be step-adjacent
        final effect = flying ? null : tileEffects[step];
        // ChasmTile blocks movement like a wall (but not targeting — see
        // terrain.dart). Missing it here would let the preview arbitrate a
        // destination the real walk can never reach.
        if (tileBlocksMovement(effect)) break;
        // A body blocks the way. Their own origin doesn't count -- a path that
        // doubles back through where it started isn't walking through anyone.
        if (!flying && step != origin && blockedTiles.contains(step)) {
          // Recorded as a one-sided contest so the UI shows the shoulder-check
          // rather than an unexplained early stop. Gameplay-wise this is just
          // "the walk ended here"; nothing reads it back.
          contests.add(
            MovementContest(tile: step, contestants: [id], winnerId: null),
          );
          break;
        }
        final cost = 1 + (effect is SlowTile ? effect.extraMoveCost : 0);
        if (cost > remaining) break;
        current    = step;
        remaining -= cost;
        walked.add(step);
      }

      walkedPaths[id] = walked;
    }

    // ── Step 2: Collision resolution ─────────────────────────────────────────
    // claim[id] indexes walkedPaths[id]: the tile that player currently
    // intends to end on. It starts at their naive destination and is walked
    // back one tile per lost contest. Index 0 is their origin and the floor --
    // a player can't be pushed off the tile they started the turn on, so an
    // origin-pinned contestant automatically holds the tile.
    final claim = {
      for (final entry in walkedPaths.entries) entry.key: entry.value.length - 1,
    };
    final bounced = <String>{};

    // Stepping back can land a loser on a tile someone else is claiming, so
    // arbitration runs to a fixed point. Every pass that changes anything
    // strictly decreases the sum of claim indices (each loser has claim > 0),
    // so this terminates; the step budget is a belt-and-braces bound.
    var guard = claim.values.fold<int>(0, (a, b) => a + b) + 1;
    var settled = false;
    while (!settled && guard-- > 0) {
      settled = true;

      final destToPlayers = <HexCoord, List<String>>{};
      for (final entry in claim.entries) {
        destToPlayers
            .putIfAbsent(walkedPaths[entry.key]![entry.value], () => [])
            .add(entry.key);
      }

      for (final entry in destToPlayers.entries) {
        final contestants = entry.value;
        if (contestants.length == 1) continue;

        // Materialised, not lazy: the loop below mutates [claim], which this
        // predicate reads.
        final List<String> losers;
        // Whoever ends up keeping the tile, for the UI's collision animation
        // (null = nobody did). Origins are unique, so the origin-holder branch
        // has exactly one such player.
        String? winnerId;
        if (contestants.any((id) => claim[id] == 0)) {
          // Someone is standing on their own origin here: they keep it and
          // everyone with room to give ground gives it.
          losers = contestants.where((id) => claim[id]! > 0).toList();
          winnerId = contestants.firstWhere((id) => claim[id] == 0);
        } else {
          final maxSpeed = contestants
              .map((id) => speeds[id] ?? maxTilesPerTurn)
              .reduce(max);
          final winners = contestants
              .where((id) => (speeds[id] ?? maxTilesPerTurn) == maxSpeed)
              .toList();
          // A unique fastest contestant claims the tile; a tie for fastest
          // means nobody does and all of them fall back.
          losers = winners.length == 1
              ? contestants.where((id) => id != winners.first).toList()
              : contestants;
          winnerId = winners.length == 1 ? winners.first : null;
        }

        contests.add(
          MovementContest(
            tile: entry.key,
            contestants: List.unmodifiable(contestants),
            winnerId: winnerId,
          ),
        );

        for (final id in losers) {
          claim[id] = claim[id]! - 1;
          bounced.add(id);
          settled = false;
        }
      }
    }

    return MovementResult(
      bounced: bounced,
      contests: List.unmodifiable(contests),
      paths: {
        // walkedPaths[id][1..] is the declared path in order (the walk breaks
        // out rather than skipping steps), so the prefix up to the claimed
        // index is exactly the declared path the player is cleared to take.
        for (final entry in claim.entries)
          entry.key: walkedPaths[entry.key]!.sublist(1, entry.value + 1),
      },
    );
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
    if (tileBlocksMovement(tileEffects[to])) return null;

    // BFS tracking previous-tile for path reconstruction.
    final prev  = <HexCoord, HexCoord?>{from: null};
    final queue = <HexCoord>[from];

    HexCoord? found;
    outer:
    while (queue.isNotEmpty) {
      final current = queue.removeAt(0);
      for (final next in neighbors(current)) {
        if (tileBlocksMovement(tileEffects[next])) continue;
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
