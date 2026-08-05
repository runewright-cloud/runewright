// SPDX-License-Identifier: GPL-3.0-or-later
//
// settings_avatar_section_test.dart — the Settings screen's Avatar card
// (docs/AVATAR_PICKER_PLAN.md §5.4): renders, opens the picker on "Change",
// and a chosen id survives Identity.saveAvatarId → loadAvatarId.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/identity/identity.dart';
import 'package:rune_duel/ui/settings_screen.dart';

import '../identity/fake_secure_storage.dart';
import '../spells/fake_path_provider.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    installFakeSecureStorage();
    // SettingsScreen's own _load reads via path_provider
    // — without this mock the plugin channel call never resolves under the
    // headless test engine and pumpAndSettle hangs, same as
    // credits_screen_test.dart's identical requirement for this screen.
    tempDir = await installFakePathProvider();
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  testWidgets('renders with the deterministic default before any choice is made',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SettingsScreen()));
    await tester.pumpAndSettle();

    expect(find.text('Avatar'), findsOneWidget);
    expect(find.text('Default'), findsOneWidget);
    expect(find.text('Change'), findsOneWidget);
  });

  testWidgets('choosing an avatar in the picker updates the card and persists',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SettingsScreen()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Change'));
    await tester.pumpAndSettle();

    // The picker screen is open.
    expect(find.text('Choose Avatar'), findsOneWidget);

    await tester.tap(find.text('Fighter F 01'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Choose'));
    await tester.pumpAndSettle();

    // Back on Settings, the card reflects the choice.
    expect(find.text('Fighter F 01'), findsOneWidget);

    // And it survives a fresh load — the round-trip the plan asks for.
    expect(await Identity.loadAvatarId(), 'fighter_f_01');
  });
}
