// SPDX-License-Identifier: GPL-3.0-or-later
//
// Widget tests for SpellCardWidget's two-layer custom-art behavior (P1):
// the small card shows custom art when present and the coat of arms
// otherwise; the full-screen overlay keeps the true (commitmentHex-derived)
// emblem reachable via swipe whenever custom art is set.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:rune_duel/spells/spell_art_store.dart';
import 'package:rune_duel/spells/spell_asset.dart';
import 'package:rune_duel/ui/spell_card_painter.dart';

import '../spells/fake_path_provider.dart';

// A tiny but genuinely decodable image, so Image.memory in the widget under
// test doesn't hit an async decode error mid-test.
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
      artSource: artHash != null ? SpellArtSource.localImport : null,
      artUpdatedAt: artHash != null ? DateTime.utc(2026, 7, 1) : null,
    );

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await installFakePathProvider();
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  testWidgets('spell with no custom art renders the vector coat-of-arms painter',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: SpellCardWidget(spell: _sample())),
    ));
    await tester.pumpAndSettle();

    expect(find.byType(CustomPaint), findsWidgets);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('spell with custom art renders the stored thumbnail once loaded',
      (tester) async {
    final spell = _sample(artHash: '0xfeed');
    final thumb = _tinyValidPng();

    // Real dart:io file I/O (SpellArtStore) and real image decode
    // (Image.memory) are genuine async work outside the fake-clock test
    // zone -- tester.runAsync() is the documented way to let both actually
    // complete instead of hanging pump().
    await tester.runAsync(() async {
      await SpellArtStore.save(spell.spellHashHex, full: thumb, thumb: thumb);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: SpellCardWidget(spell: spell)),
      ));
      // pumpAndSettle alone can race the real file read; give it a beat on
      // the real clock (we're inside runAsync, so this is a genuine delay)
      // before pumping again.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pumpAndSettle();
    });

    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets(
      'full-screen overlay for a spell with no art has no swipe hint (emblem only, unchanged behavior)',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: SpellCardWidget(spell: _sample())),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(SpellCardWidget));
    await tester.pumpAndSettle();

    expect(find.textContaining('Swipe to see'), findsNothing);
    // Tapping again (anywhere on the opaque overlay) dismisses it.
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
  });

  testWidgets(
      'full-screen overlay for a spell WITH art shows a swipe hint and the true emblem stays reachable',
      (tester) async {
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

      // Custom art is showing by default; the true sigil is one swipe away --
      // this is the anti-spoof guarantee (CLAUDE.md custom-art invariant 3).
      expect(find.text('Swipe to see the true sigil'), findsOneWidget);

      // Swipe (horizontal drag) flips to the emblem.
      await tester.drag(find.byType(Dialog), const Offset(-300, 0));
      await tester.pumpAndSettle();

      expect(find.text('Swipe to see the custom art'), findsOneWidget);
      expect(find.byType(CustomPaint), findsWidgets); // emblem painter now showing
    });
  });
}
