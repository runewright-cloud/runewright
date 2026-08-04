// SPDX-License-Identifier: GPL-3.0-or-later
//
// avatar_picker_test.dart — AvatarPickerScreen's picking flow
// (docs/AVATAR_PICKER_PLAN.md §6): a monster tile is reachable via the
// Monsters filter chip, tapping a tile then Choose pops the chosen id,
// leaving via the back button pops null, and the screen never throws when
// the atlas hasn't decoded (or fails to).
//
// Atlases are synthetic (ui.decodeImageFromPixels), not the real shipped
// PNGs: decoding an asset PNG via ui.instantiateImageCodec/File hangs under
// flutter_tester in this environment (the same reason
// wizard_movement_preview_test.dart's equivalent path is gated behind an
// opt-in env var and skipped by default) — a plain "fake atlas image" is all
// the plan actually asks for here.

import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/ui/avatars/avatar_picker_screen.dart';
import 'package:rune_duel/ui/avatars/avatar_sprites.dart';

Future<ui.Image> _fakeImage(int width, int height) {
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    Uint8List(width * height * 4),
    width,
    height,
    ui.PixelFormat.rgba8888,
    completer.complete,
  );
  return completer.future;
}

void main() {
  group('AvatarPickerScreen', () {
    testWidgets('renders without throwing when the atlas is null', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: AvatarPickerScreen()));
      expect(tester.takeException(), isNull);
      expect(find.text('Choose Avatar'), findsOneWidget);
      // Placeholder cards show the avatar name once, as the caption below.
      expect(find.text('Fighter F 01'), findsOneWidget);
    });

    testWidgets('a monster tile is reachable from the Monsters chip', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: AvatarPickerScreen()));
      expect(find.text('Flower 01'), findsNothing);

      await tester.tap(find.text('Monsters'));
      await tester.pumpAndSettle();

      expect(find.text('Flower 01'), findsOneWidget);
      expect(find.text('Fighter F 01'), findsNothing);
    });

    testWidgets('Choose pops the tapped avatar id; leaving via back pops null',
        (tester) async {
      String? pushResult = 'unset';
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                pushResult = await Navigator.push<String>(
                  context,
                  MaterialPageRoute(builder: (_) => const AvatarPickerScreen()),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Fighter F 01'));
      await tester.pumpAndSettle();
      expect(find.text('Choose'), findsOneWidget);

      // The dialog's Cancel only closes the preview, not the whole picker —
      // still browsing after backing out of one tile's preview.
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Choose Avatar'), findsOneWidget);
      expect(pushResult, 'unset');

      await tester.tap(find.text('Fighter F 01'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Choose'));
      await tester.pumpAndSettle();
      expect(pushResult, 'fighter_f_01');

      // Reopen and this time leave the whole picker via the back button —
      // that's what should pop null.
      pushResult = 'unset';
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(pushResult, isNull);
    });

    testWidgets('with injected atlases, a chosen tile still resolves to the '
        'right art in the preview', (tester) async {
      // decodeImageFromPixels' completion arrives via a real engine callback,
      // which never reaches an awaited Future inside testWidgets' FakeAsync
      // zone unless bridged through runAsync — otherwise the await hangs.
      final portraits = await tester.runAsync(
        () => _fakeImage(kAvatarPortraitAtlasWidth, kAvatarPortraitAtlasHeight),
      );
      final sprites = await tester.runAsync(
        () => _fakeImage(kAvatarAtlasWidth, kAvatarAtlasHeight),
      );
      String? pushResult;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                pushResult = await Navigator.push<String>(
                  context,
                  MaterialPageRoute(
                    builder: (_) => AvatarPickerScreen(
                      portraitAtlas: portraits,
                      spriteAtlas: sprites,
                    ),
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      // 'Mage F 01' is a few rows down in catalog order — scroll the grid
      // into the viewport before tapping (GridView.builder doesn't build
      // off-screen tiles).
      await tester.dragUntilVisible(
        find.text('Mage F 01'),
        find.byType(GridView),
        const Offset(0, -200),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mage F 01'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Choose'));
      await tester.pumpAndSettle();

      expect(pushResult, 'mage_f_01');
      expect(avatarArtById(pushResult!)?.category, AvatarCategory.heroes);
    });

    testWidgets('tile portraits lay out with a non-zero paint area', (tester) async {
      // Regression: the tile's portrait used to be a childless CustomPaint,
      // which takes `constraints.smallest`. The Column above it passes a LOOSE
      // width (crossAxisAlignment.center), so it laid out 0 px wide — the grid
      // showed borders and names with no artwork, and every existing test
      // still passed because they only ever look up name text.
      final portraits = await tester.runAsync(
        () => _fakeImage(kAvatarPortraitAtlasWidth, kAvatarPortraitAtlasHeight),
      );
      final sprites = await tester.runAsync(
        () => _fakeImage(kAvatarAtlasWidth, kAvatarAtlasHeight),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: AvatarPickerScreen(portraitAtlas: portraits, spriteAtlas: sprites),
        ),
      );
      await tester.pumpAndSettle();

      final painters = find.descendant(
        of: find.byType(GridView),
        matching: find.byType(CustomPaint),
      );
      expect(painters, findsWidgets);
      for (final element in painters.evaluate()) {
        final size = (element.renderObject! as RenderBox).size;
        expect(size.width, greaterThan(0),
            reason: 'a tile portrait laid out with zero width');
        expect(size.height, greaterThan(0));
      }
    });
  });
}
