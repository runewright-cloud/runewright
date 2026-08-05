// SPDX-License-Identifier: GPL-3.0-or-later
//
// practice_spell_drill_test.dart — widget tests for PracticeScreen's
// spell-drill mode (the library's "Practice Incantation" destination).
//
// Covers the three things that make a drill a *recall* exercise rather than a
// reading one: the spell's own incantation is loaded (not a random formula),
// the formula-count chips are gone (length is a property of the spell), and
// the words start concealed until the player asks to see them.
//
// Scoring itself is not exercised here — that needs a mic and lives in
// test/practice/real_template_e2e_test.dart.

import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/spells/spell_asset.dart';
import 'package:rune_duel/ui/practice_screen.dart';

import '../spells/fake_path_provider.dart';

SpellAsset _spell({
  String name = 'Ember Wake',
  List<String> formula = const ['fire', 'earth', 'water'],
}) =>
    SpellAsset(
      id: 'spell-1',
      createdAt: DateTime.utc(2026, 8, 3),
      tier: 12,
      t: 5,
      ownerPubkeyHex: '0x1234abcd',
      manaCost: 42,
      segmentCount: 3,
      dotCount: 1,
      initialGrid: List<int>.filled(469, 0)..[234] = 1,
      proofBytes: Uint8List.fromList([1, 2, 3]),
      name: name,
      commitmentHex: '0xaabbcc',
      spellHashHex: '0xddeeff',
      formula: formula,
    );

// The enrollment card at the top of the Vocal tab lists all five word names
// too, so bare find.text('ignis') would match it. Scope word assertions to
// the formula's chips: revealed words are InputChips (tappable, they play the
// model clip), concealed ones are plain Chips.
Finder _revealedWord(String word) => find.descendant(
      of: find.byType(InputChip),
      matching: find.text(word),
    );

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await installFakePathProvider();
  });

  tearDown(() async {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Future<void> pumpDrill(WidgetTester tester, SpellAsset spell) async {
    // initState reads the enrollment directory and the five words' reference
    // template assets before the formula is installed — real file and bundle
    // I/O, which never completes under testWidgets' fake-async clock. Pumping
    // the widget *inside* runAsync starts that chain on the real event loop
    // so it can finish; without this the drill silently never loads (the
    // first test in a file happens to pass, later ones don't).
    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(home: PracticeScreen(spell: spell)));
      await Future<void>.delayed(const Duration(milliseconds: 400));
    });
    await tester.pumpAndSettle();
  }

  // The drill controls sit below the enrollment, strictness and calibration
  // cards, so at the default 800x600 test surface they start off-screen —
  // tapping without scrolling first dispatches the pointer at coordinates
  // outside the viewport and silently hits nothing.
  //
  // The trailing runAsync window is for Start Over, which rebuilds the scorer
  // and so re-reads the template assets — same real-I/O-under-fake-async
  // problem pumpDrill works around.
  Future<void> tapVisible(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(finder);
      await Future<void>.delayed(const Duration(milliseconds: 400));
    });
    await tester.pumpAndSettle();
  }

  testWidgets('titles the screen with the spell being drilled', (tester) async {
    await pumpDrill(tester, _spell(name: 'Ember Wake'));
    expect(find.text('Practice — Ember Wake'), findsOneWidget);
  });

  testWidgets('hides the formula-count chips in drill mode', (tester) async {
    await pumpDrill(tester, _spell());
    expect(find.text('Formulas: '), findsNothing);
    // "New Formula" would imply a different spell; drill mode re-runs this one.
    expect(find.text('New Formula'), findsNothing);
    expect(find.text('Start Over'), findsOneWidget);
  });

  testWidgets('conceals the words until revealed', (tester) async {
    await pumpDrill(tester, _spell(formula: ['fire', 'earth', 'water']));

    // One opener + three element words, ALL concealed. Unlike the retired
    // `finitus`, the opener is one of two and so carries real recall
    // information (VOCAL_RECALL_PLAN.md §8.5).
    expect(find.text('? ? ?'), findsNWidgets(4));
    expect(_revealedWord('ignis'), findsNothing);
    expect(_revealedWord('terra'), findsNothing);
    expect(_revealedWord('aqua'), findsNothing);
    expect(_revealedWord('reformare'), findsNothing);

    await tapVisible(tester, find.text('Reveal words'));

    expect(find.text('? ? ?'), findsNothing);
    expect(_revealedWord('reformare'), findsOneWidget);
    expect(_revealedWord('ignis'), findsOneWidget);
    expect(_revealedWord('terra'), findsOneWidget);
    expect(_revealedWord('aqua'), findsOneWidget);
    expect(
      find.text('Answer revealed — start over for a clean attempt.'),
      findsOneWidget,
    );
  });

  testWidgets('Start Over re-conceals the words', (tester) async {
    await pumpDrill(tester, _spell());

    await tapVisible(tester, find.text('Reveal words'));
    expect(_revealedWord('ignis'), findsOneWidget);

    await tapVisible(tester, find.text('Start Over'));

    expect(find.text('? ? ?'), findsNWidgets(4));
    expect(_revealedWord('ignis'), findsNothing);
    expect(
      find.text('Answer revealed — start over for a clean attempt.'),
      findsNothing,
    );
  });

  testWidgets('drops residual activations that complete no triplet',
      (tester) async {
    // 5 activations = one complete formula + 2 residuals. The residuals form
    // no formula and resolve to no effect, so the drill must not ask for them.
    await pumpDrill(
      tester,
      _spell(formula: ['fire', 'earth', 'water', 'air', 'fire']),
    );
    // One opener + the one complete triplet; the 2 residuals are dropped.
    expect(find.text('? ? ?'), findsNWidgets(4));
  });

  testWidgets('main-menu mode keeps the random-formula controls',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: PracticeScreen()));
    await tester.pumpAndSettle();

    expect(find.text('Practice'), findsOneWidget);
    expect(find.text('Formulas: '), findsOneWidget);
    expect(find.text('New Formula'), findsOneWidget);
    expect(find.text('Start Over'), findsNothing);
    // No formula is loaded until the player presses New Formula.
    expect(find.text('? ? ?'), findsNothing);
  });
}
