// SPDX-License-Identifier: GPL-3.0-or-later
//
// commune_trade_navigation_test.dart — drives the real widget tree for the
// Commune UI (docs/COMMUNE_TRADE_PLAN.md, lib/trade/sync_art_session.dart):
// MenuScreen -> tap "Commune" -> CommuneScreen -> tap "TRADE"/"SYNC ART" ->
// each screen's idle state. Real Navigator transitions, real build()
// methods -- only secure storage and the documents directory are faked (no
// native Keystore/filesystem under the headless test engine), same approach
// as onboarding_flow_drive_test.dart.
//
// No second device is available in this environment, so LAN pairing itself
// isn't exercised here -- see test/trade/trade_session_test.dart and
// test/trade/sync_art_session_test.dart for the full protocol round-trips
// over InMemoryTransport.
//
// The Library screen's LOANS tab (also new to this change) is deliberately
// NOT driven here: a diagnostic run showed LibraryScreen fails to settle
// under WidgetTester even on its unrelated default (Craftings) tab, well
// before reaching any Loans-specific code -- a pre-existing characteristic
// of that screen (no widget test exercised it before this change), not
// something introduced here. Its data layer (SpellPermission.loadAll,
// localIdentityMayUse, SpellAsset.gridWithheld) is covered directly in
// test/trade/trade_session_test.dart and test/spells/spell_authorization_test.dart.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/src/rust/frb_generated.dart';
import 'package:rune_duel/ui/menu_screen.dart';

import '../identity/fake_secure_storage.dart';
import '../spells/fake_path_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await RustLib.init();
  });

  late Directory tempDir;

  setUp(() async {
    installFakeSecureStorage();
    tempDir = await installFakePathProvider();
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  testWidgets('Menu -> Commune -> Trade renders the idle host/join state', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: MenuScreen()));
    await tester.pumpAndSettle();

    expect(find.text('Commune'), findsOneWidget);
    await tester.tap(find.text('Commune'));
    await tester.pumpAndSettle();

    expect(find.text('COMMUNE'), findsOneWidget);
    expect(find.text('TRADE'), findsOneWidget);
    expect(find.text('CREATE AN APPRENTICESHIP'), findsOneWidget);
    expect(find.text('SYNC ART'), findsOneWidget);

    // Create an Apprenticeship is still visible but disabled this milestone
    // (docs/COMMUNE_TRADE_PLAN.md §1) -- confirm it doesn't navigate.
    await tester.tap(find.text('CREATE AN APPRENTICESHIP'));
    await tester.pumpAndSettle();
    expect(find.text('COMMUNE'), findsOneWidget); // still on the Commune screen

    await tester.tap(find.text('TRADE'));
    await tester.pumpAndSettle();

    expect(find.text('TRADE'), findsWidgets); // AppBar title + nothing else conflicting
    expect(find.text('HOST A TRADE'), findsOneWidget);
    expect(find.text('JOIN A TRADE'), findsOneWidget);
  });

  testWidgets('Menu -> Commune -> Sync Art renders the idle host/join state', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: MenuScreen()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Commune'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('SYNC ART'));
    await tester.pumpAndSettle();

    expect(find.text('SYNC ART'), findsWidgets); // AppBar title + nothing else conflicting
    expect(find.text('HOST A SYNC'), findsOneWidget);
    expect(find.text('JOIN A SYNC'), findsOneWidget);
  });
}
