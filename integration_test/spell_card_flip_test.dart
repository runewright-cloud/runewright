// SPDX-License-Identifier: GPL-3.0-or-later
//
// spell_card_flip_test.dart — real-device check that the fullscreen spell
// card's swipe-to-emblem gesture (lib/ui/spell_card_painter.dart) rotates the
// *whole card* (title/rules included, not just the art square) over time
// instead of hard-cutting between faces.
// Runs on the real Linux desktop engine (real gesture + animation pipeline —
// see spell_art_pack_test.dart's note that the headless flutter_test binding
// doesn't exercise this) via
// `flutter test integration_test/spell_card_flip_test.dart -d linux`.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:rune_duel/spells/spell_art_store.dart';
import 'package:rune_duel/spells/spell_asset.dart';
import 'package:rune_duel/ui/spell_card_painter.dart';

import '../test/spells/fake_path_provider.dart';

Uint8List _tinyValidPng() {
  final image = img.Image(width: 4, height: 4);
  img.fill(image, color: img.ColorRgb8(120, 40, 40));
  return img.encodePng(image);
}

SpellAsset _sample({String? artHash}) => SpellAsset(
      id: 'spell-1',
      createdAt: DateTime.utc(2026, 6, 19),
      tier: 12,
      t: 5,
      ownerPubkeyHex: '0x1234abcd',
      manaCost: 42,
      segmentCount: 3,
      dotCount: 1,
      initialGrid: List<int>.filled(469, 0)..[234] = 1,
      proofBytes: Uint8List.fromList([1, 2, 3]),
      name: 'Ember Wake',
      commitmentHex: '0xaabbcc',
      spellHashHex: '0xddeeff',
      artHash: artHash,
    );

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await installFakePathProvider();
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  testWidgets(
      'fullscreen card swipe rotates the whole card through a real flip, '
      'not an instant swap', (tester) async {
    final spell = _sample(artHash: '0xfeed');
    final art = _tinyValidPng();

    await tester.runAsync(() async {
      await SpellArtStore.save(spell.spellHashHex, full: art, thumb: art);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: SpellCardWidget(spell: spell)),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(SpellCardWidget));
      await tester.pumpAndSettle();

      final dialogImage =
          find.descendant(of: find.byType(Dialog), matching: find.byType(Image));

      expect(find.text('Swipe to see the true sigil'), findsOneWidget);
      expect(dialogImage, findsOneWidget); // custom art showing
      // Front-only chrome (title bar, rules box) is up before the flip.
      expect(find.text('Ember Wake'), findsOneWidget);
      expect(find.text('♦ 42'), findsOneWidget);

      final transformFinder = find.descendant(
        of: find.byType(Dialog),
        matching: find.byType(Transform),
      );
      // The art window always carries a fixed perspective entry (see
      // _artWindow's setEntry(3, 2, ...)); "flat" means no *rotation* on top
      // of that, not literal Matrix4.identity().
      final flat = Matrix4.identity()..setEntry(3, 2, 0.0015);

      final atRest = tester.widget<Transform>(transformFinder).transform;
      // At rest (flipT == 1), the visible face's own rotation is identity —
      // the resting card lies flat, not mid-turn or mirrored.
      expect(atRest, flat);

      await tester.drag(find.byType(Dialog), const Offset(-300, 0));

      // Sample twice inside the 420ms flip (see AnimationController in
      // _FullscreenSpellCardState) to prove the rotation is continuous
      // rather than jumping straight to the final state.
      await tester.pump(const Duration(milliseconds: 90));
      final midEarly = tester.widget<Transform>(transformFinder).transform;
      expect(midEarly, isNot(flat));

      await tester.pump(const Duration(milliseconds: 120));
      final midLate = tester.widget<Transform>(transformFinder).transform;
      expect(midLate, isNot(flat));
      expect(midLate, isNot(midEarly));

      await tester.pumpAndSettle();

      // Settled on the true emblem: hint flipped, art image gone, and the
      // resting transform is flat again (no leftover mirroring/rotation).
      expect(find.text('Swipe to see the custom art'), findsOneWidget);
      expect(dialogImage, findsNothing);
      final settled = tester.widget<Transform>(transformFinder).transform;
      expect(settled, flat);
      // The *whole* card flipped -- title bar and rules are gone too, not
      // just the art square swapped for the emblem.
      expect(find.text('Ember Wake'), findsNothing);
      expect(find.text('♦ 42'), findsNothing);

      // A tap still dismisses the dialog either way.
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);
    });
  });
}
