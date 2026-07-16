// SPDX-License-Identifier: GPL-3.0-or-later
//
// game_screen_summon_mode_test.dart — end-to-end check that GameScreen's
// Summon-mode toggle swaps FormulaBar for a live creature preview built from
// CreatureSpec.fromElements (design doc "Summons"), using the exact same
// three-stroke seed and step count as game_screen_formula_test.dart (whose
// header documents the trajectory: commits [water, fire, air] after 7 steps).
//
// Expected creature for [water, fire, air]: a 3-way count tie (1 each) ->
// first-appearance tiebreak -> water affinity. Stats are floor(count *
// multiplier) with no minimum floor (design doc "Stats" table): a count of 1
// against multipliers .5/.5/.33 floors to 0 for damage/moveSpeed/attackRange,
// and maxHp is 0 (no earth) -- triggering the 0-HP summon warning. No 4-long
// ability pattern fits a 3-element sequence.

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/engine/hex_grid.dart' show HexCoord;
import 'package:rune_duel/main.dart';
import 'package:rune_duel/ui/formula_bar.dart';
import 'package:rune_duel/ui/hex_grid_painter.dart';

void main() {
  Future<void> drawAndStepThreeStrokeSeed(WidgetTester tester) async {
    final paintFinder = find.byWidgetPredicate((w) => w is CustomPaint && w.painter is HexGridPainter);
    final canvasSize = tester.getSize(paintFinder);
    final canvasTopLeft = tester.getTopLeft(paintFinder);
    final hexSize = (tester.widget<CustomPaint>(paintFinder).painter as HexGridPainter).hexSize;
    final center = Offset(canvasSize.width / 2, canvasSize.height / 2);

    Future<void> tapHex(HexCoord coord) async {
      final local = Offset(
        center.dx + hexSize * (3 / 2 * coord.q),
        center.dy + hexSize * (sqrt(3) / 2 * coord.q + sqrt(3) * coord.r),
      );
      await tester.tapAt(canvasTopLeft + local);
      await tester.pump();
    }

    await tapHex(const HexCoord(7, 0));
    await tapHex(const HexCoord(8, 0));
    await tapHex(const HexCoord(6, -6));
    await tapHex(const HexCoord(7, -7));
    await tapHex(const HexCoord(0, -6));
    await tapHex(const HexCoord(0, -7));
    await tester.pump();

    final stepButton = find.text('Step');
    for (var i = 0; i < 7; i++) {
      await tester.tap(stepButton);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
    }
  }

  testWidgets('Incantation mode (default) shows FormulaBar, no creature preview', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: GameScreen()));
    await tester.pump();

    expect(find.byType(FormulaBar), findsOneWidget);
    expect(find.textContaining('Creature ·'), findsNothing);
  });

  testWidgets('toggling Summon mode swaps FormulaBar for a live creature preview', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: GameScreen()));
    await tester.pump();

    // Scope to TextButton so this doesn't collide with the preview's own
    // "Summon" section label (a plain, non-button Text) once toggled on.
    await tester.tap(find.widgetWithText(TextButton, 'Summon'));
    await tester.pump();

    // Before any activations: void placeholder, not a crash on null spec.
    expect(find.byType(FormulaBar), findsNothing);
    expect(find.textContaining('void: nothing will be summoned'), findsOneWidget);

    await drawAndStepThreeStrokeSeed(tester);

    expect(find.byType(FormulaBar), findsNothing);
    expect(find.textContaining('Water Creature'), findsOneWidget);
    expect(find.textContaining('HP 0'), findsOneWidget);
    expect(find.textContaining('DMG 0'), findsOneWidget);
    expect(find.textContaining('Move 0'), findsOneWidget);
    expect(find.textContaining('Range 0'), findsOneWidget);
    expect(find.textContaining('immediately perish upon summoning'), findsOneWidget);
  });

  testWidgets('toggling back to Incantation restores FormulaBar', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: GameScreen()));
    await tester.pump();

    await tester.tap(find.widgetWithText(TextButton, 'Summon'));
    await tester.pump();
    expect(find.byType(FormulaBar), findsNothing);

    await tester.tap(find.widgetWithText(TextButton, 'Incantation'));
    await tester.pump();
    expect(find.byType(FormulaBar), findsOneWidget);
    expect(find.textContaining('Creature ·'), findsNothing);
  });
}
