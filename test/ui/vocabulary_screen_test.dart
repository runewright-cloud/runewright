// SPDX-License-Identifier: GPL-3.0-or-later
//
// vocabulary_screen_test.dart — VocabularyScreen (lib/ui/vocabulary_screen.dart).
//
// What matters here is §8.8's atomicity: a half-finished re-key must never
// become live. So the tests are mostly about what the screen REFUSES to do —
// commit before every changed word has been recorded, and leave staged audio
// attached to a word the player has since retyped.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/sorcerer/vocabulary_profile.dart';
import 'package:rune_duel/sorcerer/vocal_slot.dart';
import 'package:rune_duel/ui/vocabulary_screen.dart';

import '../spells/fake_path_provider.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await installFakePathProvider();
  });

  tearDown(() async {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  // initState does real file I/O (profile load, enrollment open, clearing the
  // staging dir), which never completes under testWidgets' fake-async clock.
  // Pump inside runAsync or only the first test in the file passes — the same
  // trap PracticeScreen has.
  Future<void> pumpScreen(WidgetTester tester) async {
    // Six slots plus the separation card and the commit button do not fit the
    // default 800x600 surface, and a ListView does not inflate children it
    // never lays out — so off-screen rows are genuinely ABSENT from the tree,
    // not merely invisible, and every finder for them fails.
    await tester.binding.setSurfaceSize(const Size(1000, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.runAsync(() async {
      await tester.pumpWidget(const MaterialApp(home: VocabularyScreen()));
      // Real elapsed time, not a pump: initState's chain (profile load,
      // enrollment open, clearing the staging dir) is real file I/O, and
      // pumping only advances the fake clock it never consults.
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await tester.pump();
    });
    await tester.pump();
  }

  testWidgets('opens on the shipped Latin defaults', (tester) async {
    await pumpScreen(tester);
    for (final slot in VocalSlot.values) {
      expect(
        find.widgetWithText(TextField, slot.defaultWord),
        findsOneWidget,
        reason: '${slot.name} should show its default word',
      );
    }
  });

  testWidgets('offers nothing to save until a word is edited', (tester) async {
    await pumpScreen(tester);
    expect(find.text('No changes'), findsOneWidget);
    final button = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(button.onPressed, isNull);
  });

  testWidgets('a changed word cannot be saved until it is recorded',
      (tester) async {
    await pumpScreen(tester);
    await tester.enterText(
      find.widgetWithText(TextField, 'ignis'),
      'blaze',
    );
    await tester.pump();

    // This is the atomicity guarantee: the commit stays disabled while any
    // changed slot has no audio, so a duel can never see half a vocabulary.
    expect(find.textContaining('Record 1 more word'), findsOneWidget);
    final button = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(button.onPressed, isNull);
  });

  testWidgets('a too-short word is refused with a reason', (tester) async {
    await pumpScreen(tester);
    await tester.enterText(find.widgetWithText(TextField, 'ignis'), 'ig');
    await tester.pump();
    expect(find.textContaining('at least'), findsOneWidget);
  });

  testWidgets('two slots cannot share one word', (tester) async {
    await pumpScreen(tester);
    await tester.enterText(find.widgetWithText(TextField, 'ignis'), 'aqua');
    await tester.pump();
    expect(find.textContaining('same word'), findsOneWidget);
  });

  testWidgets('Revert puts the live words back', (tester) async {
    await pumpScreen(tester);
    await tester.enterText(find.widgetWithText(TextField, 'ignis'), 'blaze');
    await tester.pump();
    expect(find.widgetWithText(TextField, 'blaze'), findsOneWidget);

    await tester.runAsync(() async {
      await tester.tap(find.text('Revert'));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await tester.pump();
    });
    await tester.pump();

    expect(find.widgetWithText(TextField, 'ignis'), findsOneWidget);
    expect(find.text('No changes'), findsOneWidget);
  });

  testWidgets('nothing is written to the live profile before committing',
      (tester) async {
    await pumpScreen(tester);
    await tester.enterText(find.widgetWithText(TextField, 'ignis'), 'blaze');
    await tester.pump();

    await tester.runAsync(() async {
      final stored = await VocabularyProfile.load();
      expect(stored.labelFor(VocalSlot.fire), 'ignis',
          reason: 'editing must stage, never write through');
    });
  });
}
