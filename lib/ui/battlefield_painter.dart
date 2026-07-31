// SPDX-License-Identifier: GPL-3.0-or-later
//
// battlefield_painter.dart — CustomPainter for the in-battle hex grid.
//
// Draws a plain radius-N battlefield (no CA elements, no border zones).
// Wizards are shown as character sprites standing on their tile, ringed in
// their identity colour (gold for the local player, rubric red for the first
// opponent); if the sprite atlas hasn't decoded, they fall back to the original
// circular tokens — gold star for the local player, initials for opponents.
//
// Coordinate system and hex orientation are identical to HexGridPainter
// (flat-top axial, same q/r → pixel formula) so cells align if overlaid.

import 'dart:math';
import 'dart:ui' as ui show Image;

import 'package:flutter/material.dart';

import '../battle/models/effect_kind.dart' show SpellAffinity;
import '../battle/models/hex_battlefield.dart' show hexDistance;
import '../battle/models/minion.dart';
import '../battle/models/terrain.dart';
import '../engine/hex_grid.dart';
import 'avatars/avatar_sprites.dart';

// ── Pixel ↔ hex coordinate conversion (flat-top axial) ───────────────────────

/// Convert a tap position to the nearest hex coordinate.
/// [center] is the pixel center of the (0,0) hex.
HexCoord pixelToHex(Offset pixel, Offset center, double hexSize) {
  final dx = pixel.dx - center.dx;
  final dy = pixel.dy - center.dy;
  final qF = dx * (2 / 3) / hexSize;
  final rF = (-dx / 3 + dy * (sqrt(3) / 3)) / hexSize;
  return _hexRound(qF, rF);
}

/// Convert a hex coordinate to its pixel center — the inverse of [pixelToHex].
/// [center] is the pixel center of the (0,0) hex. Public so the UI layer can
/// anchor overlays (e.g. the resolution-phase card growth) to a battlefield
/// tile; must stay in lockstep with the painter's private `_hexToPixel`.
Offset hexToPixel(HexCoord coord, Offset center, double hexSize) => Offset(
  center.dx + hexSize * (3 / 2 * coord.q),
  center.dy + hexSize * (sqrt(3) / 2 * coord.q + sqrt(3) * coord.r),
);

HexCoord _hexRound(double q, double r) {
  final s = -q - r;
  var rq = q.round();
  var rr = r.round();
  var rs = s.round();
  final dq = (rq - q).abs();
  final dr = (rr - r).abs();
  final ds = (rs - s).abs();
  if (dq > dr && dq > ds) {
    rq = -rr - rs;
  } else if (dr > ds) {
    rr = -rq - rs;
  }
  return HexCoord(rq, rr);
}

// ── Cast animation ────────────────────────────────────────────────────────────

/// One resolved spell cast to animate: a glowing orb that appears at
/// [fromHex] (the caster), flies to [toHex], and bursts — coloured by the
/// casting wizard's identity (see [BattlefieldPainter.colorForWizard]), so
/// it's always clear *who* cast the spell rather than what element it was.
/// Purely cosmetic; built by the UI layer from [SpellCastEvent] (see
/// turn_loop.dart), which is the gameplay source of truth.
class CastAnimation {
  const CastAnimation({
    required this.fromHex,
    required this.toHex,
    required this.color,
  });

  final HexCoord fromHex;
  final HexCoord toHex;
  final Color color;
}

// Cast animation timeline, as a fraction of the overall playback: the orb
// flies to the target, then bursts. (The "appear and hold" leg is not part
// of this one-shot timeline -- it's rendered continuously beforehand via
// [PendingCastOrb], since it may span an entire movement phase or several
// turns of a Mystery cast's wait.)
const double _kCastTravelEnd = 0.72;

/// Fraction of the cast-animation playback at which the orb reaches its target
/// and begins to burst — i.e. the moment of impact. The resolution-phase card
/// reveal grows out of the tile at this point so the burst blooms into the
/// card. Kept equal to [_kCastTravelEnd] so the two stay in sync.
const double kCastOrbImpactFraction = _kCastTravelEnd;

/// A spell cast that has been committed but not yet resolved: a glowing orb
/// held at [origin], pulsing, coloured by the casting wizard's identity (see
/// [BattlefieldPainter.colorForWizard]). Covers both a
/// same-turn normal cast (while its owner is picking movement) and a
/// multi-turn Mystery cast waiting out its delay. [rangeRadius], when > 0,
/// draws a translucent ring around [origin] hinting at the spell's reach
/// without revealing the actual committed target tile.
class PendingCastOrb {
  const PendingCastOrb({
    required this.origin,
    required this.color,
    this.rangeRadius = 0,
  });

  final HexCoord origin;
  final Color color;
  final int rangeRadius;
}

// Conveyor chain animation timeline: the token rides the belt for the first
// 82% of playback, then the whole visualization fades out over the rest.
const double _kChainTravelEnd = 0.82;

/// One entity's conveyor-tile push (straight cascade, or a closed loop) to
/// animate: a token rides [path] tile-to-tile over one playback of
/// [BattlefieldPainter.castAnimation] (same timeline as [CastAnimation] --
/// both are "resolved this turn" playback events). Purely cosmetic; built by
/// the UI layer from [ConveyorChainEvent] (tile_entry_resolver.dart), which
/// is the gameplay source of truth for the actual position/damage/death.
class ConveyorChainAnimation {
  const ConveyorChainAnimation({required this.path, required this.killed});

  final List<HexCoord> path;

  /// Whether this push ended in a loop death spiral -- the final flourish
  /// flashes red instead of the usual air color.
  final bool killed;
}

// Avatar movement timeline: wizards walk their route over the first 72% of
// playback; the remainder is the recoil off a contested tile (and, for everyone
// who wasn't in a collision, a beat of stillness before the spells resolve).
const double _kMoveTravelEnd = 0.72;

// How far onto a contested tile a losing wizard actually gets before being
// shoved back. Not all the way: two tokens fully overlapping reads as a
// rendering glitch, whereas a clear near-miss reads as a shoulder-check.
const double _kLungeReach = 0.48;

/// One wizard's walk this turn, to animate rather than teleport: the token
/// slides along [path] tile-to-tile over one playback of
/// [BattlefieldPainter.moveAnimation].
///
/// Every wizard's animation shares that one timeline, which is what makes a
/// collision legible — both tokens arrive at the contested tile on the same
/// frame, and whoever lost recoils off it. Purely cosmetic; built by the UI
/// layer from [AvatarMoveEvent] (turn_loop.dart), which is the gameplay source
/// of truth for where anyone actually ended up.
class AvatarMoveAnimation {
  const AvatarMoveAnimation({
    required this.playerId,
    required this.path,
    this.lungeTile,
    this.wonContestAt,
  });

  final String playerId;

  /// Tiles visited in order, starting with the pre-move origin. A single-entry
  /// path means the wizard ended where they began — worth animating only when
  /// [lungeTile] is set, i.e. they were shoved all the way back to their own
  /// tile, which is the ONE case that distinguishes "lost a collision" from
  /// "chose not to move". Wizards who genuinely stood still are left out by the
  /// caller and drawn from occupancy as usual.
  final List<HexCoord> path;

  /// A contested tile this wizard reached for and lost: the token travels
  /// [_kLungeReach] of the way onto it, then is pushed back to [path]'s last
  /// tile. Null when no collision touched them.
  final HexCoord? lungeTile;

  /// A contested tile this wizard reached for and *kept* by being faster.
  /// Only drives the impact spark — they end there either way.
  final HexCoord? wonContestAt;

  /// The tile a collision visibly happened on, if any.
  HexCoord? get contestedTile => lungeTile ?? wonContestAt;
}

/// A wizard's drawn position and facing on one frame of a walk — the resolved
/// output of [wizardWalkStateAt].
class WizardWalkState {
  const WizardWalkState(this.pos, this.facing);
  final Offset pos;
  final AvatarFacing facing;
}

/// One wizard's position and facing at playback fraction [t] (0..1) of their
/// [anim], on a grid whose (0,0) hex is centred at [center] with the given
/// [hexSize].
///
/// Top-level and public because this is the whole movement timeline in one
/// function: it is what the walk *looks like*, it is the thing worth testing
/// directly, and it is where the later walk-cycle work (advancing [AvatarPose]
/// rather than always drawing the standing frame) will hook in.
///
/// The route is walked at constant speed over [0, _kMoveTravelEnd] regardless
/// of how many tiles it covers, so every wizard's step lands on the same
/// frame — that simultaneity is the whole reason a collision reads as a
/// collision rather than as two unrelated moves. (Speed differences are
/// already expressed by *who wins the tile*, not by who gets there first.)
///
/// A wizard who lost a contest keeps walking past their final tile, partway
/// onto the tile they wanted, and is then shoved back over the remaining
/// `1 - _kMoveTravelEnd` of the timeline — decelerating, since a recoil that
/// arrives at constant speed reads as a second move rather than a rebound.
/// They stay facing the tile they lost throughout: being pushed off a tile
/// you are still reaching for is the pose that tells the story.
WizardWalkState wizardWalkStateAt(
  AvatarMoveAnimation anim,
  double t,
  Offset center,
  double hexSize,
) {
  Offset px(HexCoord hex) => hexToPixel(hex, center, hexSize);
  final route = [for (final hex in anim.path) px(hex)];
  final home = route.last;

  final lunge = anim.lungeTile;
  if (lunge != null) {
    final target = px(lunge);
    final reach = Offset.lerp(home, target, _kLungeReach)!;
    if (t >= _kMoveTravelEnd) {
      final back = ((t - _kMoveTravelEnd) / (1 - _kMoveTravelEnd)).clamp(
        0.0,
        1.0,
      );
      // easeOutBack overshoots slightly past home, away from the contested
      // tile — a stagger, which is exactly what being shoved looks like.
      final eased = Curves.easeOutBack.transform(back);
      return WizardWalkState(
        Offset.lerp(reach, home, eased)!,
        facingForDelta(target - home),
      );
    }
    // Reaching for it: the walked route plus the extra partial step. The
    // per-segment facing _alongRoute derives already turns them toward the
    // contested tile on that last leg, so no special-casing is needed.
    return _alongRoute([...route, reach], t / _kMoveTravelEnd);
  }

  if (t >= _kMoveTravelEnd) return WizardWalkState(home, _finalFacing(route));
  return _alongRoute(route, t / _kMoveTravelEnd);
}

/// Position and facing a fraction [f] (0..1) of the way along [route], measured
/// in *segments* rather than distance — every tile step takes the same time,
/// which is what a grid walk should look like.
WizardWalkState _alongRoute(List<Offset> route, double f) {
  if (route.length < 2) {
    return WizardWalkState(route.first, AvatarFacing.down);
  }
  final segments = route.length - 1;
  final travel = f.clamp(0.0, 1.0) * segments;
  final idx = travel.floor().clamp(0, segments - 1);
  final frac = (travel - idx).clamp(0.0, 1.0);
  final from = route[idx];
  final to = route[idx + 1];
  return WizardWalkState(
    Offset.lerp(from, to, frac)!,
    facingForDelta(to - from),
  );
}

/// Which way a wizard is left facing once they stop: the direction of their
/// last step, so they finish looking where they were headed rather than
/// snapping back to face the viewer.
AvatarFacing _finalFacing(List<Offset> route) => route.length < 2
    ? AvatarFacing.down
    : facingForDelta(route.last - route[route.length - 2]);

/// The battlefield effects one just-resolved spell created, being revealed by
/// the resolution sequence: they scale up out of [origin] (the tile the spell
/// hit) as [BattlefieldPainter.effectBloomAnimation] runs 0→1. Handles are
/// matched by id (clouds/minions) or hex (terrain); anything not in these sets
/// draws at full size as usual. See battle_screen.dart's reveal sequence.
class EffectBloom {
  const EffectBloom({
    required this.origin,
    this.cloudIds = const {},
    this.tileHexes = const {},
    this.minionIds = const {},
  });

  final HexCoord origin;
  final Set<String> cloudIds;
  final Set<HexCoord> tileHexes;
  final Set<String> minionIds;
}

/// Which battlefield handles existed *before* the turn currently resolving
/// began — clouds by id, terrain by hex, creatures by id.
///
/// The engine mutates [BattleState] in place while `runTurn` is still awaiting
/// its next network exchange, and this painter repaints every frame off the
/// free-running pulse controller (not off widget rebuilds). Without a baseline
/// a cloud conjured in Phase 5 is therefore drawn the instant the applicator
/// creates it — several hundred milliseconds before the resolution sequence
/// gets to hide it again and bloom it out of its cast tile, which reads as the
/// effect flickering in, vanishing, then arriving properly.
///
/// So while a turn is resolving, anything *not* in this snapshot is held back
/// exactly like [BattlefieldPainter.hiddenCloudIds] holds it back afterwards.
/// Null means no turn is resolving and everything on the field may draw.
class ResolutionBaseline {
  const ResolutionBaseline({
    required this.cloudIds,
    required this.tileHexes,
    required this.minionIds,
  });

  final Set<String> cloudIds;
  final Set<HexCoord> tileHexes;
  final Set<String> minionIds;
}

// ── Painter ───────────────────────────────────────────────────────────────────

class BattlefieldPainter extends CustomPainter {
  BattlefieldPainter({
    required this.radius,
    required this.hexSize,
    required this.occupancy,
    this.localPlayerId,
    this.highlightHex,
    this.movePath = const [],
    this.spellRangeRadius = 0,
    this.casterPos,
    this.minions = const [],
    this.localTeamId,
    this.barrierRings = const {},
    this.pulseAnimation,
    this.castAnimations = const [],
    this.castAnimation,
    this.tileEffects = const {},
    this.clouds = const [],
    this.directionPickHexes = const [],
    this.conveyorChainAnimations = const [],
    this.pendingCastOrbs = const [],
    this.scryRevealHex,
    this.meleePickHexes = const [],
    this.freeMovePickHexes = const [],
    this.hiddenCloudIds = const {},
    this.hiddenTileHexes = const {},
    this.hiddenMinionIds = const {},
    this.resolutionBaseline,
    this.effectBloom,
    this.effectBloomAnimation,
    this.terrainBeneath = false,
    this.avatarMoveAnimations = const [],
    this.moveAnimation,
    this.avatarAtlas,
    this.avatarAssignment = const AvatarAssignment(),
  }) : super(
         repaint: Listenable.merge([
           pulseAnimation,
           castAnimation,
           effectBloomAnimation,
           moveAnimation,
         ]),
       );

  final int radius;
  final double hexSize;

  /// playerId → current position. Players absent from this map are off-field.
  final Map<String, HexCoord> occupancy;

  /// The local player's id — their token is drawn in gold with a star glyph
  /// (or, once [avatarAtlas] has decoded, a gold ring beneath their sprite).
  final String? localPlayerId;

  /// This turn's wizard walks, played back over [moveAnimation]. While this is
  /// non-empty the listed wizards are drawn at their interpolated position
  /// instead of their [occupancy] entry — see [_animatedTokenPositions]. The
  /// caller clears it when playback ends, which is not optional: displacement
  /// resolved *after* the movement phase (knockback, Zephyr) moves the same
  /// wizards again, and a stale animation would pin their token to where the
  /// movement phase left them.
  final List<AvatarMoveAnimation> avatarMoveAnimations;

  /// Drives [avatarMoveAnimations], 0→1 over one turn's movement. Merged into
  /// the repaint listenable so the walk animates without a widget rebuild.
  final Animation<double>? moveAnimation;

  /// The decoded avatar sprite sheet, or null while it loads (or if it failed).
  /// Null means every wizard falls back to the placeholder disc token, which is
  /// exactly what the board looked like before sprites existed.
  final ui.Image? avatarAtlas;

  /// Which sprite each wizard wears. See AvatarAssignment — today a pure
  /// function of playerId, later the player's own pick.
  final AvatarAssignment avatarAssignment;

  /// Hex to highlight as a spell target (golden ring).
  final HexCoord? highlightHex;

  /// Tiles to highlight as the player's chosen move path (blue rings).
  final List<HexCoord> movePath;

  /// When > 0, draw a subtle range tint around [casterPos] to show the spell
  /// targeting area. Ignored if [casterPos] is null.
  final int spellRangeRadius;

  /// Position of the local player, used for the spell range ring.
  final HexCoord? casterPos;

  /// Live minions to render on the field.
  final List<Minion> minions;

  /// The local player's teamId — friendly minions are drawn in gold, enemies in red.
  final String? localTeamId;

  /// Maps hex positions to the list of active barrier elements at that position.
  /// Used to draw a pulsing elemental glow ring around each shielded entity.
  final Map<HexCoord, List<SpellAffinity>> barrierRings;

  /// Drives the barrier ring pulse. Passed as [CustomPainter.repaint] so the
  /// painter redraws on every tick without triggering a widget rebuild.
  final Animation<double>? pulseAnimation;

  /// Spell casts resolved this turn, to animate as glowing orbs. Fixed for
  /// the duration of one playback of [castAnimation]; the caller replaces
  /// this list (via a rebuild) only when a new turn resolves.
  final List<CastAnimation> castAnimations;

  /// Drives cast-animation playback, 0→1 over one turn's worth of casts.
  /// Passed as [CustomPainter.repaint] alongside [pulseAnimation] so the
  /// painter redraws every tick without a widget rebuild.
  final Animation<double>? castAnimation;

  /// Permanent terrain modifications placed by tileModification spells
  /// (lava / impassable / slow / conveyor). Drawn as a tile overlay under
  /// the minion/wizard tokens.
  final Map<HexCoord, TileEffect> tileEffects;

  /// Active cloud effects placed by cloud spells. Drawn as a translucent
  /// overlay above tokens (radius from [CloudObject.position]).
  final List<CloudObject> clouds;

  /// Resolution-reveal hold-back: effects newly created this turn that haven't
  /// had their spell's card resolve yet are skipped entirely (matched by cloud
  /// id / terrain hex / minion id) so they pop in only when their card does.
  final Set<String> hiddenCloudIds;
  final Set<HexCoord> hiddenTileHexes;
  final Set<String> hiddenMinionIds;

  /// The same hold-back, applied *during* the turn rather than after it: while
  /// this is non-null, any cloud/terrain/creature that wasn't on the field when
  /// the turn started is skipped. Hands off to the three sets above the moment
  /// `runTurn` returns. See [ResolutionBaseline].
  final ResolutionBaseline? resolutionBaseline;

  /// The effect group currently blooming into view (one spell's freshly
  /// revealed creations), scaled up out of [EffectBloom.origin] by
  /// [effectBloomAnimation]. Null when nothing is blooming.
  final EffectBloom? effectBloom;

  /// Drives [effectBloom]'s 0→1 grow-in. Merged into the repaint listenable so
  /// the bloom animates without a widget rebuild.
  final Animation<double>? effectBloomAnimation;

  /// Whether a scenery backdrop is drawn underneath this painter (see
  /// lib/ui/scenery/). When true the playable tiles are washed rather than
  /// filled, so the terrain shows through inside the grid, and the tile rim is
  /// drawn as a light line over a dark halo so cells stay countable against any
  /// terrain. Defaults to false, which keeps the original opaque stone board —
  /// that is still what shows if the atlas fails to load.
  final bool terrainBeneath;

  /// The 6 neighbor hexes of a ConveyorTile about to be created, highlighted
  /// (air-colored) while the caster is choosing a push direction. See
  /// battle_screen.dart's pickingDirection phase.
  final List<HexCoord> directionPickHexes;

  /// Conveyor-tile pushes resolved this turn, to animate as a token riding
  /// the belt tile-to-tile. Fixed for the duration of one playback of
  /// [castAnimation]; the caller replaces this list (via a rebuild) only
  /// when a new turn resolves.
  final List<ConveyorChainAnimation> conveyorChainAnimations;

  /// Spells committed but not yet resolved -- a held, pulsing orb per cast.
  /// Covers both a same-turn normal cast (while movement is being chosen)
  /// and any in-flight Mystery casts (from [BattleState.pendingDelayedSpells],
  /// shared/public state, so this also renders the opponent's pending
  /// Mystery casts, not just the local player's own).
  final List<PendingCastOrb> pendingCastOrbs;

  /// Airy Scrying Pool reveal (MESH_ARCHITECTURE.md §13b): the opponent's
  /// committed spell-target tile for this turn, when an active
  /// DivinationLink resolved one. Drawn as a violet "eye" ring, distinct
  /// from [highlightHex] (the local player's own selected target).
  final HexCoord? scryRevealHex;

  /// Adjacent hostile tiles offered during the resolution-phase melee prompt
  /// (battle_screen.dart's [_pickingMelee] state) — highlighted so the
  /// player can see which tiles are valid melee targets.
  final List<HexCoord> meleePickHexes;

  /// Adjacent free tiles offered during the post-resolution Airy Barrier
  /// burst prompt (battle_screen.dart's [_pickingFreeMove] state) — air
  /// -colored so it reads as the barrier's own element, and so it's never
  /// confused with the rubric-red melee prompt.
  final List<HexCoord> freeMovePickHexes;

  static const _kScryReveal = Color(0xFF9B5FC0); // violet — third-eye glimpse
  static const _kMeleePick = Color(0xFF7A1F1F); // rubric red — melee prompt

  static const _kTileLight = Color(0xFFD5CCB2); // stone tile fill
  static const _kTileDark = Color(0xFFC2B89A); // alternate tile (checkerboard)
  static const _kEdge = Color(0xFF4A3018); // tile border

  // ── Terrain-beneath variants (see [terrainBeneath]) ────────────────────────
  // The opaque fills above would hide the scenery entirely, so with terrain
  // underneath the checkerboard becomes a wash and the rim does the work of
  // keeping cells countable. Both washes are needed: tinting only the light
  // cells reads as "some tiles are highlighted" rather than as a grid.
  static const _kTileLightWash = Color(0x1FFFF4DC); // warm lift, ~12% alpha
  static const _kTileDarkWash = Color(0x26241505); // cool sink, ~15% alpha

  // A single 1px line vanishes wherever the terrain happens to match its
  // luminance — over snow the dark edge is fine, over pinewood it is invisible.
  // Drawing a dark halo under a light line keeps the lattice readable on both.
  static const _kEdgeHalo = Color(0xCC1A0F04);
  static const _kEdgeLine = Color(0x99E8D9B8);
  static const _kLocalToken = Color(0xFFB8860B); // illumination gold
  static const _kFoeToken = Color(0xFF7A1F1F); // rubric red

  // Extra wizard identity colors for 3-6 player experimental matches, used
  // in [colorForWizard] after the local (gold) and first-opponent (red)
  // slots are taken — assigned in avatar list order so every wizard reads
  // as a stable, distinct caster color.
  static const List<Color> _kExtraWizardColors = [
    Color(0xFF3A7FCC), // azure
    Color(0xFF5FA83C), // verdant
    Color(0xFF9B5FC0), // violet
    Color(0xFFCC7A2E), // amber
  ];

  // Elemental colors — minion label tint, barrier ring glow, and the chain
  // indicator. [colorForAffinity] is the public accessor for callers (e.g.
  // battle_screen.dart) that want the *element's* color rather than the
  // caster's — see [colorForWizard] for the cast-orb/caster-identity color.
  static const Map<SpellAffinity, Color> _kElementColor = {
    SpellAffinity.fire: Color(0xFFE05020),
    SpellAffinity.earth: Color(0xFF8B6033),
    SpellAffinity.water: Color(0xFF2090E0),
    SpellAffinity.air: Color(0xFFD8C840),
  };

  /// The elemental color for a spell's/minion's/chain's primary affinity.
  static Color colorForAffinity(SpellAffinity affinity) =>
      _kElementColor[affinity] ?? Colors.white;

  /// The cast-orb color for whichever wizard cast the spell: gold for the
  /// local player, red for the first opponent (matching the existing board
  /// token colors), and a fixed extra palette for any further wizards in a
  /// 3-6 player experimental match, assigned by their order in
  /// [orderedPlayerIds] (typically `BattleState.avatars` order, which is
  /// stable for the life of a match). Keeping this by caster rather than by
  /// spell element is the point: in a multi-wizard duel, the orb must answer
  /// "who cast that" at a glance, not "what element was it."
  static Color colorForWizard(
    String playerId, {
    required String? localPlayerId,
    required List<String> orderedPlayerIds,
  }) {
    if (playerId == localPlayerId) return _kLocalToken;
    final opponentIds =
        orderedPlayerIds.where((id) => id != localPlayerId).toList();
    final idx = opponentIds.indexOf(playerId);
    if (idx <= 0) return _kFoeToken;
    final extraIdx = idx - 1;
    return extraIdx < _kExtraWizardColors.length
        ? _kExtraWizardColors[extraIdx]
        : _kFoeToken;
  }

  // Terrain/cloud color follows the elemental flavor that creates it (same
  // palette as minion labels / barrier rings / cast orbs).
  Color _colorForTileEffect(TileEffect effect) => switch (effect) {
    FloorIsLava() => _kElementColor[SpellAffinity.fire]!,
    ImpassableTile() => _kElementColor[SpellAffinity.earth]!,
    SlowTile() => _kElementColor[SpellAffinity.water]!,
    ConveyorTile() => _kElementColor[SpellAffinity.air]!,
    // Wild magic (Glacier / Chasm) follows the same rule: the elemental flavor
    // of the effect that creates it. Glacier is Water, Chasm is Earth.
    IceTile() => _kElementColor[SpellAffinity.water]!,
    ChasmTile() => _kElementColor[SpellAffinity.earth]!,
  };

  Color _colorForCloudKind(CloudKind kind) => switch (kind) {
    ToxicCloud() => _kElementColor[SpellAffinity.fire]!,
    DustCloud() => _kElementColor[SpellAffinity.earth]!,
    WaterCloud() => _kElementColor[SpellAffinity.water]!,
    MobileCloud() => _kElementColor[SpellAffinity.air]!,
  };

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);

    // Pass 1 — tiles
    for (int q = -radius; q <= radius; q++) {
      final r1 = max(-radius, -q - radius);
      final r2 = min(radius, -q + radius);
      for (int r = r1; r <= r2; r++) {
        _drawTile(canvas, HexCoord(q, r), center);
      }
    }

    // Shared pulse value -- drives the barrier-ring glow, cloud puffs, and
    // the conveyor wind-gust animation, all off the same free-running
    // _pulseController (no extra AnimationController).
    final pulse = pulseAnimation?.value ?? 0.5;

    // Pass 1.5 — permanent terrain effects (over tiles, under highlights).
    // Held-back terrain (not yet revealed by its spell's card) is skipped;
    // terrain currently blooming in scales up out of the cast tile.
    for (final entry in tileEffects.entries) {
      if (_tileHeldBack(entry.key)) continue;
      _bloomWrap(
        canvas,
        center,
        () => _drawTileEffect(canvas, entry.key, center, entry.value, pulse),
        tileHex: entry.key,
      );
    }

    // Pass 2 — highlights
    // Spell range tint (shown during action phase when a spell is selected).
    if (casterPos != null && spellRangeRadius > 0) {
      for (int q = -radius; q <= radius; q++) {
        final r1 = max(-radius, -q - radius);
        final r2 = min(radius, -q + radius);
        for (int r = r1; r <= r2; r++) {
          final coord = HexCoord(q, r);
          if (hexDistance(casterPos!, coord) <= spellRangeRadius) {
            _drawRangeTint(canvas, coord, center);
          }
        }
      }
    }
    // Move path (shown during movement phase, one highlight per step).
    for (final hex in movePath) {
      _drawHighlight(canvas, hex, center, const Color(0xFF3A7FCC));
    }
    // Spell target (on top of range tint).
    if (highlightHex != null) {
      _drawHighlight(canvas, highlightHex!, center, const Color(0xFFB8860B));
    }
    // Airy Scrying Pool reveal — drawn after the local player's own target
    // highlight so it's never mistaken for it.
    if (scryRevealHex != null) {
      _drawHighlight(canvas, scryRevealHex!, center, _kScryReveal);
    }
    // Conveyor direction-pick candidates (air-colored, on top of everything
    // else in this pass so they're unambiguous during the prompt).
    for (final hex in directionPickHexes) {
      _drawHighlight(canvas, hex, center, _kElementColor[SpellAffinity.air]!);
    }
    // Resolution-phase melee prompt candidates.
    for (final hex in meleePickHexes) {
      _drawHighlight(canvas, hex, center, _kMeleePick);
    }
    // Post-resolution Airy Barrier burst free-move candidates.
    for (final hex in freeMovePickHexes) {
      _drawHighlight(canvas, hex, center, _kElementColor[SpellAffinity.air]!);
    }

    // Pass 3 — minion tokens (Big/EEEE creatures draw one token per
    // occupied tile, label on the anchor tile only). A just-summoned creature
    // is held back until its card resolves, then blooms out of the cast tile.
    for (final m in minions) {
      if (!m.isAlive) continue;
      if (_minionHeldBack(m.id)) continue;
      final friendly = m.teamId == localTeamId;
      _bloomWrap(canvas, center, () {
        for (final tile in m.occupiedTiles) {
          _drawMinionToken(
            canvas,
            _hexToPixel(tile, center),
            m,
            friendly,
            showLabel: tile == m.position,
          );
        }
      }, minionId: m.id);
    }

    // Pass 4 — wizard tokens (on top of minions). A wizard mid-walk is drawn
    // at their interpolated position and facing instead of their occupancy
    // entry; everyone else stands on their tile facing the viewer.
    final walking = _walkStates(center);
    for (final entry in occupancy.entries) {
      final isLocal = entry.key == localPlayerId;
      final walk = walking[entry.key];
      _drawToken(
        canvas,
        walk?.pos ?? _hexToPixel(entry.value, center),
        isLocal,
        entry.key,
        facing: walk?.facing ?? AvatarFacing.down,
      );
    }

    // Pass 4.2 — collision impact. Drawn after both tokens so the spark sits
    // between them at the moment they meet.
    if (walking.isNotEmpty) {
      _drawCollisionSparks(canvas, center);
    }

    // Pass 4.5 — clouds (over tokens so entities read through the haze;
    // under barrier rings/cast animations so those stay fully legible). A
    // freshly conjured cloud is held back until its card resolves, then
    // blooms out of the cast tile.
    for (final cloud in clouds) {
      if (_cloudHeldBack(cloud.id)) continue;
      _bloomWrap(
        canvas,
        center,
        () => _drawCloud(canvas, center, cloud, pulse),
        cloudId: cloud.id,
      );
    }

    // Pass 5 — barrier rings (pulsing glow over all shielded entities). Keyed
    // by the entity's FINAL tile, so a shielded wizard mid-walk would leave
    // their ring behind at the destination; ride along with the token instead.
    final ringCarriers = {
      for (final entry in occupancy.entries)
        if (walking[entry.key] != null) entry.value: walking[entry.key]!.pos,
    };
    for (final entry in barrierRings.entries) {
      _drawBarrierRing(
        canvas,
        ringCarriers[entry.key] ?? _hexToPixel(entry.key, center),
        _blendBarrierColors(entry.value),
        pulse,
      );
    }

    // Pass 5.5 — pending cast orbs (committed, not yet resolved): a range
    // hint tint under a pulsing orb, per held/Mystery cast.
    for (final orb in pendingCastOrbs) {
      if (orb.rangeRadius > 0) {
        for (int q = -radius; q <= radius; q++) {
          final r1 = max(-radius, -q - radius);
          final r2 = min(radius, -q + radius);
          for (int r = r1; r <= r2; r++) {
            final coord = HexCoord(q, r);
            if (hexDistance(orb.origin, coord) <= orb.rangeRadius) {
              _drawRangeTint(canvas, coord, center);
            }
          }
        }
      }
      _drawCastOrb(
        canvas,
        _hexToPixel(orb.origin, center),
        orb.color,
        radiusScale: 0.85 + pulse * 0.15,
        alpha: 0.7 + pulse * 0.3,
      );
    }

    // Pass 6 — cast animations (glow → fly → burst), on top of everything.
    if (castAnimations.isNotEmpty) {
      final t = (castAnimation?.value ?? 1.0).clamp(0.0, 1.0);
      for (final anim in castAnimations) {
        _drawCastAnimation(canvas, center, anim, t);
      }
    }

    // Pass 6.5 — conveyor chain/loop animations (belt ride), same timeline.
    if (conveyorChainAnimations.isNotEmpty) {
      final t = (castAnimation?.value ?? 1.0).clamp(0.0, 1.0);
      for (final anim in conveyorChainAnimations) {
        _drawConveyorChainAnimation(canvas, center, anim, t);
      }
    }
  }

  // ── Reveal hold-back ──────────────────────────────────────────────────────
  //
  // Two sources, checked together: the post-turn per-spell sets, and — while a
  // turn is still resolving — "anything born since the turn started". These are
  // evaluated at *paint* time rather than being folded into one set by the
  // caller, because the painter repaints off the pulse controller between
  // widget rebuilds: a set computed in build() would already be stale by the
  // time the applicator conjures the cloud. See [ResolutionBaseline].

  bool _cloudHeldBack(String id) {
    if (hiddenCloudIds.contains(id)) return true;
    final base = resolutionBaseline;
    return base != null && !base.cloudIds.contains(id);
  }

  bool _tileHeldBack(HexCoord hex) {
    if (hiddenTileHexes.contains(hex)) return true;
    final base = resolutionBaseline;
    return base != null && !base.tileHexes.contains(hex);
  }

  bool _minionHeldBack(String id) {
    if (hiddenMinionIds.contains(id)) return true;
    final base = resolutionBaseline;
    return base != null && !base.minionIds.contains(id);
  }

  /// Runs [draw] normally, unless the effect it renders (identified by exactly
  /// one of [cloudId]/[tileHex]/[minionId]) is in [effectBloom]'s reveal set —
  /// in which case the canvas is scaled about [EffectBloom.origin] by the
  /// current bloom progress, so the effect grows out of the cast tile.
  void _bloomWrap(
    Canvas canvas,
    Offset center,
    void Function() draw, {
    String? cloudId,
    HexCoord? tileHex,
    String? minionId,
  }) {
    final bloom = effectBloom;
    final inBloom =
        bloom != null &&
        ((cloudId != null && bloom.cloudIds.contains(cloudId)) ||
            (tileHex != null && bloom.tileHexes.contains(tileHex)) ||
            (minionId != null && bloom.minionIds.contains(minionId)));
    if (!inBloom) {
      draw();
      return;
    }
    final p = (effectBloomAnimation?.value ?? 1.0).clamp(0.02, 1.0);
    final origin = _hexToPixel(bloom.origin, center);
    canvas.save();
    canvas.translate(origin.dx, origin.dy);
    canvas.scale(p);
    canvas.translate(-origin.dx, -origin.dy);
    draw();
    canvas.restore();
  }

  void _drawTile(Canvas canvas, HexCoord coord, Offset center) {
    final pos = _hexToPixel(coord, center);
    final path = _hexPath(pos);

    // Subtle checkerboard tint so tiles are distinguishable.
    final light = (coord.q + coord.r + coord.q * coord.r).isEven;

    if (!terrainBeneath) {
      canvas.drawPath(path, Paint()..color = light ? _kTileLight : _kTileDark);
      canvas.drawPath(
        path,
        Paint()
          ..color = _kEdge
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.0,
      );
      return;
    }

    // Terrain underneath: wash instead of fill, and a two-tone rim. The halo
    // is stroked first and wider, so the light line reads as sitting on top of
    // a shadow rather than as a doubled border.
    canvas.drawPath(
      path,
      Paint()..color = light ? _kTileLightWash : _kTileDarkWash,
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = _kEdgeHalo
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.6,
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = _kEdgeLine
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0,
    );
  }

  void _drawRangeTint(Canvas canvas, HexCoord coord, Offset center) {
    canvas.drawPath(
      _hexPath(_hexToPixel(coord, center)),
      Paint()
        ..color = const Color(0xFFB8860B).withValues(alpha: 0.12)
        ..style = PaintingStyle.fill,
    );
  }

  void _drawHighlight(
    Canvas canvas,
    HexCoord coord,
    Offset center,
    Color color,
  ) {
    final pos = _hexToPixel(coord, center);
    final path = _hexPath(pos);
    canvas.drawPath(
      path,
      Paint()
        ..color = color.withValues(alpha: 0.25)
        ..style = PaintingStyle.fill,
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );
  }

  /// Draws one wizard standing on [pos]: their character sprite if the atlas
  /// has decoded, otherwise the original coloured disc.
  ///
  /// Either way the identity colour is what answers "who is that" at a glance —
  /// as the disc's fill, or as the ring the sprite stands in. Two wizards can
  /// wear the same face (a player will eventually be free to pick one already
  /// taken); nobody shares a ring colour.
  void _drawToken(
    Canvas canvas,
    Offset pos,
    bool isLocal,
    String playerId, {
    AvatarFacing facing = AvatarFacing.down,
  }) {
    final atlas = avatarAtlas;
    if (atlas != null) {
      _drawSpriteToken(canvas, pos, isLocal, playerId, facing, atlas);
      return;
    }
    _drawDiscToken(canvas, pos, isLocal, playerId);
  }

  void _drawSpriteToken(
    Canvas canvas,
    Offset pos,
    bool isLocal,
    String playerId,
    AvatarFacing facing,
    ui.Image atlas,
  ) {
    final color = isLocal ? _kLocalToken : _kFoeToken;
    // The sprite stands ON the tile rather than filling it: feet just below the
    // hex centre, body rising out of it. Sized off hexSize so it scales with
    // the board, and kept under a full tile tall so a wizard never hides the
    // token behind them.
    final h = hexSize * 1.65;
    final w = h * kAvatarFrameWidth / kAvatarFrameHeight;
    final feet = pos.dy + hexSize * 0.30;

    // Ground shadow + identity ring, both at the feet. The ring reads as the
    // wizard's own colour without tinting the artwork itself.
    final ringRect = Rect.fromCenter(
      center: Offset(pos.dx, feet - hexSize * 0.06),
      width: hexSize * 0.86,
      height: hexSize * 0.40,
    );
    canvas.drawOval(
      ringRect.inflate(1.5),
      Paint()..color = Colors.black.withValues(alpha: 0.32),
    );
    canvas.drawOval(
      ringRect,
      Paint()
        ..color = color.withValues(alpha: 0.90)
        ..style = PaintingStyle.stroke
        ..strokeWidth = isLocal ? 2.6 : 2.0,
    );

    canvas.drawImageRect(
      atlas,
      avatarAssignment.artFor(playerId).frameRect(facing, AvatarPose.stand),
      Rect.fromLTWH(pos.dx - w / 2, feet - h, w, h),
      // Pixel art upscaled ~2x: nearest-neighbour keeps it crisp, where any
      // smoothing turns 24x32 sprites into mush.
      Paint()
        ..filterQuality = FilterQuality.none
        ..isAntiAlias = false,
    );
  }

  void _drawDiscToken(
    Canvas canvas,
    Offset pos,
    bool isLocal,
    String playerId,
  ) {
    final r = hexSize * 0.36;
    final color = isLocal ? _kLocalToken : _kFoeToken;

    // Drop shadow
    canvas.drawCircle(
      pos + const Offset(0, 1.5),
      r,
      Paint()..color = Colors.black.withValues(alpha: 0.30),
    );

    // Fill
    canvas.drawCircle(pos, r, Paint()..color = color);

    // Rim highlight
    canvas.drawCircle(
      pos,
      r,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.30)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2,
    );

    // Label: ★ for local player, first letter of playerId for opponents
    final label = isLocal
        ? '★'
        : (playerId.isNotEmpty ? playerId[0].toUpperCase() : '?');
    final tp = TextPainter(
      text: TextSpan(
        text: label,
        style: TextStyle(
          fontSize: hexSize * (isLocal ? 0.32 : 0.28),
          fontWeight: FontWeight.bold,
          color: Colors.white,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, pos - Offset(tp.width / 2, tp.height / 2));
  }

  void _drawMinionToken(
    Canvas canvas,
    Offset pos,
    Minion m,
    bool friendly, {
    bool showLabel = true,
  }) {
    final r = hexSize * 0.24;
    final fillColor = friendly ? _kLocalToken : _kFoeToken;
    final labelColor = _kElementColor[m.affinity] ?? Colors.white;

    canvas.drawCircle(
      pos + const Offset(0, 1.2),
      r,
      Paint()..color = Colors.black.withValues(alpha: 0.28),
    );
    canvas.drawCircle(
      pos,
      r,
      Paint()..color = fillColor.withValues(alpha: 0.85),
    );
    canvas.drawCircle(
      pos,
      r,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.25)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0,
    );

    if (!showLabel) return;

    // Elemental-affinity initial (F/E/W/A) -- creature family is no longer
    // Spirit/Hound (v2.4); affinity + tint already carry that identity.
    final label = switch (m.affinity) {
      SpellAffinity.fire => 'F',
      SpellAffinity.earth => 'E',
      SpellAffinity.water => 'W',
      SpellAffinity.air => 'A',
    };
    final tp = TextPainter(
      text: TextSpan(
        text: label,
        style: TextStyle(
          fontSize: hexSize * 0.26,
          fontWeight: FontWeight.bold,
          color: labelColor,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, pos - Offset(tp.width / 2, tp.height / 2));
  }

  // ── Terrain effects (tileModification spells) ─────────────────────────────

  void _drawTileEffect(
    Canvas canvas,
    HexCoord coord,
    Offset center,
    TileEffect effect,
    double pulse,
  ) {
    final pos = _hexToPixel(coord, center);
    final path = _hexPath(pos);
    final color = _colorForTileEffect(effect);

    // Dark base first so the colored fill reads as saturated rather than
    // washing out against the off-white/tan tile fill underneath it.
    canvas.drawPath(
      path,
      Paint()..color = Colors.black.withValues(alpha: 0.14),
    );
    canvas.drawPath(path, Paint()..color = color.withValues(alpha: 0.48));

    canvas.save();
    canvas.clipPath(path);
    switch (effect) {
      case FloorIsLava():
        _drawLavaAccents(canvas, coord, pos);
      case ImpassableTile():
        _drawCrosshatch(canvas, pos, color);
      case SlowTile():
        _drawSludgeLines(canvas, pos, color);
      case ConveyorTile(:final direction, :final directionSet):
        if (directionSet) {
          _drawConveyorArrows(canvas, pos, color, direction, pulse);
        } else {
          _drawConveyorPending(canvas, pos, color);
        }
      case IceTile():
        _drawIceSheen(canvas, pos, color);
      case ChasmTile():
        _drawChasmRift(canvas, coord, pos);
    }
    canvas.restore();

    canvas.drawPath(
      path,
      Paint()
        ..color = color.withValues(alpha: 0.9)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );
  }

  void _drawLavaAccents(Canvas canvas, HexCoord coord, Offset pos) {
    const emberColor = Color(0xFFFFD060);
    for (int i = 0; i < 3; i++) {
      final jx = (_pseudoRandom(coord.q, coord.r, i * 2) - 0.5) * hexSize * 1.1;
      final jy =
          (_pseudoRandom(coord.q, coord.r, i * 2 + 1) - 0.5) * hexSize * 1.1;
      canvas.drawCircle(
        pos + Offset(jx, jy),
        hexSize * 0.05,
        Paint()
          ..color = emberColor.withValues(alpha: 0.85)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, hexSize * 0.03),
      );
    }
    final crack = Path()
      ..moveTo(pos.dx - hexSize * 0.3, pos.dy - hexSize * 0.15)
      ..lineTo(pos.dx - hexSize * 0.05, pos.dy + hexSize * 0.05)
      ..lineTo(pos.dx + hexSize * 0.15, pos.dy - hexSize * 0.1)
      ..lineTo(pos.dx + hexSize * 0.35, pos.dy + hexSize * 0.2);
    canvas.drawPath(
      crack,
      Paint()
        ..color = emberColor.withValues(alpha: 0.6)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2,
    );
  }

  /// Glacier's ice: a few bright, parallel slide-lines, deliberately all in
  /// one direction so the tile reads as "you will keep going" rather than as
  /// a wall.
  void _drawIceSheen(Canvas canvas, Offset pos, Color color) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.55)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.1;
    final s = hexSize * 0.7;
    for (var i = -1; i <= 1; i++) {
      final off = i * hexSize * 0.32;
      canvas.drawLine(
        Offset(pos.dx - s, pos.dy + off - s * 0.25),
        Offset(pos.dx + s, pos.dy + off + s * 0.25),
        paint,
      );
    }
    canvas.drawCircle(
      pos,
      hexSize * 0.5,
      Paint()
        ..color = color.withValues(alpha: 0.18)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, hexSize * 0.25),
    );
  }

  /// Chasm: a dark jagged rift. Drawn as a void rather than a wall — this
  /// tile blocks movement but not targeting, so it must not read like the
  /// Earth crosshatch that also blocks line of sight.
  void _drawChasmRift(Canvas canvas, HexCoord coord, Offset pos) {
    canvas.drawCircle(
      pos,
      hexSize * 0.62,
      Paint()..color = const Color(0xFF120C08).withValues(alpha: 0.75),
    );
    final rift = Path()..moveTo(pos.dx - hexSize * 0.55, pos.dy);
    for (var i = 1; i <= 4; i++) {
      final t = i / 4.0;
      final jitter = (_pseudoRandom(coord.q, coord.r, i) - 0.5) * hexSize * 0.5;
      rift.lineTo(pos.dx - hexSize * 0.55 + hexSize * 1.1 * t, pos.dy + jitter);
    }
    canvas.drawPath(
      rift,
      Paint()
        ..color = Colors.black.withValues(alpha: 0.9)
        ..style = PaintingStyle.stroke
        ..strokeWidth = hexSize * 0.16
        ..strokeCap = StrokeCap.round,
    );
  }

  void _drawCrosshatch(Canvas canvas, Offset pos, Color color) {
    final paint = Paint()
      ..color = color.withValues(alpha: 0.65)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    final s = hexSize * 0.9;
    for (double d = -s; d <= s; d += hexSize * 0.35) {
      canvas.drawLine(
        Offset(pos.dx + d - s, pos.dy - s),
        Offset(pos.dx + d + s, pos.dy + s),
        paint,
      );
      canvas.drawLine(
        Offset(pos.dx + d - s, pos.dy + s),
        Offset(pos.dx + d + s, pos.dy - s),
        paint,
      );
    }
  }

  void _drawSludgeLines(Canvas canvas, Offset pos, Color color) {
    final paint = Paint()
      ..color = color.withValues(alpha: 0.6)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    for (int i = -1; i <= 1; i++) {
      final y = pos.dy + i * hexSize * 0.28;
      final path = Path()..moveTo(pos.dx - hexSize * 0.6, y);
      path.quadraticBezierTo(
        pos.dx - hexSize * 0.2,
        y - hexSize * 0.15,
        pos.dx,
        y,
      );
      path.quadraticBezierTo(
        pos.dx + hexSize * 0.2,
        y + hexSize * 0.15,
        pos.dx + hexSize * 0.6,
        y,
      );
      canvas.drawPath(path, paint);
    }
  }

  /// Wind gust: one static center chevron for unambiguous direction
  /// (screenshot-safe) plus 3 animated tapered streaks flowing from the
  /// upstream to downstream edge, looping via [pulse] (the free-running
  /// _pulseController already used for barrier rings/cloud puffs).
  void _drawConveyorArrows(
    Canvas canvas,
    Offset pos,
    Color color,
    HexCoord direction,
    double pulse,
  ) {
    final angle = _directionAngle(direction);
    canvas.save();
    canvas.translate(pos.dx, pos.dy);
    canvas.rotate(angle);

    final gustPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    for (int i = 0; i < 3; i++) {
      final t = (pulse + i / 3) % 1.0;
      final travel = hexSize * (-0.55 + 1.1 * t);
      final wiggle = sin(t * 2 * pi + i) * hexSize * 0.05;
      final alpha = sin(pi * t).clamp(0.0, 1.0);
      gustPaint
        ..color = color.withValues(alpha: 0.55 * alpha)
        ..strokeWidth = hexSize * 0.05 * (0.5 + alpha);
      canvas.drawLine(
        Offset(travel - hexSize * 0.16, wiggle),
        Offset(travel + hexSize * 0.05, wiggle * 0.6),
        gustPaint,
      );
    }

    final chevronPaint = Paint()
      ..color = color.withValues(alpha: 0.8)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round;
    final chevron = Path()
      ..moveTo(-hexSize * 0.10, -hexSize * 0.18)
      ..lineTo(hexSize * 0.18, 0)
      ..lineTo(-hexSize * 0.10, hexSize * 0.18);
    canvas.drawPath(chevron, chevronPaint);

    canvas.restore();
  }

  /// Direction not yet chosen (set at resolution time, see terrain.dart) —
  /// a dashed ring + "?" glyph instead of a directional arrow.
  void _drawConveyorPending(Canvas canvas, Offset pos, Color color) {
    final paint = Paint()
      ..color = color.withValues(alpha: 0.7)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    const dashCount = 10;
    final r = hexSize * 0.5;
    for (int i = 0; i < dashCount; i++) {
      final a0 = (i / dashCount) * 2 * pi;
      canvas.drawArc(
        Rect.fromCircle(center: pos, radius: r),
        a0,
        (pi / dashCount) * 0.6,
        false,
        paint,
      );
    }
    final tp = TextPainter(
      text: TextSpan(
        text: '?',
        style: TextStyle(
          fontSize: hexSize * 0.32,
          fontWeight: FontWeight.bold,
          color: color,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, pos - Offset(tp.width / 2, tp.height / 2));
  }

  double _directionAngle(HexCoord direction) {
    final delta = Offset(
      hexSize * (3 / 2 * direction.q),
      hexSize * (sqrt(3) / 2 * direction.q + sqrt(3) * direction.r),
    );
    return atan2(delta.dy, delta.dx);
  }

  // ── Clouds ──────────────────────────────────────────────────────────────────

  void _drawCloud(
    Canvas canvas,
    Offset center,
    CloudObject cloud,
    double pulse,
  ) {
    final color = _colorForCloudKind(cloud.kind);
    for (final coord in _hexesInRadius(cloud.position, cloud.radius)) {
      final pos = _hexToPixel(coord, center);
      final path = _hexPath(pos);
      // Dark base first so the colored fill reads as saturated rather than
      // washing out against the off-white/tan tile fill underneath it.
      canvas.drawPath(
        path,
        Paint()..color = Colors.black.withValues(alpha: 0.10),
      );
      canvas.drawPath(
        path,
        Paint()..color = color.withValues(alpha: 0.34 + pulse * 0.10),
      );
      canvas.drawPath(
        path,
        Paint()
          ..color = color.withValues(alpha: 0.6)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.8,
      );

      for (int i = 0; i < 3; i++) {
        final jx =
            (_pseudoRandom(coord.q, coord.r, i * 2) - 0.5) * hexSize * 0.7;
        final jy =
            (_pseudoRandom(coord.q, coord.r, i * 2 + 1) - 0.5) * hexSize * 0.7;
        final puffR =
            hexSize * (0.16 + 0.05 * _pseudoRandom(coord.q, coord.r, i + 10));
        canvas.drawCircle(
          pos + Offset(jx, jy),
          puffR + pulse * hexSize * 0.02,
          Paint()
            ..color = color.withValues(alpha: 0.28 + pulse * 0.12)
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, hexSize * 0.12),
        );
      }
    }
    _drawCloudBadge(
      canvas,
      _hexToPixel(cloud.position, center),
      cloud.remainingTurns,
      color,
    );
  }

  void _drawCloudBadge(
    Canvas canvas,
    Offset pos,
    int remainingTurns,
    Color color,
  ) {
    final badgePos = pos + Offset(0, -hexSize * 0.5);
    canvas.drawCircle(
      badgePos,
      hexSize * 0.16,
      Paint()..color = Colors.black.withValues(alpha: 0.55),
    );
    canvas.drawCircle(
      badgePos,
      hexSize * 0.16,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2,
    );
    final tp = TextPainter(
      text: TextSpan(
        text: '$remainingTurns',
        style: TextStyle(
          fontSize: hexSize * 0.20,
          fontWeight: FontWeight.bold,
          color: Colors.white,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, badgePos - Offset(tp.width / 2, tp.height / 2));
  }

  /// All hexes within [cloudRadius] of [origin], clipped to the battlefield.
  List<HexCoord> _hexesInRadius(HexCoord origin, int cloudRadius) {
    final result = <HexCoord>[];
    for (int dq = -cloudRadius; dq <= cloudRadius; dq++) {
      final dr1 = max(-cloudRadius, -dq - cloudRadius);
      final dr2 = min(cloudRadius, -dq + cloudRadius);
      for (int dr = dr1; dr <= dr2; dr++) {
        final coord = HexCoord(origin.q + dq, origin.r + dr);
        if (coord.q.abs() <= radius &&
            coord.r.abs() <= radius &&
            (coord.q + coord.r).abs() <= radius) {
          result.add(coord);
        }
      }
    }
    return result;
  }

  /// Deterministic pseudo-random value in [0, 1), keyed by hex coordinate so
  /// the lava/cloud "puff" jitter is stable across repaints instead of
  /// reseeding every frame.
  double _pseudoRandom(int a, int b, int salt) {
    final h = (a * 374761393 + b * 668265263 + salt * 982451653) & 0x7fffffff;
    return (h % 1000) / 1000.0;
  }

  void _drawBarrierRing(Canvas canvas, Offset pos, Color color, double pulse) {
    final r = hexSize * 0.42 + pulse * hexSize * 0.03;

    // Outer glow — blurred halo.
    canvas.drawCircle(
      pos,
      r + hexSize * 0.05,
      Paint()
        ..color = color.withValues(alpha: 0.35 + pulse * 0.25)
        ..style = PaintingStyle.stroke
        ..strokeWidth = hexSize * 0.10
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, hexSize * 0.08),
    );
    // Crisp inner ring on top of the glow.
    canvas.drawCircle(
      pos,
      r,
      Paint()
        ..color = color.withValues(alpha: 0.55 + pulse * 0.35)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  /// Renders one [CastAnimation] at overall playback fraction [t] (0..1):
  /// fly from the held pending-cast position to the target, then burst.
  void _drawCastAnimation(
    Canvas canvas,
    Offset center,
    CastAnimation anim,
    double t,
  ) {
    final from = _hexToPixel(anim.fromHex, center);
    final to = _hexToPixel(anim.toHex, center);

    if (t < _kCastTravelEnd) {
      final p = t / _kCastTravelEnd;
      final pos = Offset.lerp(
        from,
        to,
        Curves.easeInOut.transform(p.clamp(0.0, 1.0)),
      )!;
      _drawCastOrb(canvas, pos, anim.color, radiusScale: 1.0, alpha: 1.0);
    } else {
      final p = (t - _kCastTravelEnd) / (1 - _kCastTravelEnd);
      _drawCastBurst(canvas, to, anim.color, p.clamp(0.0, 1.0));
    }
  }

  void _drawCastOrb(
    Canvas canvas,
    Offset pos,
    Color color, {
    required double radiusScale,
    required double alpha,
  }) {
    final r = hexSize * 0.22 * radiusScale;
    if (r <= 0) return;
    // Outer glow halo.
    canvas.drawCircle(
      pos,
      r * 1.8,
      Paint()
        ..color = color.withValues(alpha: 0.45 * alpha)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, hexSize * 0.18),
    );
    // Bright core.
    canvas.drawCircle(pos, r, Paint()..color = color.withValues(alpha: alpha));
    canvas.drawCircle(
      pos,
      r,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.6 * alpha)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0,
    );
  }

  void _drawCastBurst(Canvas canvas, Offset pos, Color color, double p) {
    final alpha = 1 - p;
    // Expanding ring.
    canvas.drawCircle(
      pos,
      hexSize * (0.25 + 0.55 * p),
      Paint()
        ..color = color.withValues(alpha: 0.7 * alpha)
        ..style = PaintingStyle.stroke
        ..strokeWidth = hexSize * 0.12 * (1 - p * 0.6)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, hexSize * 0.10),
    );
    // Fading core flash.
    canvas.drawCircle(
      pos,
      hexSize * 0.18 * (1 - p * 0.7),
      Paint()..color = Colors.white.withValues(alpha: 0.8 * alpha),
    );
  }

  // ── Wizard movement ────────────────────────────────────────────────────────

  /// Where every mid-walk wizard is right now, and which way they're facing.
  ///
  /// Empty when no movement is playing, which is the normal case — callers use
  /// "absent from this map" to mean "draw at the occupancy tile as usual", so
  /// this being empty restores the pre-animation behaviour exactly.
  Map<String, WizardWalkState> _walkStates(Offset center) {
    if (avatarMoveAnimations.isEmpty) return const {};
    final t = (moveAnimation?.value ?? 1.0).clamp(0.0, 1.0);
    return {
      for (final anim in avatarMoveAnimations)
        anim.playerId: wizardWalkStateAt(anim, t, center, hexSize),
    };
  }

  /// A brief spark on every tile two wizards reached for at once, peaking as
  /// they meet. Without it a speed win looks like the loser simply chose to
  /// stop one tile short — the spark is what says "they were both going there."
  void _drawCollisionSparks(Canvas canvas, Offset center) {
    final t = (moveAnimation?.value ?? 1.0).clamp(0.0, 1.0);
    // Starts a hair before impact and outlives it, so the flash is already
    // there on the frame the tokens touch.
    const start = _kMoveTravelEnd - 0.06;
    if (t < start) return;
    final p = ((t - start) / (1 - start)).clamp(0.0, 1.0);

    final tiles = <HexCoord>{
      for (final anim in avatarMoveAnimations)
        if (anim.contestedTile != null) anim.contestedTile!,
    };
    for (final tile in tiles) {
      _drawCastBurst(canvas, _hexToPixel(tile, center), Colors.white, p);
    }
  }

  /// Renders one [ConveyorChainAnimation] at overall playback fraction [t]
  /// (0..1): a token rides [ConveyorChainAnimation.path] tile-to-tile over
  /// the first [_kChainTravelEnd] of the timeline, with a fading trail over
  /// already-passed tiles, then the whole thing (orb + trail) fades out over
  /// the remainder -- otherwise, since [castAnimation] is a one-shot
  /// AnimationController that simply sits at t=1 once it finishes (no
  /// auto-reset), the orb would stay rendered at full opacity at the
  /// destination tile indefinitely instead of disappearing. (If
  /// [ConveyorChainAnimation.killed], a red burst plays near the very end
  /// instead of the usual air-colored glow.)
  void _drawConveyorChainAnimation(
    Canvas canvas,
    Offset center,
    ConveyorChainAnimation anim,
    double t,
  ) {
    if (anim.path.length < 2) return;
    final segments = anim.path.length - 1;
    final travelT = (t / _kChainTravelEnd).clamp(0.0, 1.0);
    final travel = travelT * segments;
    final idx = travel.floor().clamp(0, segments - 1);
    final frac = (travel - idx).clamp(0.0, 1.0);
    final from = _hexToPixel(anim.path[idx], center);
    final to = _hexToPixel(anim.path[idx + 1], center);
    final pos = Offset.lerp(from, to, frac)!;

    const deathColor = Color(0xFF7A1F1F);
    final airColor = _kElementColor[SpellAffinity.air]!;
    final color = anim.killed ? Color.lerp(airColor, deathColor, t)! : airColor;

    // Fades the whole visualization out after travel completes, instead of
    // leaving a solid orb sitting at the destination tile forever.
    final fade = t < _kChainTravelEnd
        ? 1.0
        : (1 - (t - _kChainTravelEnd) / (1 - _kChainTravelEnd)).clamp(0.0, 1.0);

    if (fade > 0) {
      // Fading trail over already-passed tiles.
      for (int i = 0; i <= idx; i++) {
        final age = (idx - i) / (segments + 1);
        canvas.drawCircle(
          _hexToPixel(anim.path[i], center),
          hexSize * 0.14,
          Paint()
            ..color = color.withValues(
              alpha: (0.22 * (1 - age) * fade).clamp(0.0, 0.22),
            ),
        );
      }
      _drawCastOrb(canvas, pos, color, radiusScale: 1.0, alpha: fade);
    }

    if (anim.killed && t > 0.9) {
      final p = ((t - 0.9) / 0.1).clamp(0.0, 1.0);
      _drawCastBurst(canvas, to, deathColor, p);
    }
  }

  Color _blendBarrierColors(List<SpellAffinity> affinities) {
    if (affinities.isEmpty) return Colors.white;
    if (affinities.length == 1) {
      return _kElementColor[affinities.first] ?? Colors.white;
    }
    var r = 0, g = 0, b = 0;
    for (final a in affinities) {
      final c = _kElementColor[a] ?? Colors.white;
      r += (c.r * 255.0).round().clamp(0, 255);
      g += (c.g * 255.0).round().clamp(0, 255);
      b += (c.b * 255.0).round().clamp(0, 255);
    }
    return Color.fromARGB(
      255,
      r ~/ affinities.length,
      g ~/ affinities.length,
      b ~/ affinities.length,
    );
  }

  Path _hexPath(Offset center) {
    final path = Path();
    for (int i = 0; i < 6; i++) {
      final angle = pi / 3 * i;
      final x = center.dx + hexSize * cos(angle);
      final y = center.dy + hexSize * sin(angle);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    path.close();
    return path;
  }

  // Flat-top axial → pixel (matches HexGridPainter exactly).
  Offset _hexToPixel(HexCoord coord, Offset center) =>
      hexToPixel(coord, center, hexSize);

  @override
  bool shouldRepaint(BattlefieldPainter old) =>
      old.radius != radius ||
      old.hexSize != hexSize ||
      old.localPlayerId != localPlayerId ||
      old.occupancy.length != occupancy.length ||
      old.highlightHex != highlightHex ||
      old.scryRevealHex != scryRevealHex ||
      old.movePath.length != movePath.length ||
      old.spellRangeRadius != spellRangeRadius ||
      old.casterPos != casterPos ||
      old.minions.length != minions.length ||
      old.barrierRings.length != barrierRings.length ||
      old.castAnimations.length != castAnimations.length ||
      old.tileEffects.length != tileEffects.length ||
      !_cloudsMatch(old.clouds, clouds) ||
      old.directionPickHexes.length != directionPickHexes.length ||
      old.meleePickHexes.length != meleePickHexes.length ||
      old.freeMovePickHexes.length != freeMovePickHexes.length ||
      old.conveyorChainAnimations.length != conveyorChainAnimations.length ||
      old.hiddenCloudIds.length != hiddenCloudIds.length ||
      old.hiddenTileHexes.length != hiddenTileHexes.length ||
      old.hiddenMinionIds.length != hiddenMinionIds.length ||
      !identical(old.resolutionBaseline, resolutionBaseline) ||
      old.terrainBeneath != terrainBeneath ||
      old.avatarMoveAnimations.length != avatarMoveAnimations.length ||
      !identical(old.avatarAtlas, avatarAtlas) ||
      !identical(old.avatarAssignment, avatarAssignment) ||
      !identical(old.effectBloom, effectBloom);

  /// Length-only comparison misses [CloudObject.position] mutating in place
  /// (e.g. MobileCloud drifting toward its target) — same id/count, new tile.
  /// Compare id+position pairwise so a moved cloud actually triggers a repaint.
  static bool _cloudsMatch(List<CloudObject> a, List<CloudObject> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id || a[i].position != b[i].position) return false;
    }
    return true;
  }
}
