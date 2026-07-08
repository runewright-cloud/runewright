// SPDX-License-Identifier: GPL-3.0-or-later
//
// game_screen_formula_test.dart — end-to-end check that GameScreen's
// FormulaBar reflects FormulaTracker's three-rule cascade (formula.dart)
// on a real seed, not just synthetic (zone, supreme) sequences
// (formula_test.dart already covers the cascade rules in isolation).
//
// Reuses the three-stroke seed from
// game_screen_dominance_characterization_test.dart, whose dominant
// trajectory was re-verified directly against CAStep.step/advanceDominance
// after 42c75c6's water-rule revision (see that file's notes for why the
// trajectory differs from an earlier baseline):
//   gen1-3: neutral (no border contact yet)
//   gen4:   dominant=Water, supreme=true  -> lead change -> add water
//   gen5:   water/air tied for the lead   -> tie -> nothing, lastDominant
//           resets to null (A3)
//   gen6:   dominant=Fire (sole leader, not supreme) -> lead change
//           (null -> fire) -> add fire
//   gen7:   dominant=Wind(air), supreme=true -> lead change -> add air
// So the cascade should commit exactly [water, fire, air] -- one complete
// formula group, no residuals -- after 7 generations.

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/engine/border_zone.dart';
import 'package:rune_duel/engine/hex_grid.dart' show HexCoord;
import 'package:rune_duel/main.dart';
import 'package:rune_duel/ui/formula_bar.dart';
import 'package:rune_duel/ui/hex_grid_painter.dart';

void main() {
  testWidgets('three-zone seed commits water, fire, air as one complete formula group', (tester) async {
    // Avoid pumpAndSettle: the supreme banner runs a perpetually-repeating
    // pulse AnimationController once mounted, which pumpAndSettle can
    // never observe as settled (see the dominance characterization test
    // for the same note). Bounded pumps only.
    await tester.pumpWidget(const MaterialApp(home: GameScreen()));
    await tester.pump();

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

    final formulaBar = find.byType(FormulaBar);
    expect(formulaBar, findsOneWidget);

    // FormulaBar labels air "Air" (distinct from RuleBar's "Wind" for the
    // same zone), but "Fire"/"Water"/"Earth" collide with RuleBar's preset
    // button labels, so scope every lookup to inside FormulaBar.
    expect(find.descendant(of: formulaBar, matching: find.text('Water')), findsOneWidget);
    expect(find.descendant(of: formulaBar, matching: find.text('Air')), findsOneWidget);
    expect(find.descendant(of: formulaBar, matching: find.text('Fire')), findsOneWidget);
    expect(find.descendant(of: formulaBar, matching: find.text('Earth')), findsNothing,
        reason: 'earth never led or pulsed in this trajectory -- it must not appear');

    // The FormulaBar widget itself confirms the grouping/shape directly.
    final bar = tester.widget<FormulaBar>(formulaBar);
    expect(bar.formulas, equals([[BorderZone.water, BorderZone.fire, BorderZone.air]]),
        reason: 'exactly 3 commits, in commit order -> one complete group, no residuals');
    expect(bar.residuals, isEmpty);
    expect(bar.pendingZone, isNull, reason: 'gen7 (air) was itself just committed via the lead change');
  });
}
