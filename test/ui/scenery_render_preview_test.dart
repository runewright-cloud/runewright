// SPDX-License-Identifier: GPL-3.0-or-later
//
// scenery_render_preview_test.dart — renders backdrops to PNG for eyeballing.
//
// Not an assertion test: the invariants live in scenery_map_test.dart. This is
// the tuning loop. Terrain palettes, dimming and vignette are judgement calls
// that no unit test can make, and the repo's verification hierarchy puts
// "looked at it" above "the test went green".
//
// Set SCENERY_PREVIEW_DIR to render one PNG per region plus a seed sweep:
//
//     SCENERY_PREVIEW_DIR=/tmp/scenery flutter test \
//         test/ui/scenery_render_preview_test.dart
//
// Without that variable the test is a no-op, so it costs nothing in CI.

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/engine/hex_grid.dart' show HexCoord;
import 'package:rune_duel/ui/battlefield_painter.dart' show BattlefieldPainter;
import 'package:rune_duel/ui/scenery/scenery_map.dart';
import 'package:rune_duel/ui/scenery/scenery_painter.dart';

const String _atlasPath = 'assets/art_pack/terrain/hex_terrain_atlas.png';

Future<ui.Image> _loadAtlasFromDisk() async {
  // rootBundle is unavailable outside a real app, so read the shipped file.
  final bytes = await File(_atlasPath).readAsBytes();
  final codec = await ui.instantiateImageCodec(bytes);
  return (await codec.getNextFrame()).image;
}

Future<void> _render({
  required ui.Image atlas,
  required String path,
  required int seed,
  SceneryRegion? region,
  Size size = const Size(720, 900),
  int playRadius = 4,
}) async {
  final hexSize = _hexSizeFromConstraints(size, playRadius);
  final map = generateSceneryMap(
    seed: seed,
    radius: sceneryRadiusForPanel(size, hexSize),
    region: region,
    focusRadius: playRadius,
  );

  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder, Offset.zero & size);
  canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF1A1008));
  SceneryBackdropPainter(
    map: map,
    atlas: atlas,
    hexSize: hexSize,
    playRadius: playRadius,
  ).paint(canvas, size);

  // The whole point of the preview is the composite: scenery alone says
  // nothing about whether the playable cells stay countable on top of it.
  BattlefieldPainter(
    radius: playRadius,
    hexSize: hexSize,
    terrainBeneath: true,
    occupancy: {
      'local': HexCoord(0, playRadius),
      'foe': HexCoord(0, -playRadius),
    },
    localPlayerId: 'local',
  ).paint(canvas, size);

  final picture = recorder.endRecording();
  final image = await picture.toImage(size.width.toInt(), size.height.toInt());
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  await File(path).writeAsBytes(png!.buffer.asUint8List());
  // ignore: avoid_print
  print(
    'wrote $path  (${map.region.label}, seed $seed, ${map.tiles.length} tiles)',
  );
}

/// Mirrors BattleScreen._hexSizeFromConstraints so previews match the app.
double _hexSizeFromConstraints(Size available, int radius) {
  final byWidth = available.width / (3 * radius + 2);
  final byHeight = available.height / (1.7320508075688772 * (2 * radius + 1));
  final smaller = byWidth < byHeight ? byWidth : byHeight;
  return smaller.clamp(6.0, 36.0);
}

void main() {
  final outDir = Platform.environment['SCENERY_PREVIEW_DIR'];

  testWidgets('render scenery previews', (tester) async {
    if (outDir == null) {
      // ignore: avoid_print
      print('SCENERY_PREVIEW_DIR unset — skipping preview render.');
      return;
    }
    Directory(outDir).createSync(recursive: true);

    // Image decode and Picture.toImage need the real event loop and raster
    // thread; under the default fake-async test zone they never complete.
    await tester.runAsync(() async {
      final atlas = await _loadAtlasFromDisk();

      for (final region in SceneryRegion.values) {
        await _render(
          atlas: atlas,
          path: '$outDir/region_${region.name}.png',
          seed: 20260728,
          region: region,
        );
      }
      for (var seed = 0; seed < 6; seed++) {
        await _render(
          atlas: atlas,
          path: '$outDir/seed_$seed.png',
          seed: seed * 7919 + 13,
        );
      }
    });
  });
}
