// SPDX-License-Identifier: GPL-3.0-or-later
//
// terrain.dart — Tile effects and cloud objects.
//
// TileEffect variants (placed by Earth-Water / tileModification spells):
//   FloorIsLava    — Fire flavor: 2 damage to any entity passing through
//   ImpassableTile — Earth flavor: blocks movement + spell line-of-sight
//   SlowTile       — Water flavor: costs extra movement + mana drain on entry
//   ConveyorTile   — Air flavor: force-moves occupants one tile per turn
//
// Tile effects are permanent (no turn limit); they persist until removed by
// another effect or match end.
//
// CloudObject variants (placed by Water-Fire / clouds spells; design doc v3.0
// Effect Table, Water-Fire row):
//   Base effect (all flavors): entities standing in the cloud's radius may
//   only target/be targeted by adjacent entities (see TurnLoop/battle_screen
//   targeting checks -- CloudObject itself just carries position + radius).
//   ToxicCloud  — Fire flavor: deals damage per turn on the tile
//   DustCloud   — Earth flavor: the adjacent-only targeting restriction lingers
//                 [restrictionTurnsAfterLeaving] turns after an entity leaves
//                 (applied as a status effect -- see StatusEffectId)
//   WaterCloud  — Water flavor: no extra tick behaviour, just [radius] = 2
//                 instead of 1 (a bigger cloud)
//   MobileCloud — Air flavor: auto-seeks the nearest enemy, moving 1 tile
//                 during the Summons step each turn (TurnLoop._moveClouds)

import 'package:rune_duel/engine/hex_grid.dart';

// ── Tile effects ──────────────────────────────────────────────────────────────

sealed class TileEffect {
  const TileEffect();
}

/// Fire flavor (Earth-Water): any entity that passes through this tile takes
/// [damage] HP damage. Spirits with ignoresTerrain are exempt.
class FloorIsLava extends TileEffect {
  const FloorIsLava({this.damage = 2});

  final int damage;
}

/// Earth flavor (Earth-Water): no entity (player or hound) may enter.
/// Also blocks spell targeting through this tile (line-of-sight check).
/// Spirits may fly over it (ignoresTerrain = true on SpiritMinion).
class ImpassableTile extends TileEffect {
  const ImpassableTile();
}

/// Water flavor (Earth-Water): entering costs [extraMoveCost] additional
/// movement points and drains [manaDrainOnEntry] mana from the mover.
/// TODO(design): mana drain amount not specified — set during playtesting.
class SlowTile extends TileEffect {
  const SlowTile({this.extraMoveCost = 2, this.manaDrainOnEntry = 10});

  final int extraMoveCost;
  final int manaDrainOnEntry;
}

/// Air flavor (Earth-Water): any entity that starts its turn on this tile is
/// force-moved one hex in [direction].
///
/// [direction] is chosen at resolution time (HexCoord(0,0) = not yet set).
/// Permanent — does not expire.
///
/// Sorcerer seam: in real-time mode, display an on-screen directional
/// indicator; physical movement handling deferred pending sorcerer-mode design.
// TODO(sorcerer): conveyor indicator UI for real-time mode.
class ConveyorTile extends TileEffect {
  const ConveyorTile({this.direction = const HexCoord(0, 0)});

  final HexCoord direction;

  bool get directionSet => direction.q != 0 || direction.r != 0;

  ConveyorTile withDirection(HexCoord dir) => ConveyorTile(direction: dir);
}

// ── Cloud object ──────────────────────────────────────────────────────────────

sealed class CloudKind {
  const CloudKind();
}

/// Fire flavor (Water-Fire): deals [damagePerTurn] to any entity on the tile
/// at the end of each turn.
class ToxicCloud extends CloudKind {
  const ToxicCloud({this.damagePerTurn = 1});

  final int damagePerTurn;
}

/// Earth flavor (Water-Fire): when an entity leaves the cloud's radius, the
/// base "adjacent-only targeting" restriction lingers on them for
/// [restrictionTurnsAfterLeaving] more turns, applied as a status effect
/// (StatusEffectId.cloudBoundTargeting).
class DustCloud extends CloudKind {
  const DustCloud({this.restrictionTurnsAfterLeaving = 2});

  final int restrictionTurnsAfterLeaving;
}

/// Water flavor (Water-Fire): no kind-specific tick behaviour -- this flavor's
/// entire effect is CloudObject.radius = 2 instead of the default 1 (a bigger
/// cloud), which the caller sets when constructing the CloudObject.
class WaterCloud extends CloudKind {
  const WaterCloud();
}

/// Air flavor (Water-Fire): auto-seeks the nearest enemy, moving 1 tile
/// toward them during the Summons step each turn (TurnLoop._moveClouds).
class MobileCloud extends CloudKind {
  const MobileCloud();
}

class CloudObject {
  CloudObject({
    required this.id,
    required this.position,
    required this.kind,
    required this.remainingTurns,
    required this.ownerId,
    this.radius = 1,
  });

  final String id;
  HexCoord position;
  final CloudKind kind;
  int remainingTurns;
  final String ownerId;

  /// Tiles from [position] this cloud covers for damage/targeting-restriction
  /// purposes. 1 for all flavors except Water (2).
  final int radius;

  bool tick() {
    if (remainingTurns > 0) remainingTurns--;
    return remainingTurns > 0;
  }
}

