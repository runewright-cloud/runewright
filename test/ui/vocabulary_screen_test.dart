// SPDX-License-Identifier: GPL-3.0-or-later
//
// vocabulary_screen_test.dart — VocabularyScreen, the "Attune Spell
// Components" page (lib/ui/vocabulary_screen.dart).
//
// What matters here is §8.8's atomicity: a half-finished re-key must never
// become live. So the tests are mostly about what the screen REFUSES to do —
// commit before every changed word has been recorded, and leave staged audio
// attached to a word the player has since retyped.
//
// The Somatic tab gets a shallow pass only (it is there, it opens, it carries
// the gesture capture controls) — the gesture pipeline's real gate is the
// confusion matrix in test/sorcerer/gesture_confusion_e2e_test.dart, and
// enrollment itself is covered in test/practice/gesture_enrollment_test.dart.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/practice/gesture_enrollment.dart';
import 'package:rune_duel/sorcerer/vocabulary_profile.dart';
import 'package:rune_duel/sorcerer/vocal_enrollment.dart';
import 'package:rune_duel/sorcerer/vocal_slot.dart';
import 'package:rune_duel/spells/spell_asset.dart';
import 'package:rune_duel/ui/vocabulary_screen.dart';
import 'package:rune_duel/ui/widgets/hold_to_record_control.dart';

import '../spells/fake_path_provider.dart';

SpellAsset _spell() => SpellAsset(
      id: 'spell-1',
      createdAt: DateTime.utc(2026, 8, 6),
      tier: 12,
      t: 5,
      ownerPubkeyHex: '0x1234abcd',
      manaCost: 42,
      segmentCount: 3,
      dotCount: 1,
      initialGrid: List<int>.filled(469, 0)..[234] = 1,
      proofBytes: Uint8List.fromList([1, 2, 3]),
      name: 'Ember Wake',
      commitmentHex: '0xaabbcc',
      spellHashHex: '0xddeeff',
      formula: const ['fire', 'earth', 'water'],
    );

/// Writes [takes] dummy exemplars for every slot straight into the enrollment
/// directory under [tempDir]. Going through `saveFromRecording` would need real
/// audio through a mic; only the COUNT matters to the practice gate, and the
/// file format is two fields wide (vocal_enrollment.dart `_writeTakes`).
///
/// SYNCHRONOUS on purpose, and the path is spelled out rather than resolved via
/// `VocalEnrollment.open()`: this runs in a testWidgets body, under fake async,
/// where awaiting real dart:io never completes and the whole run hangs with no
/// output. `docs/` and `practice_enrollment/` mirror fake_path_provider.dart
/// and VocalEnrollment.open respectively — if either moves, this moves too.
void seedEnrollment(Directory tempDir, int takes) {
  final dir = Directory('${tempDir.path}/docs/practice_enrollment')
    ..createSync(recursive: true);
  for (final slot in VocalSlot.values) {
    File('${dir.path}/${slot.storageKey}.json').writeAsStringSync(jsonEncode({
      'label': slot.defaultWord,
      'takes': List.generate(
          takes, (_) => List.generate(25, (_) => List.filled(13, 0.0))),
    }));
  }
}

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
  Future<void> pumpScreen(WidgetTester tester, {SpellAsset? gateFor}) async {
    // Six slots plus the separation card and the commit button do not fit the
    // default 800x600 surface, and a ListView does not inflate children it
    // never lays out — so off-screen rows are genuinely ABSENT from the tree,
    // not merely invisible, and every finder for them fails.
    await tester.binding.setSurfaceSize(const Size(1000, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(
          home: VocabularyScreen(proceedToPracticeWith: gateFor)));
      // Real elapsed time, not a pump: initState's chain (profile load,
      // enrollment open, clearing the staging dir) is real file I/O, and
      // pumping only advances the fake clock it never consults.
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await tester.pump();
    });
    await tester.pump();
  }

  testWidgets('opens on the Vocal tab of the attunement page', (tester) async {
    await pumpScreen(tester);
    expect(find.text('Attune Spell Components'), findsOneWidget);
    expect(find.widgetWithText(Tab, 'Vocal'), findsOneWidget);
    expect(find.widgetWithText(Tab, 'Somatic'), findsOneWidget);
    // Vocal is where a practice gate sends a player and where unsaved work
    // lives, so it is always the tab in front.
    expect(find.widgetWithText(TextField, 'ignis'), findsOneWidget);
  });

  testWidgets('the Somatic tab carries the gesture capture controls',
      (tester) async {
    await pumpScreen(tester);
    // The panel opens its own enrollment directory on first build — real file
    // I/O, so the tap has to land inside runAsync like every other pump here.
    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(Tab, 'Somatic'));
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await tester.pump();
    });
    await tester.pumpAndSettle();

    for (final label in ['Fire', 'Air', 'Water', 'Earth', 'Melee']) {
      expect(find.widgetWithText(HoldToRecordButton, label), findsOneWidget,
          reason: '$label should have a hold-to-record control');
    }
    // The confusables are what make the accept threshold settable at all —
    // if they ever quietly vanish from this page the calibration is unusable.
    for (final confusable in GestureConfusable.values) {
      expect(find.widgetWithText(HoldToRecordButton, confusable.name),
          findsOneWidget);
    }
    expect(find.widgetWithText(HoldToRecordButton, 'Hold to test'),
        findsOneWidget);
    // Same suggested-count treatment as the Vocal tab. The gestures ask for
    // GestureEnrollment.suggestedReps; the confusables ask for more, because
    // they have to cover everything a duel might mistake for a cast.
    expect(find.text('0 of ${GestureEnrollment.suggestedReps} attunements'),
        findsNWidgets(5));
    expect(
        find.text(
            '0 of ${GestureEnrollment.corpusRepsForCalibration} attunements'),
        findsNWidgets(GestureConfusable.values.length));
  });

  testWidgets('suggests a number of attunements per word, with no ceiling',
      (tester) async {
    seedEnrollment(tempDir, 1);
    await pumpScreen(tester);
    // Progress toward the suggestion is shown on every row, not just rows
    // being edited — a count only guides a player if it is visible before
    // they have a reason to look for it.
    expect(find.text('1 of ${VocalEnrollment.suggestedTakes} attunements'),
        findsNWidgets(VocalSlot.values.length));
    expect(find.textContaining('no upper limit'), findsOneWidget);
  });

  testWidgets('drops the progress denominator once a word is well attuned',
      (tester) async {
    // At or past the suggestion there is nothing to count toward — the cap is
    // a rolling window, not a target, so continuing to show "N of 4" would
    // read as a limit the player is pushing against.
    seedEnrollment(tempDir, VocalEnrollment.suggestedTakes);
    await pumpScreen(tester);
    expect(find.text('${VocalEnrollment.suggestedTakes} attunements'),
        findsNWidgets(VocalSlot.values.length));
    expect(find.textContaining('of ${VocalEnrollment.suggestedTakes} attune'),
        findsNothing);
  });

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

  // ── Practice gate (library › Practice Incantation, under-enrolled) ────────

  testWidgets('explains why practice sent the player here', (tester) async {
    await pumpScreen(tester, gateFor: _spell());
    expect(find.textContaining('Before you can practise'), findsOneWidget);
    expect(find.text('Save and proceed to practice'), findsOneWidget);
  });

  testWidgets('will not proceed to practice while words are under-recorded',
      (tester) async {
    // One take each: enough to be "enrolled", short of the drill's threshold.
    seedEnrollment(tempDir, VocalEnrollment.minTakesForPractice - 1);
    await pumpScreen(tester, gateFor: _spell());

    // This is the gate: practising against templates the scorer can't
    // separate would report mistakes the player did not make.
    expect(find.textContaining('recordings of each word'), findsOneWidget);
    final button = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(button.onPressed, isNull);
  });

  testWidgets('unlocks once every word meets the threshold', (tester) async {
    seedEnrollment(tempDir, VocalEnrollment.minTakesForPractice);
    await pumpScreen(tester, gateFor: _spell());

    expect(find.textContaining('recordings of each word'), findsNothing);
    // Nothing was edited, so there is nothing to write — but the gate is
    // satisfied by what is already on disk, and the button's job in gate mode
    // is to reach the drill. Disabling it here would strand the player.
    final button = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(button.onPressed, isNotNull);
  });
}
