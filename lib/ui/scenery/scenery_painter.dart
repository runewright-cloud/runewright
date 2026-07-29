// SPDX-License-Identifier: GPL-3.0-or-later
//
// scenery_painter.dart — draws a [SceneryMap] underneath the battlefield.
//
// PURELY COSMETIC (see scenery_tile.dart). This painter sits *behind*
// BattlefieldPainter and shares its geometry exactly — same flat-top axial
// grid, same hexSize, same centre — so every playable hex sits squarely on one
// terrain tile. Only sits under the PLAYABLE hexes (radius <= playRadius) —
// terrain beyond the battlefield's edge is deliberately not drawn, since a
// visibly walkable-looking hex a player can't actually move to reads as a bug,
// not a frame (2026-07-29).
//
// ── Geometry ─────────────────────────────────────────────────────────────────
//
// The art is authored on a hex that is 128 wide by 128 tall, i.e. stretched
// vertically by 2/sqrt(3) relative to a regular hex. Rather than fight that per
// tile, the whole draw runs through one canvas transform from "atlas space"
// (where a hex is 128x128 and steps by 96 / 128 / 64) into screen space:
//
//     sx = 2 * hexSize / 128            sy = sqrt(3) * hexSize / 128
//
// which reproduces BattlefieldPainter's hexToPixel exactly:
//
//     x = sx * 96q                  = 1.5 * hexSize * q                    ✓
//     y = sy * (64q + 128r)         = hexSize * (sqrt(3)/2 q + sqrt(3) r)  ✓
//
// The 0.866 vertical squash is invisible on a texture and costs one transform
// instead of 300 per-tile scale computations.
//
// Tiles carry a 16px downward extrusion that must overlap the tile behind them,
// so they are drawn back-to-front in [SceneryMap.paintOrder].

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../../battle/models/hex_battlefield.dart' show hexDistance;
import '../../engine/hex_grid.dart' show HexCoord;
import '../battlefield_painter.dart' show pixelToHex;
import 'scenery_map.dart';
import 'scenery_tile.dart';

// ── Readability tuning ───────────────────────────────────────────────────────
//
// Terrain is scenery, not the subject: it must never compete with tokens,
// range rings, cast orbs or path highlights.

// Also picks up BattlefieldPainter's checkerboard wash and tile rim on top,
// so it is dimmed much less here than the numbers alone suggest — tuned
// against the composite, not against scenery on its own.
const double _kInnerBrightness = 0.82;
const double _kInnerSaturation = 0.96;

// ── Atlas loading ────────────────────────────────────────────────────────────

/// Loads and caches the shipped terrain atlas.
///
/// One decode per process: the atlas is a single 768x432 RGBA texture, and
/// every tile is a source rect into it, so a whole backdrop is one texture bind.
class SceneryAtlas {
  SceneryAtlas._();

  static const String assetPath =
      'assets/art_pack/terrain/hex_terrain_atlas.png';

  static ui.Image? _image;
  static Future<ui.Image>? _pending;

  /// The decoded atlas, or null if [load] has not completed yet. Painters
  /// treat null as "draw nothing this frame".
  static ui.Image? get imageOrNull => _image;

  static Future<ui.Image> load() {
    final cached = _image;
    if (cached != null) return Future.value(cached);
    return _pending ??= _decode();
  }

  static Future<ui.Image> _decode() async {
    final data = await rootBundle.load(assetPath);
    final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
    final frame = await codec.getNextFrame();
    _image = frame.image;
    _pending = null;
    return frame.image;
  }

  /// Test hook — drops the cached decode so a fake atlas can be installed.
  @visibleForTesting
  static void resetForTest() {
    _image = null;
    _pending = null;
  }
}

// ── Sizing helper ────────────────────────────────────────────────────────────

/// Smallest map radius whose hex disc covers a [panel] of the given size at
/// [hexSize], plus a margin so the extrusions along the edge have something to
/// sit on.
///
/// Computed from the panel's own corners via [pixelToHex] rather than a
/// closed-form bound, so it stays correct if the grid geometry ever changes.
int sceneryRadiusForPanel(Size panel, double hexSize, {int margin = 2}) {
  if (hexSize <= 0 || panel.isEmpty) return margin;
  final centre = Offset(panel.width / 2, panel.height / 2);
  const origin = HexCoord(0, 0);
  var needed = 0;
  for (final corner in [
    Offset.zero,
    Offset(panel.width, 0),
    Offset(0, panel.height),
    Offset(panel.width, panel.height),
  ]) {
    needed = math.max(
      needed,
      hexDistance(origin, pixelToHex(corner, centre, hexSize)),
    );
  }
  return needed + margin;
}

// ── Painter ──────────────────────────────────────────────────────────────────

/// Draws [map] as the battle backdrop.
class SceneryBackdropPainter extends CustomPainter {
  SceneryBackdropPainter({
    required this.map,
    required this.atlas,
    required this.hexSize,
    required this.playRadius,
    this.vignetteColor = const Color(0xFF1A1008),
  });

  final SceneryMap map;

  /// Decoded [SceneryAtlas] image. Null until the asset finishes loading, in
  /// which case nothing is drawn (the scaffold colour shows through).
  final ui.Image? atlas;

  /// Must equal the BattlefieldPainter's hexSize for the grids to coincide.
  final double hexSize;

  /// Battlefield radius. Tiles beyond it are not drawn at all (see this
  /// file's header comment) — only the playable area gets a terrain
  /// backdrop.
  final int playRadius;

  /// Colour the backdrop fades into at the panel edges, beyond [playRadius]
  /// — normally the scaffold's own colour, so there's no visible seam
  /// between "playable ground" and "everything past the battlefield edge."
  final Color vignetteColor;

  @override
  void paint(Canvas canvas, Size size) {
    final image = atlas;
    if (image == null || hexSize <= 0) return;

    final centre = Offset(size.width / 2, size.height / 2);
    final sx = 2 * hexSize / atlasCellWidth;
    // Divisor is the *face* height, not the cell height: the extrusion below
    // the face is overhang, not part of the hex's footprint. Numerically equal
    // to atlasCellWidth today, but they are different quantities.
    final sy = math.sqrt(3) * hexSize / atlasFaceHeight;

    // Visible region in atlas space, so off-panel tiles are skipped entirely.
    final visible = Rect.fromLTRB(
      (0 - centre.dx) / sx,
      (0 - centre.dy) / sy,
      (size.width - centre.dx) / sx,
      (size.height - centre.dy) / sy,
    ).inflate(atlasCellHeight);

    final inner = Paint()
      ..isAntiAlias = true
      ..filterQuality = FilterQuality.medium
      ..colorFilter = _toneFilter(_kInnerBrightness, _kInnerSaturation);

    canvas.save();
    canvas.clipRect(Offset.zero & size);
    canvas.translate(centre.dx, centre.dy);
    canvas.scale(sx, sy);

    const origin = HexCoord(0, 0);
    for (final hex in map.paintOrder) {
      if (hexDistance(origin, hex) > playRadius) continue;
      final tile = map.tiles[hex];
      if (tile == null) continue;

      final ax = atlasStepX * hex.q;
      final ay = atlasColumnDrop * hex.q + atlasStepY * hex.r;
      final dst = Rect.fromLTWH(
        ax - atlasCellWidth / 2,
        ay - atlasFaceHeight / 2,
        atlasCellWidth,
        atlasCellHeight,
      );
      if (!dst.overlaps(visible)) continue;

      final src = Rect.fromLTWH(
        tile.atlasCol * atlasCellWidth,
        tile.atlasRow * atlasCellHeight,
        atlasCellWidth,
        atlasCellHeight,
      );

      canvas.drawImageRect(image, src, dst, inner);
    }

    canvas.restore();

    // Fade the outer reaches into the scaffold colour so the backdrop has no
    // visible rectangular crop.
    final panel = Offset.zero & size;
    canvas.drawRect(
      panel,
      Paint()
        ..shader = RadialGradient(
          center: Alignment.center,
          radius: 0.78,
          colors: [
            vignetteColor.withValues(alpha: 0),
            vignetteColor.withValues(alpha: 0),
            vignetteColor,
          ],
          stops: const [0.0, 0.52, 1.0],
        ).createShader(panel),
    );
  }

  @override
  bool shouldRepaint(covariant SceneryBackdropPainter old) =>
      !identical(old.map, map) ||
      old.atlas != atlas ||
      old.hexSize != hexSize ||
      old.playRadius != playRadius ||
      old.vignetteColor != vignetteColor;

  /// Combined desaturate-and-darken, applied to RGB only so the tiles' own
  /// antialiased alpha edges survive untouched.
  static ColorFilter _toneFilter(double brightness, double saturation) {
    const lr = 0.2126, lg = 0.7152, lb = 0.0722;
    final s = saturation;
    final b = brightness;
    double m(double v) => v * b;
    return ColorFilter.matrix(<double>[
      m((1 - s) * lr + s),
      m((1 - s) * lg),
      m((1 - s) * lb),
      0,
      0,
      m((1 - s) * lr),
      m((1 - s) * lg + s),
      m((1 - s) * lb),
      0,
      0,
      m((1 - s) * lr),
      m((1 - s) * lg),
      m((1 - s) * lb + s),
      0,
      0,
      0,
      0,
      0,
      1,
      0,
    ]);
  }
}
