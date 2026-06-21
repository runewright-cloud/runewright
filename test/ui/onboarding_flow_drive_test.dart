// SPDX-License-Identifier: GPL-3.0-or-later
//
// onboarding_flow_drive_test.dart — drives the real onboarding widget tree
// (AppRoot -> OnboardingLandingScreen -> RollEntryScreen / BackupPromptScreen
// -> MenuScreen) end to end via WidgetTester taps, the same screens and
// navigation a player would hit. Only the secure-storage platform channel
// is faked (no native Keystore under the headless test engine, see
// fake_secure_storage.dart); everything else -- Ed25519 keygen, the d20
// seed derivation, real Navigator transitions -- runs for real.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/ui/app_root.dart';

import '../identity/fake_secure_storage.dart';

void main() {
  testWidgets('Rite of Four-and-Twenty: landing -> roll entry -> picker -> recorded', (tester) async {
    installFakeSecureStorage();
    await tester.pumpWidget(const MaterialApp(home: AppRoot()));
    await tester.pumpAndSettle();

    expect(find.text('FORGE YOUR RUNEKEY'), findsOneWidget);
    expect(find.text('CREATE NEW (THE RITE OF FOUR-AND-TWENTY)'), findsOneWidget);

    await tester.tap(find.text('CREATE NEW (THE RITE OF FOUR-AND-TWENTY)'));
    await tester.pumpAndSettle();

    expect(find.text('THE RITE OF FOUR-AND-TWENTY'), findsOneWidget);
    expect(find.text('FIRE'), findsOneWidget);
    expect(find.text('WIND'), findsOneWidget);
    expect(find.text('WATER'), findsOneWidget);
    expect(find.text('EARTH'), findsOneWidget);
    expect(find.text('0 / 24 recorded'), findsOneWidget);

    await tester.tap(find.text('—').first);
    await tester.pumpAndSettle();

    expect(find.text('CHOOSE YOUR ROLL (1–20)'), findsOneWidget);
    expect(find.text('1'), findsWidgets);
    expect(find.text('20'), findsOneWidget);

    await tester.tap(find.text('7'));
    await tester.pumpAndSettle();

    expect(find.text('1 / 24 recorded'), findsOneWidget);
    expect(find.text('7'), findsWidgets);
  });

  testWidgets('Auto-create: landing -> backup prompt -> checkbox gates Continue -> menu', (tester) async {
    installFakeSecureStorage();
    await tester.pumpWidget(const MaterialApp(home: AppRoot()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('CREATE NEW (QUICK)'));
    await tester.pumpAndSettle();

    expect(find.text('BACK UP YOUR RUNEKEY'), findsOneWidget);
    expect(find.text('EXPORT ENCRYPTED KEY FILE'), findsOneWidget);
    expect(find.textContaining('You\'ve been warned'), findsOneWidget);

    // Continue is gated until either export succeeds or the risk box is
    // checked -- verify it's a no-op while ungated. (ensureVisible because
    // the short 800x600 test viewport puts it below the fold, same as a
    // real player would scroll to reach it.)
    await tester.ensureVisible(find.text('CONTINUE'));
    await tester.tap(find.text('CONTINUE'));
    await tester.pumpAndSettle();
    expect(find.text('BACK UP YOUR RUNEKEY'), findsOneWidget);

    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('CONTINUE'));
    await tester.tap(find.text('CONTINUE'));
    await tester.pumpAndSettle();

    expect(find.text('RUNE WRIGHT'), findsOneWidget);
    expect(find.text('Rune Craft'), findsOneWidget);
  });

  testWidgets('Back button returns to the landing chooser from all three reachable screens', (tester) async {
    installFakeSecureStorage();
    await tester.pumpWidget(const MaterialApp(home: AppRoot()));
    await tester.pumpAndSettle();
    expect(find.text('FORGE YOUR RUNEKEY'), findsOneWidget);

    // Rolls entry (covers both create-rolls and restore-rolls -- same screen).
    await tester.tap(find.text('CREATE NEW (THE RITE OF FOUR-AND-TWENTY)'));
    await tester.pumpAndSettle();
    expect(find.text('THE RITE OF FOUR-AND-TWENTY'), findsOneWidget);
    await tester.tap(find.text('‹ Back'));
    await tester.pumpAndSettle();
    expect(find.text('FORGE YOUR RUNEKEY'), findsOneWidget);

    // Restore from file.
    await tester.tap(find.text('RESTORE FROM BACKUP FILE'));
    await tester.pumpAndSettle();
    expect(find.text('RESTORE FROM BACKUP FILE'), findsWidgets);
    await tester.tap(find.text('‹ Back'));
    await tester.pumpAndSettle();
    expect(find.text('FORGE YOUR RUNEKEY'), findsOneWidget);

    // Auto-create's backup prompt -- the path that used to pushReplacement
    // over the landing screen (no route left to pop to). Now uses push.
    await tester.tap(find.text('CREATE NEW (QUICK)'));
    await tester.pumpAndSettle();
    expect(find.text('BACK UP YOUR RUNEKEY'), findsOneWidget);
    await tester.tap(find.text('‹ Back'));
    await tester.pumpAndSettle();
    expect(find.text('FORGE YOUR RUNEKEY'), findsOneWidget);
  });
}
