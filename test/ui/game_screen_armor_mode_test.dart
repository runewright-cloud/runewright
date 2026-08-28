// SPDX-License-Identifier: GPL-3.0-or-later
//
// game_screen_armor_mode_test.dart — the Rune Craft screen's third mode.
//
// Mirrors game_screen_summon_mode_test.dart: no proving happens here (the real
// prove/persist path for an armor is covered in test/spells/inscribe_test.dart)
// -- this is about the mode bar presenting three choices and each one swapping
// in the right live preview.

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/engine/hex_grid.dart' show HexCoord;
import 'package:rune_duel/main.dart';
import 'package:rune_duel/ui/formula_bar.dart';
import 'package:rune_duel/ui/hex_grid_painter.dart';

void main() {
  Future<void> drawAndStep(WidgetTester tester, int steps) async {
    final paintFinder =
        find.byWidgetPredicate((w) => w is CustomPaint && w.painter is HexGridPainter);
    final canvasSize = tester.getSize(paintFinder);
    final canvasTopLeft = tester.getTopLeft(paintFinder);
    final hexSize =
        (tester.widget<CustomPaint>(paintFinder).painter as HexGridPainter).hexSize;
    final center = Offset(canvasSize.width / 2, canvasSize.height / 2);

    Future<void> tapHex(HexCoord coord) async {
      await tester.tapAt(canvasTopLeft +
          Offset(
            center.dx + hexSize * (3 / 2 * coord.q),
            center.dy + hexSize * (sqrt(3) / 2 * coord.q + sqrt(3) * coord.r),
          ));
      await tester.pump();
    }

    // Same three-stroke seed as game_screen_formula_test.dart.
    await tapHex(const HexCoord(7, 0));
    await tapHex(const HexCoord(8, 0));
    await tapHex(const HexCoord(6, -6));
    await tapHex(const HexCoord(7, -7));
    await tapHex(const HexCoord(0, -6));
    await tapHex(const HexCoord(0, -7));
    await tester.pump();

    for (var i = 0; i < steps; i++) {
      await tester.tap(find.text('Step'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
    }
  }

  testWidgets('the mode bar offers exactly Incantation, Summon and Armor',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: GameScreen()));
    await tester.pump();

    expect(find.text('Incantation'), findsOneWidget);
    expect(find.text('Summon'), findsOneWidget);
    expect(find.text('Armor'), findsOneWidget);
  });

  testWidgets('Incantation is the default and shows the FormulaBar',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: GameScreen()));
    await tester.pump();

    expect(find.byType(FormulaBar), findsOneWidget);
    expect(find.textContaining('Aetherial Armor'), findsNothing);
  });

  testWidgets('Armor mode swaps the FormulaBar for the armor read-out',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: GameScreen()));
    await tester.pump();

    await tester.tap(find.text('Armor'));
    await tester.pump();

    expect(find.byType(FormulaBar), findsNothing);
    expect(find.textContaining('Aetherial Armor'), findsOneWidget);
  });

  testWidgets('Armor mode hides the mana readout; Incantation keeps it',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: GameScreen()));
    await tester.pump();

    expect(find.textContaining('Mana Cost:'), findsOneWidget);

    await tester.tap(find.text('Armor'));
    await tester.pump();
    expect(find.textContaining('Mana Cost:'), findsNothing);

    await tester.tap(find.text('Incantation'));
    await tester.pump();
    expect(find.textContaining('Mana Cost:'), findsOneWidget);
  });

  testWidgets('the armor read-out counts every generation the CA has stepped',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: GameScreen()));
    await tester.pump();

    await tester.tap(find.text('Armor'));
    await tester.pump();
    // T=0 costs nothing until the first generation is stepped.
    expect(find.textContaining('T 0  ·  0 artifact slots'), findsOneWidget);

    await drawAndStep(tester, 7);
    // ceil(7/4) = 2.
    expect(find.textContaining('T 7  ·  2 artifact slots'), findsOneWidget);
    // The element tally is present and is a per-generation count, not the
    // compressed formula view.
    expect(find.textContaining('F '), findsWidgets);
  });

  testWidgets('switching to Armor keeps no summon-only controls on screen',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: GameScreen()));
    await tester.pump();
    await drawAndStep(tester, 5);

    await tester.tap(find.text('Summon'));
    await tester.pump();
    // In Summon mode the preview names the creature it would summon; the
    // mode-bar button is a separate 'Summon' Text, hence findsNWidgets(2).
    expect(find.text('Summon'), findsNWidgets(2));

    await tester.tap(find.text('Armor'));
    await tester.pump();
    // Only the mode-bar button is left: the creature preview is gone.
    expect(find.text('Summon'), findsOneWidget);
    expect(find.byType(FormulaBar), findsNothing);
    expect(find.textContaining('Aetherial Armor'), findsOneWidget);
  });

  testWidgets('the name prompt names an Armor, not a Spell', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: GameScreen()));
    await tester.pump();
    await tester.tap(find.text('Armor'));
    await tester.pump();
    await drawAndStep(tester, 1);

    await tester.tap(find.text('Inscribe'));
    await tester.pumpAndSettle();

    expect(find.text('Name Your Armor'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
  });
}
