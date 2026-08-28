// SPDX-License-Identifier: GPL-3.0-or-later
//
// library_armor_test.dart — Aetherial Armor through the real Library screen:
// how an armor is presented in Craftings, that it cannot be added to a
// chapter's spell list, and the chapter editor's equip / replace / remove
// flow with its slot budget.
//
// LibraryScreen does real dart:io file I/O on load, so this uses the same
// runAsync + real-delay settle that dev_surfaces_hidden_test.dart documents;
// pumpAndSettle hangs here.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/engine/border_zone.dart';
import 'package:rune_duel/spells/chapter_asset.dart';
import 'package:rune_duel/src/rust/frb_generated.dart';
import 'package:rune_duel/ui/library_screen.dart';

import '../identity/fake_secure_storage.dart';
import '../spells/armor_fixture.dart';
import '../spells/fake_path_provider.dart';

Future<void> _settleReal(WidgetTester tester, {int rounds = 3}) async {
  for (var i = 0; i < rounds; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350)); // tab/route animation
  }
}

/// Opens the CHAPTERS tab and enters the chapter named [name].
Future<void> _openChapter(WidgetTester tester, String name) async {
  await tester.tap(find.text('CHAPTERS'));
  await _settleReal(tester);
  await tester.tap(find.text(name));
  await _settleReal(tester);
}

Future<ChapterAsset> _reload(String id) async =>
    (await ChapterAsset.loadById(id))!;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  // Craftings renders the wizard's sigil via the Rust bridge (poseidon2Hash2).
  setUpAll(() async {
    await RustLib.init();
  });

  setUp(() async {
    tempDir = await installFakePathProvider();
    installFakeSecureStorage();
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  Future<ChapterAsset> seedChapter({
    int artifacts = 0,
    String? armorSpellId,
  }) async {
    final chapter = ChapterAsset(
      id: 'chapter-1',
      name: 'Duel Chapter',
      createdAt: DateTime.utc(2026, 8, 25),
      artifacts: List.generate(
          artifacts, (_) => const ArtifactEntry(kind: ArtifactKind.manaGem)),
      armorSpellId: armorSpellId,
    );
    await chapter.save();
    return chapter;
  }

  // ── Craftings presentation ─────────────────────────────────────────────────

  testWidgets('an armor is labelled as one in the library, with no mana price',
      (tester) async {
    await tester.runAsync(() async {
      await armorAsset(
        id: 'a1',
        name: 'Stormplate',
        elements: runOf(BorderZone.air, 4),
      ).save();

      await tester.pumpWidget(const MaterialApp(home: LibraryScreen()));
      await _settleReal(tester);

      expect(find.text('Stormplate'), findsOneWidget);
      expect(find.textContaining('Aetherial Armor  ·  Gen 4'), findsOneWidget);
      // The proof-derived summary rides along on the card.
      expect(find.text('T 4  ·  1 artifact slot'), findsOneWidget);
      expect(find.text('Flying'), findsOneWidget);
    });
  });

  testWidgets('an armor offers no "Add to Chapter" or practice affordance, '
      'while an ordinary spell still does', (tester) async {
    await tester.runAsync(() async {
      await armorAsset(id: 'a1', name: 'Stormplate', elements: runOf(BorderZone.air, 4))
          .save();

      await tester.pumpWidget(const MaterialApp(home: LibraryScreen()));
      await _settleReal(tester);

      await tester.tap(find.byIcon(Icons.more_vert).first);
      await _settleReal(tester);

      expect(find.text('View'), findsOneWidget);
      expect(find.text('Add to Chapter'), findsNothing);
      expect(find.text('Practice Incantation'), findsNothing);
      expect(find.text('Delete Spell'), findsOneWidget);
    });
  });

  testWidgets('an ordinary spell keeps its Add to Chapter item', (tester) async {
    await tester.runAsync(() async {
      await plainSpell(id: 's1', name: 'Ember Wake').save();

      await tester.pumpWidget(const MaterialApp(home: LibraryScreen()));
      await _settleReal(tester);

      await tester.tap(find.byIcon(Icons.more_vert).first);
      await _settleReal(tester);

      expect(find.text('Add to Chapter'), findsOneWidget);
    });
  });

  // ── Chapter equip flow ─────────────────────────────────────────────────────

  testWidgets('a chapter with no armor says so and offers Equip',
      (tester) async {
    await tester.runAsync(() async {
      await seedChapter();
      await tester.pumpWidget(const MaterialApp(home: LibraryScreen()));
      await _settleReal(tester);
      await _openChapter(tester, 'Duel Chapter');

      expect(find.text('ARMOR'), findsOneWidget);
      expect(find.text('No armor equipped.'), findsOneWidget);
      expect(find.text('Equip'), findsOneWidget);
      expect(find.textContaining('12'), findsWidgets); // full slot budget
    });
  });

  testWidgets('equipping an armor binds it and spends its slots',
      (tester) async {
    await tester.runAsync(() async {
      await seedChapter(artifacts: 2);
      await armorAsset(
        id: 'a1',
        name: 'Stormplate',
        elements: runOf(BorderZone.air, 9), // T=9 -> 3 slots
      ).save();

      await tester.pumpWidget(const MaterialApp(home: LibraryScreen()));
      await _settleReal(tester);
      await _openChapter(tester, 'Duel Chapter');

      // 2 artifacts, no armor yet.
      expect(find.text('7'), findsNothing);
      await tester.tap(find.text('Equip'));
      await _settleReal(tester);
      await tester.tap(find.text('Stormplate'));
      await _settleReal(tester);
      await _settleReal(tester);

      expect((await _reload('chapter-1')).armorSpellId, 'a1');
      // 2 artifacts + 3 armor slots = 5 used, 7 remaining.
      expect(find.text('7'), findsOneWidget);
      expect(find.text('Replace'), findsOneWidget);
      expect(find.text('Remove'), findsOneWidget);
    });
  });

  testWidgets('replacing an armor rebinds it and releases the old slots',
      (tester) async {
    await tester.runAsync(() async {
      await armorAsset(id: 'a1', name: 'Heavyplate', elements: runOf(BorderZone.earth, 9))
          .save();
      await armorAsset(id: 'a2', name: 'Lightplate', elements: runOf(BorderZone.air, 4))
          .save();
      await seedChapter(artifacts: 2, armorSpellId: 'a1');

      await tester.pumpWidget(const MaterialApp(home: LibraryScreen()));
      await _settleReal(tester);
      await _openChapter(tester, 'Duel Chapter');

      // 2 + 3 = 5 used, 7 free.
      expect(find.text('7'), findsOneWidget);

      await tester.tap(find.text('Replace'));
      await _settleReal(tester);
      await tester.tap(find.text('Lightplate'));
      await _settleReal(tester);
      await _settleReal(tester);

      expect((await _reload('chapter-1')).armorSpellId, 'a2');
      // 2 + 1 = 3 used, 9 free: the T9 armor's slots came back.
      expect(find.text('9'), findsOneWidget);
    });
  });

  testWidgets('removing an armor clears the binding and restores its slots',
      (tester) async {
    await tester.runAsync(() async {
      await armorAsset(id: 'a1', name: 'Heavyplate', elements: runOf(BorderZone.earth, 9))
          .save();
      await seedChapter(artifacts: 2, armorSpellId: 'a1');

      await tester.pumpWidget(const MaterialApp(home: LibraryScreen()));
      await _settleReal(tester);
      await _openChapter(tester, 'Duel Chapter');
      expect(find.text('7'), findsOneWidget);

      await tester.tap(find.text('Remove'));
      await _settleReal(tester);

      expect((await _reload('chapter-1')).armorSpellId, isNull);
      expect(find.text('No armor equipped.'), findsOneWidget);
      expect(find.text('10'), findsOneWidget); // 12 - 2 artifacts
    });
  });

  testWidgets('an armor the chapter cannot afford is offered but not equippable',
      (tester) async {
    await tester.runAsync(() async {
      await seedChapter(artifacts: 10);
      await armorAsset(id: 'a1', name: 'Heavyplate', elements: runOf(BorderZone.earth, 9))
          .save();

      await tester.pumpWidget(const MaterialApp(home: LibraryScreen()));
      await _settleReal(tester);
      await _openChapter(tester, 'Duel Chapter');

      await tester.tap(find.text('Equip'));
      await _settleReal(tester);
      expect(find.textContaining('Needs 3 slots'), findsOneWidget);

      await tester.tap(find.text('Heavyplate'));
      await _settleReal(tester);

      expect((await _reload('chapter-1')).armorSpellId, isNull);
    });
  });

  testWidgets('deleting the equipped armor unbinds it rather than stranding '
      'the slots', (tester) async {
    await tester.runAsync(() async {
      final armor =
          armorAsset(id: 'a1', name: 'Heavyplate', elements: runOf(BorderZone.earth, 9));
      await armor.save();
      await seedChapter(artifacts: 2, armorSpellId: 'a1');

      await armor.delete();

      expect((await _reload('chapter-1')).armorSpellId, isNull);
    });
  });
}
