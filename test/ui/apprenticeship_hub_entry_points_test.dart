// SPDX-License-Identifier: GPL-3.0-or-later
//
// apprenticeship_hub_entry_points_test.dart — pins the hub screen's two
// pairing entry points (docs/MASTER_APPRENTICE_PLAN.md §6.2).
//
// The regression this exists for: the hub shipped with "OFFER AN
// APPRENTICESHIP" (master role) as the ONLY route into
// ApprenticeOfferScreen for a device with no existing mastership. The
// apprentice role was reachable exclusively via `RENEW`, which renders only
// once a master already exists — so two players forming a FIRST
// apprenticeship could each enter only as master, both send a chapterOffer,
// and both sit on "Awaiting their decision..." forever. Nothing in the
// protocol layer is wrong; the apprentice side simply had no door.
//
// commune_trade_navigation_test.dart's header states this screen's
// FutureBuilder never resolves under WidgetTester. That is true of
// pumpAndSettle() alone; letting the real event loop turn inside
// tester.runAsync() does drain the real dart:io + secure-storage work the
// load depends on, which is what the pump helper below does.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/src/rust/frb_generated.dart';
import 'package:rune_duel/ui/apprentice_offer_screen.dart';
import 'package:rune_duel/ui/apprenticeship_screen.dart';

import '../identity/fake_secure_storage.dart';
import '../spells/fake_path_provider.dart';

/// Mounts the hub and pumps until its FutureBuilder has resolved.
///
/// `pumpWidget` has to happen INSIDE `tester.runAsync` so `initState`'s
/// `_load()` future chain is created in the real zone — created in the
/// fake-async zone instead, its real `dart:io` continuations never get
/// delivered and the screen spins forever (the characteristic recorded in
/// commune_trade_navigation_test.dart's header).
Future<void> _pumpHub(WidgetTester tester) async {
  await tester.runAsync(() async {
    await tester.pumpWidget(const MaterialApp(home: ApprenticeshipScreen()));
    for (var i = 0; i < 40; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await tester.pump();
      if (find.byType(CircularProgressIndicator).evaluate().isEmpty) return;
    }
    fail('ApprenticeshipScreen never finished loading');
  });
  await tester.pump();
}

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

  testWidgets('with no master and no apprentices, BOTH pairing roles are reachable', (tester) async {
    await _pumpHub(tester);

    expect(find.text('OFFER AN APPRENTICESHIP'), findsOneWidget);
    expect(
      find.text('STUDY UNDER A MASTER'),
      findsOneWidget,
      reason: 'without this the apprentice role is unreachable and both peers deadlock as masters',
    );
  });

  testWidgets('"Study under a master" opens the pairing flow as the APPRENTICE', (tester) async {
    await _pumpHub(tester);

    await tester.tap(find.text('STUDY UNDER A MASTER'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300)); // push transition

    final screen = tester.widget<ApprenticeOfferScreen>(find.byType(ApprenticeOfferScreen));
    expect(screen.role, ApprenticeOfferRole.apprentice);
    // The apprentice-side title, not the master's 'OFFER APPRENTICESHIP'
    // (findsWidgets, not findsOneWidget: the hub's button underneath carries
    // the same label, by design — they name the same act).
    expect(find.text('STUDY UNDER A MASTER'), findsWidgets);
    expect(find.text('OFFER APPRENTICESHIP'), findsNothing);
  });

  testWidgets('"Offer an apprenticeship" opens the pairing flow as the MASTER', (tester) async {
    await _pumpHub(tester);

    await tester.tap(find.text('OFFER AN APPRENTICESHIP'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final screen = tester.widget<ApprenticeOfferScreen>(find.byType(ApprenticeOfferScreen));
    expect(screen.role, ApprenticeOfferRole.master);
  });
}
