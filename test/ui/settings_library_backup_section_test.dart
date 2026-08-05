// SPDX-License-Identifier: GPL-3.0-or-later
//
// settings_library_backup_section_test.dart — the Settings screen's Library
// Backup card: renders, and the Import confirm dialog explains the
// additive/no-overwrite behavior before any file is touched. Export/Import
// themselves go through file_picker, which has no platform channel under
// the headless test engine (same reason settings_avatar_section_test.dart
// mocks path_provider/secure storage) -- covered instead by
// test/spells/library_backup_test.dart's real-file-I/O merge tests.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/ui/settings_screen.dart';

import '../identity/fake_secure_storage.dart';
import '../spells/fake_path_provider.dart';

void main() {
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

  testWidgets('renders the Library Backup card with Export/Import buttons', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SettingsScreen()));
    await tester.pumpAndSettle();

    // The card sits below the fold in the settings ListView.
    await tester.drag(find.byType(ListView), const Offset(0, -400));
    await tester.pumpAndSettle();

    expect(find.text('Library Backup'), findsOneWidget);
    expect(find.text('Export'), findsOneWidget);
    expect(find.text('Import'), findsOneWidget);
  });

  testWidgets('tapping Import shows the additive-merge confirmation before touching any file',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SettingsScreen()));
    await tester.pumpAndSettle();

    await tester.drag(find.byType(ListView), const Offset(0, -400));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Import'));
    await tester.pumpAndSettle();

    expect(find.text('Import a library backup?'), findsOneWidget);
    expect(find.textContaining("won't be able to cast them"), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    // Cancelling never reaches the file picker -- the dialog just closes.
    expect(find.text('Import a library backup?'), findsNothing);
  });
}
