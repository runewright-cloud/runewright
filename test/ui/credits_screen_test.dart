// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/spells/spell_art_pack.dart';
import 'package:rune_duel/spells/spell_sound_pack.dart';
import 'package:rune_duel/ui/about_screen.dart';
import 'package:rune_duel/ui/credits_screen.dart';
import 'package:rune_duel/ui/settings_screen.dart';

import '../spells/fake_path_provider.dart';

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

  testWidgets('renders Runewright\'s own licence statement and the art pack attribution',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: CreditsScreen()));

    expect(find.textContaining('GPL-3.0'), findsOneWidget);
    expect(find.textContaining('CC BY-SA 4.0'), findsWidgets);
    // Appears twice by design -- the compact "Author" row and the full
    // Attribution row from kPainterlyLicence.
    expect(find.textContaining('J. W. Bjerk'), findsWidgets);
    expect(find.textContaining(kPainterlyLicence.modifications), findsOneWidget);
    for (final url in kPainterlyLicence.sourceUrls) {
      expect(find.text(url), findsOneWidget);
    }
  });

  testWidgets('renders the sound pack attribution', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: CreditsScreen()));

    expect(find.textContaining('p0ss'), findsWidgets);
    expect(find.textContaining(kSpellSoundLicence.modifications), findsOneWidget);
    for (final url in kSpellSoundLicence.sourceUrls) {
      expect(find.text(url), findsOneWidget);
    }
  });

  // CC BY 3.0 makes this credit a licence condition, not a courtesy — a build
  // that ships assets/art_pack/avatars/ without it is out of compliance.
  testWidgets('renders the required wizard sprite attribution', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: CreditsScreen()));

    expect(find.textContaining('Svetlana Kushnariova'), findsOneWidget);
    expect(find.textContaining('CC BY 3.0'), findsOneWidget);
    expect(find.textContaining('24x32 characters'), findsOneWidget);
    // CC BY 3.0 §4(a) also requires the derivative to be identified as such.
    expect(find.textContaining('colour key'), findsOneWidget);
  });

  testWidgets('renders the Piper voice model credit', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: CreditsScreen()));

    expect(find.textContaining('Piper'), findsWidgets);
    expect(find.textContaining('it_IT-paola-medium'), findsOneWidget);
  });

  testWidgets(
      'Settings screen has a Credits & Licences entry that opens the About '
      'screen on its Credits tab', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SettingsScreen()));
    await tester.pumpAndSettle();

    // The Avatar section (docs/AVATAR_PICKER_PLAN.md §5.4) now leads the
    // list, pushing this entry below the fold — scroll it into view first.
    await tester.dragUntilVisible(
      find.text('Credits & Licences'),
      find.byType(ListView),
      const Offset(0, -200),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Credits & Licences'));
    await tester.pumpAndSettle();

    final about = tester.widget<AboutScreen>(find.byType(AboutScreen));
    expect(about.initialTab, 1);
    expect(find.byType(CreditsScreen), findsOneWidget);
  });
}
