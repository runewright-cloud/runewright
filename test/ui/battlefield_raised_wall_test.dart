// SPDX-License-Identifier: GPL-3.0-or-later
//
// battlefield_raised_wall_test.dart — impassable tiles are drawn as rock
// standing proud of the ground plane, and re-occlude whoever stands behind them.
//
// Like battlefield_terrain_beneath_test.dart this asserts pixels, for the same
// reason: the requirement is inherently visual and every failure mode here is
// silent. A wall that renders flat, a wall that never crumbles, and an
// occlusion pass that never fires all leave the rest of the suite green.
//
// The wall height is load-bearing, not decorative — see BattlefieldPainter's
// _kWallMaxLayers. A wall stands exactly one hex row tall so that an entity one
// row behind is actually reached; drop a layer and the occlusion pass becomes
// dead code. 'a wall stands one full hex row tall' is the test that pins that.

import 'dart:typed_data' show Uint8List;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/battle/models/terrain.dart';
import 'package:rune_duel/engine/hex_grid.dart' show HexCoord;
import 'package:rune_duel/ui/battlefield_painter.dart';

const Size _kSize = Size(400, 400);
const double _kHexSize = 24;

/// The colour the fake atlas paints into the chalk cell. Nothing else on the
/// board is magenta, so "is this pixel wall?" is unambiguous.
const Color _kWallColor = Color(0xFFFF00FF);

/// A stand-in terrain atlas: the right dimensions, with the wall terrain's cell
/// (SceneryTile.wallTile == chalk, atlasIndex 6 → col 0, row 1) filled magenta
/// and everything else a flat dark colour.
Future<ui.Image> _fakeAtlas() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder, const Rect.fromLTWH(0, 0, 768, 432));
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, 768, 432),
    Paint()..color = const Color(0xFF203040),
  );
  canvas.drawRect(
    const Rect.fromLTWH(0, 144, 128, 144),
    Paint()..color = _kWallColor,
  );
  return recorder.endRecording().toImage(768, 432);
}

/// One rendered board, as raw RGBA.
class _Render {
  _Render(this.bytes, this.centre);

  final Uint8List bytes;
  final Offset centre;

  Color at(Offset p) {
    final o = ((p.dy.round() * _kSize.width.toInt()) + p.dx.round()) * 4;
    return Color.fromARGB(bytes[o + 3], bytes[o], bytes[o + 1], bytes[o + 2]);
  }

  /// Whether the pixel reads as wall rock. Tolerant of the show-through alpha
  /// blend, which keeps magenta dominant but darkens it.
  bool isWall(Offset p) {
    final c = at(p);
    return c.r > 0.45 && c.b > 0.45 && c.g < 0.35;
  }

  Offset hex(HexCoord h) => hexToPixel(h, centre, _kHexSize);

  /// Highest wall pixel in the column through [h], as pixels above its centre.
  /// Zero when the column holds no wall at all.
  double wallRiseAbove(HexCoord h) {
    final p = hex(h);
    final x = p.dx.round();
    for (var y = 0; y < _kSize.height.toInt(); y++) {
      if (isWall(Offset(x.toDouble(), y.toDouble()))) return p.dy - y;
    }
    return 0;
  }
}

Future<_Render> _render({
  Map<HexCoord, TileEffect> tileEffects = const {},
  Map<HexCoord, int> terrainHp = const {},
  Map<String, HexCoord> occupancy = const {},
  required bool withAtlas,
}) async {
  final atlas = withAtlas ? await _fakeAtlas() : null;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder, Offset.zero & _kSize);
  canvas.drawRect(Offset.zero & _kSize, Paint()..color = const Color(0xFF000000));

  BattlefieldPainter(
    radius: 4,
    hexSize: _kHexSize,
    occupancy: occupancy,
    tileEffects: tileEffects,
    terrainHp: terrainHp,
    sceneryAtlas: atlas,
  ).paint(canvas, _kSize);

  final image = await recorder.endRecording().toImage(
    _kSize.width.toInt(),
    _kSize.height.toInt(),
  );
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  return _Render(
    data!.buffer.asUint8List(),
    Offset(_kSize.width / 2, _kSize.height / 2),
  );
}

void main() {
  const wall = HexCoord(0, 0);
  // One row up-screen of the wall: q + 2r is smaller, so it is *behind*.
  const behind = HexCoord(0, -1);
  // Two rows up-screen — behind, but out of the wall's reach.
  const farBehind = HexCoord(0, -2);

  /// One hex row, in pixels. The wall's design height.
  final rowStep = 1.7320508 * _kHexSize;

  testWidgets('an impassable tile is drawn as rock raised above its own tile', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final r = await _render(
        tileEffects: {wall: const ImpassableTile()},
        withAtlas: true,
      );
      // The flat hex face reaches sqrt(3)/2 ≈ 0.866 × hexSize above centre.
      // Anything painted above that line can only be the raise.
      final aboveTheFace = r.hex(wall).dy - 0.866 * _kHexSize - 4;
      expect(
        r.isWall(Offset(r.hex(wall).dx, aboveTheFace)),
        isTrue,
        reason: 'the wall is flat — nothing is drawn above its hex face',
      );
    });
  });

  testWidgets('a wall stands one full hex row tall', (tester) async {
    await tester.runAsync(() async {
      final r = await _render(
        tileEffects: {wall: const ImpassableTile()},
        withAtlas: true,
      );
      // This is the number the occlusion pass depends on: a wall shorter than a
      // row can never reach the entity behind it. Tolerance is one layer's
      // worth of rise (0.2165 × hexSize ≈ 5px) either way.
      expect(
        r.wallRiseAbove(wall),
        closeTo(rowStep, 0.25 * _kHexSize),
        reason: 'wall height drifted from one hex row — occlusion will stop '
            'firing (see _kWallMaxLayers)',
      );
    });
  });

  testWidgets('a damaged wall visibly crumbles', (tester) async {
    await tester.runAsync(() async {
      final full = await _render(
        tileEffects: {wall: const ImpassableTile()},
        terrainHp: {wall: 4},
        withAtlas: true,
      );
      final chipped = await _render(
        tileEffects: {wall: const ImpassableTile()},
        terrainHp: {wall: 2},
        withAtlas: true,
      );
      final stump = await _render(
        tileEffects: {wall: const ImpassableTile()},
        terrainHp: {wall: 1},
        withAtlas: true,
      );

      expect(
        chipped.wallRiseAbove(wall),
        lessThan(full.wallRiseAbove(wall)),
        reason: 'a half-destroyed wall stands as tall as an intact one',
      );
      expect(
        stump.wallRiseAbove(wall),
        lessThan(chipped.wallRiseAbove(wall)),
        reason: 'a nearly-destroyed wall does not read as nearly destroyed',
      );
      expect(
        stump.wallRiseAbove(wall),
        greaterThan(0),
        reason: 'a 1 HP wall vanished entirely — it is still an obstacle',
      );
    });
  });

  testWidgets('without the atlas a wall falls back to the flat crosshatch', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final r = await _render(
        tileEffects: {wall: const ImpassableTile()},
        withAtlas: false,
      );
      expect(
        r.wallRiseAbove(wall),
        0,
        reason: 'rock was drawn without an atlas to draw it from',
      );
    });
  });

  testWidgets('walls paint back-to-front regardless of map insertion order', (
    tester,
  ) async {
    await tester.runAsync(() async {
      // Flat tile effects never overlapped, so pass 1.5 could iterate
      // tileEffects in map order. A raised wall stands into the tile behind it,
      // so two adjacent walls now overlap and the order is load-bearing: drawn
      // in insertion order, the farther wall's body wins over the nearer one's.
      //
      // Asserting on the composite rather than on a probe pixel — the property
      // is "output does not depend on insertion order", which is exactly what
      // comparing the two renders tests.
      const near = HexCoord(0, 0);
      const far = HexCoord(0, -1);

      final frontFirst = await _render(
        tileEffects: {near: const ImpassableTile(), far: const ImpassableTile()},
        withAtlas: true,
      );
      final backFirst = await _render(
        tileEffects: {far: const ImpassableTile(), near: const ImpassableTile()},
        withAtlas: true,
      );

      expect(
        frontFirst.bytes,
        orderedEquals(backFirst.bytes),
        reason: 'wall render depends on tileEffects insertion order — two '
            'adjacent walls will overlap the wrong way round',
      );
    });
  });

  group('occlusion', () {
    testWidgets('an entity behind a wall is drawn through it', (tester) async {
      await tester.runAsync(() async {
        final r = await _render(
          tileEffects: {wall: const ImpassableTile()},
          occupancy: {'p1': behind},
          withAtlas: true,
        );
        // The band where the token's disc and the wall's raised body overlap:
        // the token centre is one row up, the wall reaches exactly that far, so
        // the lower part of the disc is inside the rock.
        final probe = Offset(r.hex(behind).dx, r.hex(wall).dy - rowStep + 6);
        expect(
          r.isWall(probe),
          isTrue,
          reason: 'the wall does not re-occlude the entity standing behind it',
        );
      });
    });

    testWidgets('the entity is not painted over completely', (tester) async {
      await tester.runAsync(() async {
        final r = await _render(
          tileEffects: {wall: const ImpassableTile()},
          occupancy: {'p1': behind},
          withAtlas: true,
        );
        // Above the wall's top the token must be untouched — the whole point of
        // partial re-occlusion is that head and torso stay clear.
        final head = Offset(r.hex(behind).dx, r.hex(behind).dy - 6);
        expect(
          r.isWall(head),
          isFalse,
          reason: 'the wall swallowed the entity whole instead of its feet',
        );
      });
    });

    testWidgets('an entity out of a wall reach is left alone', (tester) async {
      await tester.runAsync(() async {
        final r = await _render(
          tileEffects: {wall: const ImpassableTile()},
          occupancy: {'p1': farBehind},
          withAtlas: true,
        );
        // Two rows back is beyond the wall's bounds; ghosting it would be the
        // occlusion pass over-reaching.
        final centre = r.hex(farBehind);
        for (final dy in [-6.0, 0.0, 6.0]) {
          expect(
            r.isWall(Offset(centre.dx, centre.dy + dy)),
            isFalse,
            reason: 'an entity two rows behind a wall was ghosted anyway',
          );
        }
      });
    });
  });
}
