// SPDX-License-Identifier: GPL-3.0-or-later
//
// spell_art_pack_test.dart — real-device golden-path check for the built-in
// art pack picker (docs/SPELL_ART_PACK_PLAN.md Phase E). Runs the actual
// LibraryScreen widget tree on the real Linux desktop engine (real gesture
// pipeline, real WebP asset decode -- see the plan's §8 note that widget
// tests under the headless flutter_test binding don't exercise this), via
// `flutter test integration_test/spell_art_pack_test.dart -d linux`. Uses
// the project's existing fake path_provider so it never touches the real
// on-device spellbook.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:rune_duel/spells/spell_asset.dart';
import 'package:rune_duel/src/rust/frb_generated.dart' show RustLib;
import 'package:rune_duel/ui/library_screen.dart';
import 'package:rune_duel/ui/spell_art_pack_screen.dart';

import '../test/spells/fake_path_provider.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUpAll(() async {
    await RustLib.init();
  });

  setUp(() async {
    tempDir = await installFakePathProvider();

    final spell = SpellAsset(
      id: 'spell-1',
      createdAt: DateTime.utc(2026, 7, 27, 12, 0, 0),
      tier: 12,
      t: 5,
      ownerPubkeyHex: '0x1234abcd',
      manaCost: 42,
      segmentCount: 3,
      dotCount: 1,
      initialGrid: List<int>.filled(469, 0)..[234] = 1,
      proofBytes: Uint8List.fromList([1, 2, 3, 4, 5]),
      name: 'Ember Wake',
      commitmentHex: '0xaabbcc',
      spellHashHex: '0xddeeff',
    );
    await spell.save();
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  testWidgets(
      'choosing built-in art from the spell menu renders it on the real engine, '
      'then Revert to Coat of Arms clears it', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: LibraryScreen()));
    await tester.pumpAndSettle();

    expect(find.text('Ember Wake'), findsOneWidget);
    // Before any art is set, the card shows the vector coat of arms, not an
    // Image widget.
    expect(find.byType(Image), findsNothing);

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Set Custom Art'));
    await tester.pumpAndSettle();

    // The Phase E chooser sheet.
    expect(find.text('Choose from Art Pack'), findsOneWidget);
    expect(find.text('Import an Image…'), findsOneWidget);
    await tester.tap(find.text('Choose from Art Pack'));
    await tester.pumpAndSettle();

    expect(find.byType(SpellArtPackScreen), findsOneWidget);
    await tester.tap(find.text('Fire'));
    await tester.pumpAndSettle();

    await tester.tap(
      find.descendant(of: find.byType(GridView), matching: find.byType(InkWell)).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Choose'));
    await tester.pumpAndSettle();

    // Back on the Craftings tab: the real WebP asset decoded and rendered.
    expect(find.byType(SpellArtPackScreen), findsNothing);
    expect(find.byType(Image), findsOneWidget);
    expect(find.text('Replace Custom Art'), findsNothing); // menu closed; just a sanity check

    // Revert clears it back to the coat of arms.
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    expect(find.text('Replace Custom Art'), findsOneWidget);
    await tester.tap(find.text('Revert to Coat of Arms'));
    await tester.pumpAndSettle();

    expect(find.byType(Image), findsNothing);
  });
}
