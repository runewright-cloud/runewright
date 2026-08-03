// SPDX-License-Identifier: GPL-3.0-or-later
//
// wizard_movement_preview_test.dart — renders the wizard walk to PNG for
// eyeballing, in the same spirit as scenery_render_preview_test.dart.
//
// Not an assertion test: the invariants live in wizard_movement_animation_test
// .dart. This is the tuning loop for the judgement calls no unit test can make
// — sprite scale on the tile, how far the lunge reaches, whether the impact
// spark reads as a shoulder-check or as a spell going off.
//
// Set WIZARD_PREVIEW_DIR to render a filmstrip of a speed-win collision plus a
// facing sheet:
//
//     WIZARD_PREVIEW_DIR=/tmp/wizards flutter test \
//         test/ui/wizard_movement_preview_test.dart
//
// Without that variable the test is a no-op, so it costs nothing in CI.

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/engine/hex_grid.dart' show HexCoord;
import 'package:rune_duel/ui/avatars/avatar_sprites.dart';
import 'package:rune_duel/ui/battlefield_painter.dart';
import 'package:rune_duel/ui/scenery/scenery_map.dart';
import 'package:rune_duel/ui/scenery/scenery_painter.dart';

const String _terrainAtlasPath = 'assets/art_pack/terrain/hex_terrain_atlas.png';
const String _avatarAtlasPath = 'assets/art_pack/avatars/avatar_atlas.png';

Future<ui.Image> _decode(String path) async {
  // rootBundle is unavailable outside a real app, so read the shipped file.
  final bytes = await File(path).readAsBytes();
  final codec = await ui.instantiateImageCodec(bytes);
  return (await codec.getNextFrame()).image;
}

/// A head-on collision the faster wizard wins: 'foe' walks two tiles east to
/// west into (0,0) and keeps it; 'me' reaches for it from the west, loses, and
/// is shoved back to (-1,0).
const _collision = [
  AvatarMoveAnimation(
    playerId: 'me',
    path: [HexCoord(-2, 0), HexCoord(-1, 0)],
    lungeTile: HexCoord(0, 0),
  ),
  AvatarMoveAnimation(
    playerId: 'foe',
    path: [HexCoord(2, 0), HexCoord(1, 0), HexCoord(0, 0)],
    wonContestAt: HexCoord(0, 0),
  ),
];

Future<void> _renderFrames({
  required ui.Image terrain,
  required ui.Image? avatars,
  required String path,
  required List<double> times,
  Size frame = const Size(360, 300),
  int playRadius = 3,
}) async {
  final hexSize = _hexSizeFromConstraints(frame, playRadius);
  final map = generateSceneryMap(
    seed: 20260730,
    radius: sceneryRadiusForPanel(frame, hexSize),
    focusRadius: playRadius,
  );

  final size = Size(frame.width, frame.height * times.length);
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder, Offset.zero & size);
  canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF1A1008));

  for (var i = 0; i < times.length; i++) {
    canvas.save();
    canvas.translate(0, frame.height * i);
    canvas.clipRect(Offset.zero & frame);
    SceneryBackdropPainter(
      map: map,
      atlas: terrain,
      hexSize: hexSize,
      playRadius: playRadius,
    ).paint(canvas, frame);
    BattlefieldPainter(
      radius: playRadius,
      hexSize: hexSize,
      terrainBeneath: true,
      localPlayerId: 'me',
      occupancy: const {'me': HexCoord(-1, 0), 'foe': HexCoord(0, 0)},
      avatarMoveAnimations: _collision,
      moveAnimation: AlwaysStoppedAnimation<double>(times[i]),
      avatarAtlas: avatars,
    ).paint(canvas, frame);
    // Label the frame with its playback fraction.
    final label = TextPainter(
      text: TextSpan(
        text: 't = ${times[i].toStringAsFixed(2)}',
        style: const TextStyle(color: Colors.white70, fontSize: 12),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    label.paint(canvas, const Offset(8, 8));
    canvas.restore();
  }

  await _write(recorder.endRecording(), size, path);
}

/// One sprite in all four facings, at battlefield scale and at 4x, so the
/// pixel-art scaling can be judged.
Future<void> _renderFacings({
  required ui.Image avatars,
  required String path,
}) async {
  const size = Size(1400, 200);
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder, Offset.zero & size);
  canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF241505));

  final art = const AvatarAssignment().artFor('preview-wizard');
  var x = 40.0;
  for (final facing in AvatarFacing.values) {
    for (final pose in AvatarPose.values) {
      final src = art.frameRect(facing, pose);
      canvas.drawImageRect(
        avatars,
        src,
        Rect.fromLTWH(x, 40, 24 * 4, 32 * 4),
        Paint()
          ..filterQuality = FilterQuality.none
          ..isAntiAlias = false,
      );
      x += 24 * 4 + 8;
    }
    x += 16;
  }
  final label = TextPainter(
    text: TextSpan(
      text: '${art.id} — up / right / down / left, each: step stand step',
      style: const TextStyle(color: Colors.white70, fontSize: 13),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  label.paint(canvas, const Offset(40, 176));

  await _write(recorder.endRecording(), size, path);
}

Future<void> _write(ui.Picture picture, Size size, String path) async {
  final image = await picture.toImage(size.width.toInt(), size.height.toInt());
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  await File(path).writeAsBytes(png!.buffer.asUint8List());
  // ignore: avoid_print
  print('wrote $path');
}

/// Mirrors BattleScreen._hexSizeFromConstraints so previews match the app.
double _hexSizeFromConstraints(Size available, int radius) {
  final byWidth = available.width / (3 * radius + 2);
  final byHeight = available.height / (1.7320508075688772 * (2 * radius + 1));
  final smaller = byWidth < byHeight ? byWidth : byHeight;
  return smaller.clamp(6.0, 36.0);
}

void main() {
  final outDir = Platform.environment['WIZARD_PREVIEW_DIR'];

  testWidgets('render wizard movement previews', (tester) async {
    if (outDir == null) {
      // ignore: avoid_print
      print('WIZARD_PREVIEW_DIR unset — skipping preview render.');
      return;
    }
    Directory(outDir).createSync(recursive: true);

    // Image decode and Picture.toImage need the real event loop and raster
    // thread; under the default fake-async test zone they never complete.
    await tester.runAsync(() async {
      final terrain = await _decode(_terrainAtlasPath);
      final avatars = await _decode(_avatarAtlasPath);

      const beats = [0.0, 0.36, 0.72, 0.86, 1.0];
      await _renderFrames(
        terrain: terrain,
        avatars: avatars,
        path: '$outDir/collision_sprites.png',
        times: beats,
      );
      // The same beats with no atlas, to check the placeholder-disc fallback
      // still reads while the sprite sheet is decoding.
      await _renderFrames(
        terrain: terrain,
        avatars: null,
        path: '$outDir/collision_discs.png',
        times: beats,
      );
      await _renderFacings(avatars: avatars, path: '$outDir/facings.png');
    });
  });
}
