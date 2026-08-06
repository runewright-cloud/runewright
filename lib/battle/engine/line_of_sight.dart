// SPDX-License-Identifier: GPL-3.0-or-later
//
// line_of_sight.dart — the single shared line-of-sight predicate.
//
// One implementation, used by every consumer (spell cast resolution in
// TurnLoop._applySpell, ranged summon attacks in TurnLoop._creatureTurn and
// _nearestEnemyEntity, traversal damage in EffectApplicator, and the
// battle_screen targeting mirror). Both peers run this independently and hash
// the resulting state, so it must stay deterministic: integer rounding only,
// no RNG, no wall-clock, no iteration over an unsorted Map.
//
// What blocks (docs/WALL_LOS_PLAN.md §5.1):
//   - ImpassableTile (the Earth flavor of Terrain Sculpting) — an earthen wall.
//   - Any tile of a living Big creature's footprint.
//
// What deliberately does NOT block:
//   - ChasmTile. It blocks movement but has "no bearing on targeting"
//     (design v3.0 §Wild Magic; WILD_MAGIC_PLAN.md A9). terrain.dart's
//     ChasmTile comment asks every new ImpassableTile consumer to decide about
//     chasms explicitly — this is such a consumer, and the decision is *no*.
//     That is also why this file tests `is ImpassableTile` directly rather
//     than calling tileBlocksMovement().
//   - The attacker's own footprint and the declared target's own footprint: a
//     creature never blocks itself, and you can always shoot the Big creature
//     you are aiming at.
//   - Anything at all when [penetrating] is true (Firey Inertia).
//
// A blocked spell is NOT rejected: it resolves on the blocker's tile instead
// (§2.1). Returning the blocker rather than a bool is what makes that possible.

import 'package:rune_duel/engine/hex_grid.dart';
import 'package:rune_duel/battle/models/battle_state.dart';
import 'package:rune_duel/battle/models/hex_battlefield.dart' show hexDistance;
import 'package:rune_duel/battle/models/terrain.dart';

/// Tiles strictly between [from] and [to] (exclusive of both endpoints), in
/// order from [from] outward.
///
/// Lifted out of EffectApplicator (where it was `_hexLinePath`) when three
/// subsystems came to need it. Linear interpolation in axial coordinates with
/// `.round()` at each step: integer-deterministic, so both peers walk the same
/// hexes. Returns empty for adjacent or identical endpoints.
List<HexCoord> hexLinePath(HexCoord from, HexCoord to) {
  final n = hexDistance(from, to);
  if (n <= 1) return const [];
  final path = <HexCoord>[];
  for (var i = 1; i < n; i++) {
    final t = i / n;
    final q = (from.q * (1 - t) + to.q * t).round();
    final r = (from.r * (1 - t) + to.r * t).round();
    path.add(HexCoord(q, r));
  }
  return path;
}

/// The first tile along the line from [from] to [to] that blocks line of
/// sight, or null when the line is clear.
///
/// Callers retarget a blocked spell onto the returned tile (§2.1) rather than
/// rejecting the cast. Ties cannot occur: [hexLinePath] is an ordered list and
/// this stops at the first hit (§3.10).
///
/// [penetrating] short-circuits to null — that is the whole of the Firey
/// Inertia (StatusEffectId.penetrating) wiring on this side.
HexCoord? losBlockerTile(
  BattleState state,
  HexCoord from,
  HexCoord to, {
  bool penetrating = false,
}) {
  if (penetrating) return null;

  // Footprints that are exempt: whoever is shooting, and whoever is being
  // shot at. Collected once so the per-hex test below stays a set lookup.
  final exempt = <HexCoord>{};
  for (final m in state.minions) {
    if (!m.isAlive) continue;
    final tiles = m.occupiedTiles;
    if (tiles.contains(from) || tiles.contains(to)) exempt.addAll(tiles);
  }

  // A creature blocks sight when it has a multi-tile body — naturally Big
  // (EEEE) or grown by a Rod of Wind. Keying off the footprint rather than the
  // ability keeps a rod-grown creature consistent with a born-Big one, the
  // same rule EffectApplicator._knockbackMinion already uses for immovability.
  final blockingBodies = <HexCoord>{};
  for (final m in state.minions) {
    if (!m.isAlive) continue;
    final tiles = m.occupiedTiles;
    if (tiles.length > 1) blockingBodies.addAll(tiles);
  }

  for (final hex in hexLinePath(from, to)) {
    if (exempt.contains(hex)) continue;
    if (state.tileEffects[hex] is ImpassableTile) return hex;
    if (blockingBodies.contains(hex)) return hex;
  }
  return null;
}

/// The last hex on the line from [from] to [to] before [blocker] — i.e. how far
/// the spell got before something stopped it.
///
/// Callers that place a *body* use this instead of the blocker itself: an
/// incantation effect resolves ON the wall (§2.1), but a summoned creature
/// needs a tile it can stand on, and a wall is precisely the tile nothing can
/// stand in. Returns [from] when the blocker is adjacent to the caster (there
/// was no clear hex in between) — the caster's own tile, from which
/// TurnLoop._castSummon's spawn search walks outward.
///
/// [blocker] must be a hex [losBlockerTile] returned for the same endpoints;
/// anything else falls back to [from].
HexCoord tileBeforeBlocker(HexCoord from, HexCoord to, HexCoord blocker) {
  final path = hexLinePath(from, to);
  final idx = path.indexOf(blocker);
  if (idx <= 0) return from;
  return path[idx - 1];
}
