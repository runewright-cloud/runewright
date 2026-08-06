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
// Tile effects placed by spells have no turn limit, but they are NOT
// indestructible: each of the four carries an HP pool and an elemental
// affinity (see [terrainMaxHpOf] / [terrainAffinityOf] below) and is destroyed
// when damage exhausts it. Without that, a lava- or slow-tile spam build has
// no counterplay at all (docs/WALL_LOS_PLAN.md §1/§4). The live HP and any
// barriers imbued into a tile live in BattleState.terrainHp /
// BattleState.terrainBarriers — side-maps, following the expiringTiles
// precedent, so every TileEffect stays immutable.
//
// The two WILD-MAGIC variants below (IceTile, ChasmTile) are the exception:
// they get no HP pool at all, and they expire on their own, with the expiry
// turn in BattleState.expiringTiles.
//
//   IceTile   — Glacier (wild magic, row 2 Water): entering slides you on
//   ChasmTile — Chasm   (wild magic, row 2 Earth): blocks movement, NOT
//                        targeting; indestructible while it lives
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
import 'package:rune_duel/battle/models/effect_kind.dart' show SpellAffinity;

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

/// Air flavor (Earth-Water): any entity that enters this tile -- by any
/// cause (voluntary movement's final tile, a knockback/push landing them
/// here, or another conveyor tile pushing them into this one) -- is
/// force-moved one hex in [direction], immediately, before anything else
/// resolves. Pushes cascade through further conveyor tiles; a cycle of
/// conveyor tiles forms a closed loop with its own traversal/exit/damage
/// mechanic. See lib/battle/engine/tile_entry_resolver.dart for the full
/// resolution (cascading pushes, loop detection, exit search, damage).
///
/// [direction] is chosen by the casting wizard when this tile is created
/// (HexCoord(0,0) = not yet set -- resolved to a real direction, chosen or
/// randomly, before the tile is ever placed into BattleState.tileEffects;
/// see EffectApplicator._applyTileModification). Permanent — does not
/// expire.
///
/// Sorcerer seam: in real-time mode, display an on-screen directional
/// indicator; physical movement handling deferred pending sorcerer-mode design.
// TODO(sorcerer): conveyor indicator UI for real-time mode; direction-choice
//   prompt should race against a timeout and fall back to random (the same
//   fallback EffectApplicator already uses when no direction is supplied).
class ConveyorTile extends TileEffect {
  const ConveyorTile({this.direction = const HexCoord(0, 0)});

  final HexCoord direction;

  bool get directionSet => direction.q != 0 || direction.r != 0;

  ConveyorTile withDirection(HexCoord dir) => ConveyorTile(direction: dir);
}

/// Wild magic, Glacier (row 2, Water): "tiles without existing terrain all
/// become Ice tiles for 2 [+1] turns; when moving onto ice a player continues
/// moving that direction."
///
/// The slide continues in the entry direction, FREE of movement budget, until
/// the next tile is out of bounds, occupied, or not ice (WILD_MAGIC_PLAN.md
/// A12 — mirroring ConveyorTile's free cascading push, the closest existing
/// precedent). Flying entities do not slide.
///
/// Expiry lives in BattleState.expiringTiles, not here.
class IceTile extends TileEffect {
  const IceTile();
}

/// Wild magic, Chasm (row 2, Earth): "a randomly drawn line bisects the
/// battlefield. It is impassible (without flying), and indestructible for
/// 2[+1] turns, but has no bearing on targeting."
///
/// Deliberately NOT an [ImpassableTile] (WILD_MAGIC_PLAN.md A9): that class
/// blocks line-of-sight and is destructible, and a chasm is neither. Every
/// consumer of ImpassableTile had to be audited and decided individually —
/// movement yes, targeting no, terrain destruction no. If you add a new
/// ImpassableTile consumer, make the same decision for this class explicitly.
///
/// Expiry lives in BattleState.expiringTiles, not here.
class ChasmTile extends TileEffect {
  const ChasmTile();
}

// ── Shared terrain predicates ─────────────────────────────────────────────────

/// True when a non-flying entity may not enter a tile carrying [e].
///
/// Use this at EVERY movement, push, and placement site rather than testing
/// `is ImpassableTile` directly — that is what makes "which tiles block?" a
/// single decision. Targeting and line-of-sight sites deliberately do NOT use
/// it: a [ChasmTile] blocks movement but has *no bearing on targeting*
/// (design v3.0 §Wild Magic), so a spell may be aimed across a chasm even
/// though nobody can walk over it.
bool tileBlocksMovement(TileEffect? e) => e is ImpassableTile || e is ChasmTile;

/// True when [e] must not be removed or overwritten by another effect.
///
/// A chasm is indestructible for as long as it lives (it expires on its own
/// via BattleState.expiringTiles). Terrain-destruction effects and tile
/// placements both check this.
bool tileIsIndestructible(TileEffect? e) => e is ChasmTile;

// ── Terrain HP model (docs/WALL_LOS_PLAN.md §2.2, §3.3, §5.0) ────────────────

/// True when [e] is one of the four spell-placed tiles that carry an HP pool
/// and can be damaged, barriered, and destroyed.
///
/// The wild-magic pair is deliberately excluded: [ChasmTile] is indestructible
/// for its lifetime and [IceTile] expires on its own, so neither ever gets an
/// entry in BattleState.terrainHp / .terrainBarriers.
bool tileIsDestructibleTerrain(TileEffect? e) =>
    e is FloorIsLava || e is ImpassableTile || e is SlowTile || e is ConveyorTile;

/// A terrain tile's elemental affinity — the Terrain Sculpting flavor that
/// places it. Null for the wild-magic tiles, which have no affinity because
/// they have no HP to resist damage with.
///
/// Damage against terrain runs the same resistance wheel creatures use
/// ([applyResistance]): same element halves (rounded up), opposite doubles.
/// Dousing lava with water and eroding a wall with wind both read correctly,
/// and Earth being the *worst* element for breaking an earthen wall is
/// intended (§2.2).
///
/// Fixed at placement and never changed: paving lava with a wall replaces the
/// tile outright — new type, new affinity, new full HP, old barriers lost
/// (§3.4). That is what keeps this a pure function with nothing to serialize.
SpellAffinity? terrainAffinityOf(TileEffect? e) => switch (e) {
      FloorIsLava() => SpellAffinity.fire,
      ImpassableTile() => SpellAffinity.earth,
      SlowTile() => SpellAffinity.water,
      ConveyorTile() => SpellAffinity.air,
      _ => null,
    };

/// A terrain tile's full HP pool. 0 for anything without one.
///
/// Mirrors the barrier table players already know (Earthen 4, everything else
/// 2): Earth is the tanky flavor (§3.3). It also answers terrain spam
/// directly — the cheapest tiles to spam are exactly the flimsy ones.
///
/// Note this is the *type's* pool. An illusory copy overrides it at 1 HP by
/// design (Earthen Illusions); BattleState.terrainHpAt checks the illusion map
/// first, and callers should use that rather than this (§3.7).
int terrainMaxHpOf(TileEffect? e) => switch (e) {
      ImpassableTile() => 4,
      FloorIsLava() || SlowTile() || ConveyorTile() => 2,
      _ => 0,
    };

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
  const DustCloud({this.restrictionTurnsAfterLeaving = 3});

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

