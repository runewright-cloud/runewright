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
// glows in place, flies to the target, then bursts.
const double _kCastAppearEnd = 0.18;
const double _kCastTravelEnd = 0.72;

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

    // Pass 3 — minion tokens
    for (final m in minions) {
      if (!m.isAlive) continue;
      final friendly = m.teamId == localTeamId;
      _drawMinionToken(canvas, _hexToPixel(m.position, center), m, friendly);
    }

    // Pass 4 — wizard tokens (on top of minions)
    for (final entry in occupancy.entries) {
      final isLocal = entry.key == localPlayerId;
      _drawToken(canvas, _hexToPixel(entry.value, center), isLocal, entry.key);
    }

    // Pass 5 — barrier rings (pulsing glow over all shielded entities)
    final pulse = pulseAnimation?.value ?? 0.5;
    for (final entry in barrierRings.entries) {
      _drawBarrierRing(canvas, _hexToPixel(entry.key, center),
          _blendBarrierColors(entry.value), pulse);
    }

    // Pass 6 — cast animations (glow → fly → burst), on top of everything.
    if (castAnimations.isNotEmpty) {
      final t = (castAnimation?.value ?? 1.0).clamp(0.0, 1.0);
      for (final anim in castAnimations) {
        _drawCastAnimation(canvas, center, anim, t);
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

  void _drawMinionToken(Canvas canvas, Offset pos, Minion m, bool friendly) {
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

    // 'S' = Spirit, 'H' = Hound; tinted by elemental affinity.
    final label = m is SpiritMinion ? 'S' : 'H';
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
  /// glow in at the caster, fly to the target, then burst.
  void _drawCastAnimation(Canvas canvas, Offset center, CastAnimation anim, double t) {
    final from = _hexToPixel(anim.fromHex, center);
    final to   = _hexToPixel(anim.toHex, center);

    if (t < _kCastAppearEnd) {
      final p = (t / _kCastAppearEnd).clamp(0.0, 1.0);
      _drawCastOrb(canvas, from, anim.color, radiusScale: p, alpha: p);
    } else if (t < _kCastTravelEnd) {
      final p = (t - _kCastAppearEnd) / (_kCastTravelEnd - _kCastAppearEnd);
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
      old.movePath.length != movePath.length ||
      old.spellRangeRadius != spellRangeRadius ||
      old.casterPos != casterPos ||
      old.minions.length != minions.length ||
      old.barrierRings.length != barrierRings.length ||
      old.castAnimations.length != castAnimations.length;
}
