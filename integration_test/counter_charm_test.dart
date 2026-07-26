// SPDX-License-Identifier: GPL-3.0-or-later
//
// counter_charm_test.dart — real-device golden-path check for the counter
// charm bind flow (docs: Phase 1 of the counter-charm plan). Runs the actual
// LibraryScreen widget tree on the real Linux desktop engine (real gesture
// pipeline, real rendering) via `flutter test integration_test/
// counter_charm_test.dart -d linux`, not the headless flutter_test binding.
// Uses the project's existing fake path_provider / fake secure_storage so it
// never touches the real on-device spellbook.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:rune_duel/spells/spell_asset.dart';
import 'package:rune_duel/src/rust/frb_generated.dart' show RustLib;
import 'package:rune_duel/ui/library_screen.dart';

import '../test/identity/fake_secure_storage.dart';
import '../test/spells/fake_path_provider.dart';

/// Pumps in small real-time steps until [finder] matches something, instead
/// of guessing a fixed delay. Needed for asserting on a SnackBar's text: the
/// SnackBar appears only after an async gap (file I/O in this case) and
/// auto-dismisses on its own timer, so a plain `pumpAndSettle()` either
/// returns before the async work lands or — because it keeps pumping real
/// time until nothing is animating — runs straight through the SnackBar's
/// whole display window and returns after it's already gone.
Future<void> _pumpUntilFound(WidgetTester tester, Finder finder,
    {Duration timeout = const Duration(seconds: 5)}) async {
  final deadline = DateTime.now().add(timeout);
  while (finder.evaluate().isEmpty) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for $finder');
    }
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Finds the "⋮" menu button belonging to the spell card whose title reads
/// [spellName], scoped via the innermost Row _SpellCard puts the name and
/// the PopupMenuButton in — needed once more than one spell card is on
/// screen, since a bare find.byIcon(Icons.more_vert) would match every card.
Finder _moreVertNear(WidgetTester tester, String spellName) {
  final row = find.ancestor(of: find.text(spellName), matching: find.byType(Row)).first;
  return find.descendant(of: row, matching: find.byIcon(Icons.more_vert));
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUpAll(() async {
    await RustLib.init();
  });

  setUp(() async {
    installFakeSecureStorage();
    tempDir = await installFakePathProvider();

    // Seed two real spells (distinct grid commitments) so the Craftings tab
    // has one card to bind the only unbound charm to, and a second card to
    // prove a follow-up bind attempt is refused for lack of a free charm —
    // not just short-circuited by the "already attuned to this grid" guard.
    final spellA = SpellAsset(
      id: 'spell-1',
      createdAt: DateTime.utc(2026, 7, 24, 12, 0, 0),
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
    await spellA.save();

    final spellB = SpellAsset(
      id: 'spell-2',
      createdAt: DateTime.utc(2026, 7, 24, 12, 1, 0),
      tier: 12,
      t: 5,
      ownerPubkeyHex: '0x1234abcd',
      manaCost: 30,
      segmentCount: 2,
      dotCount: 0,
      initialGrid: List<int>.filled(469, 0)..[233] = 1,
      proofBytes: Uint8List.fromList([6, 7, 8, 9, 10]),
      name: 'Frostbind',
      commitmentHex: '0x112233',
      spellHashHex: '0x445566',
    );
    await spellB.save();
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  testWidgets('add unbound charm, bind it from the spell menu, second bind is refused',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: LibraryScreen()));
    await tester.pumpAndSettle();

    // ── Chapters tab: create a chapter and add one unbound Counter Charm ──
    await tester.tap(find.text('CHAPTERS'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Create New Chapter'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Test Chapter');
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Test Chapter'));
    await tester.pumpAndSettle();

    // The lone chapter is auto-selected as active by _loadChapters, so no
    // "Set as Active" tap is needed here — the AppBar already reads ACTIVE.
    expect(find.text('ACTIVE'), findsOneWidget);

    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Counter Charm'));
    await tester.pumpAndSettle();

    expect(find.text('Counter Charm'), findsOneWidget); // the group tile
    expect(find.text('1'), findsOneWidget); // unbound count

    // Back out to Craftings to bind the charm to the seeded spell.
    await tester.pageBack();
    await tester.pumpAndSettle();

    await tester.tap(find.text('CRAFTINGS'));
    await tester.pumpAndSettle();

    expect(find.text('Ember Wake'), findsOneWidget);
    expect(find.text('Frostbind'), findsOneWidget);

    await tester.tap(_moreVertNear(tester, 'Ember Wake'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bind to Counter Charm'));
    final successSnackbar = find.text('Counter charm attuned to "Ember Wake".');
    await _pumpUntilFound(tester, successSnackbar);
    expect(successSnackbar, findsOneWidget);
    await tester.pumpAndSettle(); // let the SnackBar finish its own lifecycle

    // ── Back to Chapters: the charm should now show as bound ──
    await tester.tap(find.text('CHAPTERS'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Test Chapter'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Attuned to: Ember Wake'), findsOneWidget);
    // No unbound charms remain, so the grouped tile should be gone —
    // only the bound _CounterCharmTile's own "Counter Charm" label remains.
    expect(find.text('Counter Charm'), findsOneWidget);
    expect(find.text('No artifacts equipped.'), findsNothing);

    // Second bind attempt, on a DIFFERENT spell, must be refused for lack of
    // an unbound charm — not short-circuited by the "already attuned to
    // this grid" duplicate guard, which is what re-targeting Ember Wake
    // would exercise instead.
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('CRAFTINGS'));
    await tester.pumpAndSettle();
    await tester.tap(_moreVertNear(tester, 'Frostbind'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bind to Counter Charm'));
    final refusalSnackbar = find.text('No unbound charms available.');
    await _pumpUntilFound(tester, refusalSnackbar);
    expect(refusalSnackbar, findsOneWidget);
    await tester.pumpAndSettle();
  });
}
