// SPDX-License-Identifier: GPL-3.0-or-later
//
// foil_sheen.dart — the animated "foil" luster laid over a spell card that
// carries wild magic.
//
// Trading cards have signalled rarity with foil since the nineties, and wild
// magic is the closest thing this game has to a chase card: a fixed property
// of the rune (WILD_MAGIC_PLAN.md §2.1), so a card either shimmers forever or
// never does. That makes the luster an honest index of the card, not a
// decoration — a player flicking through their library should be able to spot
// the wild ones at a glance, without reading a word.
//
// Two layers, deliberately at different angles so they beat against each other
// rather than sliding as one sheet:
//
//   • an iridescent wash — a repeating hue cycle drifting along the card's
//     top-left → bottom-right diagonal, weighted toward gold so it reads as
//     illuminated leaf rather than an oil slick, and
//   • two specular streaks — narrow bright bands sweeping the other diagonal,
//     the gloss you get tilting a real foil card under a light.
//
// Both are plain alpha compositing (no exotic blend modes): the sheen sits over
// ink-dark title bars and pale parchment in the same card, and `srcOver` is the
// one compositing path that behaves predictably over both. Blend modes like
// `overlay`/`plus` need a saveLayer against the backdrop to be well-defined,
// which is a compositing cost per card per frame for a subtler result.

import 'dart:math' as math;

import 'package:flutter/material.dart';

/// A purely decorative animated foil luster, sized to fill its parent.
///
/// Stack it over the thing it lustres; it hit-tests as nothing. Callers are
/// responsible for clipping it to the card's rounded corners.
///
/// **Mount this only for cards that actually carry wild magic.** It runs a
/// repeating animation for as long as it is on screen, and ~97% of spells
/// fire no wild magic at all — so on a normal library page only a card or two
/// is ticking, which is the whole reason a per-widget controller is affordable
/// here.
class FoilSheen extends StatefulWidget {
  const FoilSheen({super.key, this.intensity = 1.0});

  /// Scales both layers' opacity. Small thumbnails carry the sheen over much
  /// less area, so callers there push this above 1 to keep it legible.
  final double intensity;

  @override
  State<FoilSheen> createState() => _FoilSheenState();
}

class _FoilSheenState extends State<FoilSheen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _drift;

  @override
  void initState() {
    super.initState();
    // Slow enough to read as a sheen catching the light rather than as a
    // "loading" shimmer, which is what a sub-second sweep would look like.
    _drift = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 5200),
    )..repeat();
  }

  @override
  void dispose() {
    _drift.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: AnimatedBuilder(
      animation: _drift,
      builder: (_, _) => CustomPaint(
        size: Size.infinite,
        painter: FoilSheenPainter(
          phase: _drift.value,
          intensity: widget.intensity,
        ),
      ),
    ),
  );
}

/// Paints one frame of [FoilSheen]. Public so a still frame can be painted
/// without a ticker (and so widget tests can pin the look at a given [phase]).
class FoilSheenPainter extends CustomPainter {
  const FoilSheenPainter({required this.phase, this.intensity = 1.0});

  /// 0 → 1, wrapping. Both layers are built to loop seamlessly across it.
  final double phase;

  final double intensity;

  /// The hue cycle of the wash: first and last entries are identical so the
  /// repeated tiling has no seam, and gold gets both the widest span and the
  /// highest alpha — this is a manuscript, not a hologram.
  ///
  /// Every stop is a *colour*, never a transparent black. `Color.lerp`
  /// interpolates un-premultiplied, so a stop of `0x00000000` drags the whole
  /// ramp toward grey on its way to transparent and lays a dirty cast over the
  /// parchment. Fading between low-alpha hues instead keeps the wash in-hue
  /// the whole way round.
  static const List<Color> _hues = [
    Color(0x30FFD97A), // gold leaf
    Color(0x20FFB0D8), // rose
    Color(0x28A8E6FF), // cold sky
    Color(0x1CC9FFB8), // verdigris
    Color(0x30FFD97A), // gold leaf again — closes the loop
  ];

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final rect = Offset.zero & size;

    _paintWash(canvas, size, rect);
    // Two streaks half a cycle apart, so the card is never long without one.
    _paintStreak(canvas, size, rect, phase);
    _paintStreak(canvas, size, rect, (phase + 0.5) % 1.0);
  }

  /// The drifting hue cycle.
  ///
  /// The gradient is defined over a half-size rect and tiled, giving two hue
  /// bands across the card; translating that rect by exactly its own extent
  /// over one full [phase] advances the tiling by exactly one period, so the
  /// loop closes invisibly.
  void _paintWash(Canvas canvas, Size size, Rect rect) {
    final period = Size(size.width / 2, size.height / 2);
    // Scale into the colours themselves rather than Paint.color: dart:ui
    // ignores a paint's colour once a shader is set.
    final colors = [
      for (final c in _hues)
        c.withValues(alpha: (c.a * intensity).clamp(0.0, 1.0)),
    ];
    final shader = LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: colors,
      tileMode: TileMode.repeated,
    ).createShader(
      Rect.fromLTWH(
        -period.width * phase,
        -period.height * phase,
        period.width,
        period.height,
      ),
    );
    canvas.drawRect(rect, Paint()..shader = shader);
  }

  /// One narrow gloss band crossing the *other* diagonal.
  ///
  /// [at] runs 0 → 1; the band's centre travels from just off one corner to
  /// just off the other, so it spends part of every cycle fully off the card —
  /// a highlight that never leaves doesn't read as a highlight.
  void _paintStreak(Canvas canvas, Size size, Rect rect, double at) {
    const halfWidth = 0.065;
    final centre = -0.25 + 1.5 * at;
    final lo = centre - halfWidth;
    final hi = centre + halfWidth;
    // Fully off-card in either direction: nothing to draw, and clamped stops
    // outside [0, 1] would smear the band's edge colour across the whole card.
    if (hi <= 0.0 || lo >= 1.0) return;

    final peak = (0.24 * intensity).clamp(0.0, 1.0);
    // Fade the band in and out as it enters and leaves, so it slides on rather
    // than switching on at the edge.
    final visible = math.min(1.0, math.min(hi, 1.0) - math.max(lo, 0.0)) /
        (2 * halfWidth);
    final alpha = peak * visible.clamp(0.0, 1.0);
    if (alpha <= 0.001) return;

    final stops = <double>[
      0.0,
      lo.clamp(0.0, 1.0),
      centre.clamp(0.0, 1.0),
      hi.clamp(0.0, 1.0),
      1.0,
    ];
    // clamp() can collapse neighbouring stops; LinearGradient requires them
    // non-decreasing, which the clamp preserves, but a zero-width band paints
    // nothing useful.
    if (stops[3] - stops[1] <= 0.0) return;

    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topRight,
          end: Alignment.bottomLeft,
          colors: [
            const Color(0x00FFFFFF),
            const Color(0x00FFFFFF),
            Color.fromRGBO(255, 252, 240, alpha),
            const Color(0x00FFFFFF),
            const Color(0x00FFFFFF),
          ],
          stops: stops,
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(covariant FoilSheenPainter old) =>
      old.phase != phase || old.intensity != intensity;
}
