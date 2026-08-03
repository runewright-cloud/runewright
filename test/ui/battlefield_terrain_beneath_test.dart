// SPDX-License-Identifier: GPL-3.0-or-later
//
// battlefield_terrain_beneath_test.dart — the scenery must be visible *inside*
// the battle grid, and the cells must stay easy to tell apart on top of it.
//
// Unlike battlefield_painter_test.dart (a paint()-time crash smoke test) this
// one does assert pixels, because the requirement is inherently visual and the
// failure mode is silent: BattlefieldPainter's playable tiles were originally
// an opaque fill, which hid the terrain completely while every other test
// stayed green. A pixel probe is the only thing that notices.

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/engine/hex_grid.dart' show HexCoord;
import 'package:rune_duel/ui/battlefield_painter.dart';

/// Stand-in for scenery: a flat, unmistakable colour drawn under the painter.
const Color _kUnderlay = Color(0xFF00C8FF);

const Size _kSize = Size(400, 400);
const double _kHexSize = 24;

/// Renders the painter over [_kUnderlay] and returns the pixel at the centre of
/// the given hex — i.e. the middle of a playable cell, well away from its rim.
Future<Color> _cellCentre(HexCoord hex, {required bool terrainBeneath}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder, Offset.zero & _kSize);
  canvas.drawRect(Offset.zero & _kSize, Paint()..color = _kUnderlay);

  BattlefieldPainter(
    radius: 4,
    hexSize: _kHexSize,
    occupancy: const {},
    terrainBeneath: terrainBeneath,
  ).paint(canvas, _kSize);

  final image = await recorder.endRecording().toImage(
    _kSize.width.toInt(),
    _kSize.height.toInt(),
  );
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);

  final centre = Offset(_kSize.width / 2, _kSize.height / 2);
  final p = hexToPixel(hex, centre, _kHexSize);
  final offset = ((p.dy.round() * _kSize.width.toInt()) + p.dx.round()) * 4;
  final bytes = data!.buffer.asUint8List();
  return Color.fromARGB(
    bytes[offset + 3],
    bytes[offset],
    bytes[offset + 1],
    bytes[offset + 2],
  );
}

void main() {
  // Two cells of opposite checkerboard parity, both well inside the grid.
  const lightCell = HexCoord(0, 0);
  const darkCell = HexCoord(1, 0);

  testWidgets('terrainBeneath lets what is underneath show through the grid', (
    tester,
  ) async {
    await tester.runAsync(() async {
      for (final hex in [lightCell, darkCell]) {
        final washed = await _cellCentre(hex, terrainBeneath: true);
        // The underlay is strongly blue; anything that still reads as blue-
        // dominant proves the fill is a wash and not an opaque board.
        expect(
          washed.b,
          greaterThan(washed.r),
          reason: 'cell $hex hides the terrain underneath it',
        );
        expect(
          washed.b,
          greaterThan(0.5),
          reason: 'cell $hex washes the terrain too heavily',
        );
      }
    });
  });

  testWidgets('the default opaque board still hides what is underneath', (
    tester,
  ) async {
    await tester.runAsync(() async {
      // Guards the fallback used when the atlas fails to load: without terrain
      // a translucent board would show the bare scaffold.
      for (final hex in [lightCell, darkCell]) {
        final filled = await _cellCentre(hex, terrainBeneath: false);
        expect(
          filled.b,
          lessThan(filled.r),
          reason: 'cell $hex is no longer opaque stone',
        );
      }
    });
  });

  testWidgets('adjacent cells remain distinguishable over terrain', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final light = await _cellCentre(lightCell, terrainBeneath: true);
      final dark = await _cellCentre(darkCell, terrainBeneath: true);
      // The checkerboard survives as a wash: neighbouring cells must not
      // render identically, or the grid reads as one undifferentiated field.
      expect(
        light.toARGB32(),
        isNot(dark.toARGB32()),
        reason: 'checkerboard wash vanished — cells are indistinguishable',
      );
    });
  });

  testWidgets('the tile rim is drawn over terrain, not just the fill', (
    tester,
  ) async {
    await tester.runAsync(() async {
      // Probe the shared edge between two adjacent cells. With terrain beneath
      // it must be neither the raw underlay nor either cell's wash — the
      // dark halo plus light line is what keeps cells countable on any ground.
      final centre = Offset(_kSize.width / 2, _kSize.height / 2);
      final a = hexToPixel(lightCell, centre, _kHexSize);
      final b = hexToPixel(darkCell, centre, _kHexSize);
      final edge = Offset((a.dx + b.dx) / 2, (a.dy + b.dy) / 2);

      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder, Offset.zero & _kSize);
      canvas.drawRect(Offset.zero & _kSize, Paint()..color = _kUnderlay);
      BattlefieldPainter(
        radius: 4,
        hexSize: _kHexSize,
        occupancy: const {},
        terrainBeneath: true,
      ).paint(canvas, _kSize);
      final image = await recorder.endRecording().toImage(400, 400);
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      final off = ((edge.dy.round() * 400) + edge.dx.round()) * 4;
      final bytes = data!.buffer.asUint8List();
      final rim = Color.fromARGB(
        bytes[off + 3],
        bytes[off],
        bytes[off + 1],
        bytes[off + 2],
      );

      // The halo is near-black; the underlay is bright blue. A rim pixel must
      // be substantially darker than the ground it sits on.
      expect(
        rim.b,
        lessThan(0.75),
        reason: 'no rim drawn between adjacent cells — they will blur together',
      );
    });
  });
}
