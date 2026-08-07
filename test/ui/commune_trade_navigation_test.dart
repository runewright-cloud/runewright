// SPDX-License-Identifier: GPL-3.0-or-later
//
// commune_trade_navigation_test.dart — drives the real widget tree for the
// Commune UI (docs/COMMUNE_TRADE_PLAN.md, docs/MASTER_APPRENTICE_PLAN.md,
// lib/trade/sync_art_session.dart): MenuScreen -> tap "Commune" ->
// CommuneScreen -> tap "TRADE"/"CREATE AN APPRENTICESHIP"/"SYNC ART" ->
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
//
// The same characteristic applies to ApprenticeshipScreen
// (docs/MASTER_APPRENTICE_PLAN.md §6.2): its FutureBuilder loads
// ApprenticeshipRecord data via real dart:io File/Directory calls, and a
// diagnostic run confirmed the underlying Future never resolves under
// WidgetTester.pump()/pumpAndSettle() (nor does wrapping the wait in
// tester.runAsync() bridge it, since the Future is already created against
// the fake test zone by the time initState runs) -- it just spins the
// CircularProgressIndicator forever. So this file only confirms navigation
// REACHES the screen (its AppBar title, which renders independently of the
// FutureBuilder); it does not drive past the loading state into the
// offer/pairing screen. That data layer and the full protocol round-trip
// are covered directly in test/apprentice/apprenticeship_test.dart and
// test/apprentice/apprentice_session_test.dart.

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
    expect(find.text('SYNC ART & SOUND'), findsOneWidget);

    await tester.tap(find.text('TRADE'));
    await tester.pumpAndSettle();

    expect(find.text('TRADE'), findsWidgets); // AppBar title + nothing else conflicting
    expect(find.text('HOST A TRADE'), findsOneWidget);
    expect(find.text('JOIN A TRADE'), findsOneWidget);
  });

  testWidgets('Menu -> Commune -> Create an Apprenticeship reaches the hub screen', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: MenuScreen()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Commune'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('CREATE AN APPRENTICESHIP'));
    // Deliberately bounded pump()s rather than pumpAndSettle() -- see this
    // file's header comment on ApprenticeshipScreen's FutureBuilder never
    // settling under WidgetTester. A few duration-stepped pumps carry the
    // push-route transition to completion (the AppBar title renders once
    // that finishes, independent of the underlying, never-resolving-here
    // data load) without ever waiting on the stuck Future.
    await tester.pump(); // starts the push transition
    await tester.pump(const Duration(milliseconds: 300)); // transition duration

    expect(find.text('APPRENTICESHIP'), findsOneWidget);
  });

  testWidgets('Menu -> Commune -> Sync Art renders the idle host/join state', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: MenuScreen()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Commune'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('SYNC ART & SOUND'));
    await tester.pumpAndSettle();

    expect(find.text('SYNC ART & SOUND'), findsWidgets); // AppBar title + nothing else conflicting
    expect(find.text('HOST A SYNC'), findsOneWidget);
    expect(find.text('JOIN A SYNC'), findsOneWidget);
  });
}
