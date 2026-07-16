// SPDX-License-Identifier: GPL-3.0-or-later
//
// battlefield_painter.dart — CustomPainter for the in-battle hex grid.
//
// Draws a plain radius-N battlefield (no CA elements, no border zones).
// Player positions are shown as circular tokens: gold star for the local
// player, rubric-red initials for opponents.
//
// Coordinate system and hex orientation are identical to HexGridPainter
// (flat-top axial, same q/r → pixel formula) so cells align if overlaid.

import 'dart:math';

import 'package:flutter/material.dart';

import '../battle/models/effect_kind.dart' show SpellAffinity;
import '../battle/models/hex_battlefield.dart' show hexDistance;
import '../battle/models/minion.dart';
import '../battle/models/terrain.dart';
import '../engine/hex_grid.dart';

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
/// spell's elemental affinity. Purely cosmetic; built by the UI layer from
/// [SpellCastEvent] (see turn_loop.dart), which is the gameplay source of truth.
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

/// A spell cast that has been committed but not yet resolved: a glowing orb
/// held at [origin], pulsing, coloured by elemental affinity. Covers both a
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
  }) : super(repaint: Listenable.merge([pulseAnimation, castAnimation]));

  final int radius;
  final double hexSize;

  /// playerId → current position. Players absent from this map are off-field.
  final Map<String, HexCoord> occupancy;

  /// The local player's id — their token is drawn in gold with a star glyph.
  final String? localPlayerId;

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

  static const _kScryReveal = Color(0xFF9B5FC0); // violet — third-eye glimpse
  static const _kMeleePick  = Color(0xFF7A1F1F); // rubric red — melee prompt

  static const _kTileLight  = Color(0xFFD5CCB2); // stone tile fill
  static const _kTileDark   = Color(0xFFC2B89A); // alternate tile (checkerboard)
  static const _kEdge       = Color(0xFF4A3018); // tile border
  static const _kLocalToken = Color(0xFFB8860B); // illumination gold
  static const _kFoeToken   = Color(0xFF7A1F1F); // rubric red

  // Elemental colors — minion label tint, barrier ring glow, and the cast
  // animation orb. [colorForAffinity] is the public accessor for callers
  // (e.g. battle_screen.dart) building a [CastAnimation].
  static const Map<SpellAffinity, Color> _kElementColor = {
    SpellAffinity.fire:  Color(0xFFE05020),
    SpellAffinity.earth: Color(0xFF8B6033),
    SpellAffinity.water: Color(0xFF2090E0),
    SpellAffinity.air:   Color(0xFFD8C840),
  };

  /// The cast-animation orb color for a spell's primary elemental affinity.
  static Color colorForAffinity(SpellAffinity affinity) =>
      _kElementColor[affinity] ?? Colors.white;

  // Terrain/cloud color follows the elemental flavor that creates it (same
  // palette as minion labels / barrier rings / cast orbs).
  Color _colorForTileEffect(TileEffect effect) => switch (effect) {
        FloorIsLava() => _kElementColor[SpellAffinity.fire]!,
        ImpassableTile() => _kElementColor[SpellAffinity.earth]!,
        SlowTile() => _kElementColor[SpellAffinity.water]!,
        ConveyorTile() => _kElementColor[SpellAffinity.air]!,
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
    for (final entry in tileEffects.entries) {
      _drawTileEffect(canvas, entry.key, center, entry.value, pulse);
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

    // Pass 3 — minion tokens (Big/EEEE creatures draw one token per
    // occupied tile, label on the anchor tile only).
    for (final m in minions) {
      if (!m.isAlive) continue;
      final friendly = m.teamId == localTeamId;
      for (final tile in m.occupiedTiles) {
        _drawMinionToken(canvas, _hexToPixel(tile, center), m, friendly,
            showLabel: tile == m.position);
      }
    }

    // Pass 4 — wizard tokens (on top of minions)
    for (final entry in occupancy.entries) {
      final isLocal = entry.key == localPlayerId;
      _drawToken(canvas, _hexToPixel(entry.value, center), isLocal, entry.key);
    }

    // Pass 4.5 — clouds (over tokens so entities read through the haze;
    // under barrier rings/cast animations so those stay fully legible).
    for (final cloud in clouds) {
      _drawCloud(canvas, center, cloud, pulse);
    }

    // Pass 5 — barrier rings (pulsing glow over all shielded entities)
    for (final entry in barrierRings.entries) {
      _drawBarrierRing(canvas, _hexToPixel(entry.key, center),
          _blendBarrierColors(entry.value), pulse);
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
      _drawCastOrb(canvas, _hexToPixel(orb.origin, center), orb.color,
          radiusScale: 0.85 + pulse * 0.15, alpha: 0.7 + pulse * 0.3);
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

  void _drawTile(Canvas canvas, HexCoord coord, Offset center) {
    final pos  = _hexToPixel(coord, center);
    final path = _hexPath(pos);

    // Subtle checkerboard tint so tiles are distinguishable.
    final light = (coord.q + coord.r + coord.q * coord.r).isEven;
    canvas.drawPath(path, Paint()..color = light ? _kTileLight : _kTileDark);
    canvas.drawPath(
      path,
      Paint()
        ..color = _kEdge
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

  void _drawHighlight(Canvas canvas, HexCoord coord, Offset center, Color color) {
    final pos  = _hexToPixel(coord, center);
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

  void _drawToken(Canvas canvas, Offset pos, bool isLocal, String playerId) {
    final r     = hexSize * 0.36;
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
    final label = isLocal ? '★' : (playerId.isNotEmpty ? playerId[0].toUpperCase() : '?');
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

  void _drawMinionToken(Canvas canvas, Offset pos, Minion m, bool friendly,
      {bool showLabel = true}) {
    final r          = hexSize * 0.24;
    final fillColor  = friendly ? _kLocalToken : _kFoeToken;
    final labelColor = _kElementColor[m.affinity] ?? Colors.white;

    canvas.drawCircle(
      pos + const Offset(0, 1.2),
      r,
      Paint()..color = Colors.black.withValues(alpha: 0.28),
    );
    canvas.drawCircle(pos, r, Paint()..color = fillColor.withValues(alpha: 0.85));
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
      Canvas canvas, HexCoord coord, Offset center, TileEffect effect, double pulse) {
    final pos   = _hexToPixel(coord, center);
    final path  = _hexPath(pos);
    final color = _colorForTileEffect(effect);

    // Dark base first so the colored fill reads as saturated rather than
    // washing out against the off-white/tan tile fill underneath it.
    canvas.drawPath(path, Paint()..color = Colors.black.withValues(alpha: 0.14));
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
      final jy = (_pseudoRandom(coord.q, coord.r, i * 2 + 1) - 0.5) * hexSize * 1.1;
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

  void _drawCrosshatch(Canvas canvas, Offset pos, Color color) {
    final paint = Paint()
      ..color = color.withValues(alpha: 0.65)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    final s = hexSize * 0.9;
    for (double d = -s; d <= s; d += hexSize * 0.35) {
      canvas.drawLine(
          Offset(pos.dx + d - s, pos.dy - s), Offset(pos.dx + d + s, pos.dy + s), paint);
      canvas.drawLine(
          Offset(pos.dx + d - s, pos.dy + s), Offset(pos.dx + d + s, pos.dy - s), paint);
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
      path.quadraticBezierTo(pos.dx - hexSize * 0.2, y - hexSize * 0.15, pos.dx, y);
      path.quadraticBezierTo(pos.dx + hexSize * 0.2, y + hexSize * 0.15, pos.dx + hexSize * 0.6, y);
      canvas.drawPath(path, paint);
    }
  }

  /// Wind gust: one static center chevron for unambiguous direction
  /// (screenshot-safe) plus 3 animated tapered streaks flowing from the
  /// upstream to downstream edge, looping via [pulse] (the free-running
  /// _pulseController already used for barrier rings/cloud puffs).
  void _drawConveyorArrows(
      Canvas canvas, Offset pos, Color color, HexCoord direction, double pulse) {
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
      canvas.drawArc(Rect.fromCircle(center: pos, radius: r), a0, (pi / dashCount) * 0.6, false, paint);
    }
    final tp = TextPainter(
      text: TextSpan(
        text: '?',
        style: TextStyle(fontSize: hexSize * 0.32, fontWeight: FontWeight.bold, color: color),
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

  void _drawCloud(Canvas canvas, Offset center, CloudObject cloud, double pulse) {
    final color = _colorForCloudKind(cloud.kind);
    for (final coord in _hexesInRadius(cloud.position, cloud.radius)) {
      final pos  = _hexToPixel(coord, center);
      final path = _hexPath(pos);
      // Dark base first so the colored fill reads as saturated rather than
      // washing out against the off-white/tan tile fill underneath it.
      canvas.drawPath(path, Paint()..color = Colors.black.withValues(alpha: 0.10));
      canvas.drawPath(path, Paint()..color = color.withValues(alpha: 0.34 + pulse * 0.10));
      canvas.drawPath(
        path,
        Paint()
          ..color = color.withValues(alpha: 0.6)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.8,
      );

      for (int i = 0; i < 3; i++) {
        final jx = (_pseudoRandom(coord.q, coord.r, i * 2) - 0.5) * hexSize * 0.7;
        final jy = (_pseudoRandom(coord.q, coord.r, i * 2 + 1) - 0.5) * hexSize * 0.7;
        final puffR = hexSize * (0.16 + 0.05 * _pseudoRandom(coord.q, coord.r, i + 10));
        canvas.drawCircle(
          pos + Offset(jx, jy),
          puffR + pulse * hexSize * 0.02,
          Paint()
            ..color = color.withValues(alpha: 0.28 + pulse * 0.12)
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, hexSize * 0.12),
        );
      }
    }
    _drawCloudBadge(canvas, _hexToPixel(cloud.position, center), cloud.remainingTurns, color);
  }

  void _drawCloudBadge(Canvas canvas, Offset pos, int remainingTurns, Color color) {
    final badgePos = pos + Offset(0, -hexSize * 0.5);
    canvas.drawCircle(badgePos, hexSize * 0.16, Paint()..color = Colors.black.withValues(alpha: 0.55));
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
        style: TextStyle(fontSize: hexSize * 0.20, fontWeight: FontWeight.bold, color: Colors.white),
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
  void _drawCastAnimation(Canvas canvas, Offset center, CastAnimation anim, double t) {
    final from = _hexToPixel(anim.fromHex, center);
    final to   = _hexToPixel(anim.toHex, center);

    if (t < _kCastTravelEnd) {
      final p = t / _kCastTravelEnd;
      final pos = Offset.lerp(from, to, Curves.easeInOut.transform(p.clamp(0.0, 1.0)))!;
      _drawCastOrb(canvas, pos, anim.color, radiusScale: 1.0, alpha: 1.0);
    } else {
      final p = (t - _kCastTravelEnd) / (1 - _kCastTravelEnd);
      _drawCastBurst(canvas, to, anim.color, p.clamp(0.0, 1.0));
    }
  }

  void _drawCastOrb(Canvas canvas, Offset pos, Color color,
      {required double radiusScale, required double alpha}) {
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
      Canvas canvas, Offset center, ConveyorChainAnimation anim, double t) {
    if (anim.path.length < 2) return;
    final segments = anim.path.length - 1;
    final travelT = (t / _kChainTravelEnd).clamp(0.0, 1.0);
    final travel  = travelT * segments;
    final idx     = travel.floor().clamp(0, segments - 1);
    final frac    = (travel - idx).clamp(0.0, 1.0);
    final from = _hexToPixel(anim.path[idx], center);
    final to   = _hexToPixel(anim.path[idx + 1], center);
    final pos  = Offset.lerp(from, to, frac)!;

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
          Paint()..color = color.withValues(alpha: (0.22 * (1 - age) * fade).clamp(0.0, 0.22)),
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
        255, r ~/ affinities.length, g ~/ affinities.length, b ~/ affinities.length);
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
  Offset _hexToPixel(HexCoord coord, Offset center) => Offset(
        center.dx + hexSize * (3 / 2 * coord.q),
        center.dy + hexSize * (sqrt(3) / 2 * coord.q + sqrt(3) * coord.r),
      );

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
      old.clouds.length != clouds.length ||
      old.directionPickHexes.length != directionPickHexes.length ||
      old.meleePickHexes.length != meleePickHexes.length ||
      old.conveyorChainAnimations.length != conveyorChainAnimations.length;
}
