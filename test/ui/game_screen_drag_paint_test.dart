// SPDX-License-Identifier: GPL-3.0-or-later
//
// game_screen_drag_paint_test.dart — checks that a drag along a hex spoke
// fills in the cells between the pointer's samples (not just the two it
// happened to land on), and that a single tap still toggles as before.
//
// Drags are normalized to straight lines now, so the gap-filling here is a
// property of the line rather than of path interpolation -- see
// game_screen_straight_line_drag_test.dart for the normalization itself.

import 'dart:math';

import 'package:flutter/material.dart' hide Element;
import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/engine/element.dart';
import 'package:rune_duel/engine/hex_grid.dart' show HexCoord, HexGrid;
import 'package:rune_duel/main.dart';
import 'package:rune_duel/ui/hex_grid_painter.dart';

void main() {
  testWidgets('dragging across the grid activates the cells in its path', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: GameScreen()));
    await tester.pump();

    final paintFinder = find.byWidgetPredicate((w) => w is CustomPaint && w.painter is HexGridPainter);
    final canvasSize = tester.getSize(paintFinder);
    final canvasTopLeft = tester.getTopLeft(paintFinder);
    final hexSize = (tester.widget<CustomPaint>(paintFinder).painter as HexGridPainter).hexSize;
    final center = Offset(canvasSize.width / 2, canvasSize.height / 2);

    Offset localFor(HexCoord coord) => Offset(
          center.dx + hexSize * (3 / 2 * coord.q),
          center.dy + hexSize * (sqrt(3) / 2 * coord.q + sqrt(3) * coord.r),
        );

    const start = HexCoord(-4, 0);
    const mid = HexCoord(0, 0);
    const end = HexCoord(4, 0);

    HexGrid gridNow() =>
        (tester.widget<CustomPaint>(paintFinder).painter as HexGridPainter).grid;

    // Sanity: none of these are active before the drag.
    expect(gridNow().cells[start], Element.dead);
    expect(gridNow().cells[mid], Element.dead);
    expect(gridNow().cells[end], Element.dead);

    final gesture = await tester.startGesture(canvasTopLeft + localFor(start));
    await tester.pump();
    // One moveTo, skipping past `mid` entirely: the stroke is derived from
    // the anchor and the touch point, so `mid` is filled because it lies on
    // the line, not because the pointer was sampled there.
    await gesture.moveTo(canvasTopLeft + localFor(end));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    final grid = gridNow();
    expect(grid.cells[start], Element.alive);
    expect(grid.cells[mid], Element.alive, reason: 'cell between the two touch points lies on the line and must be filled');
    expect(grid.cells[end], Element.alive);
  });

  testWidgets('a plain tap still toggles a single cell', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: GameScreen()));
    await tester.pump();

    final paintFinder = find.byWidgetPredicate((w) => w is CustomPaint && w.painter is HexGridPainter);
    final canvasSize = tester.getSize(paintFinder);
    final canvasTopLeft = tester.getTopLeft(paintFinder);
    final hexSize = (tester.widget<CustomPaint>(paintFinder).painter as HexGridPainter).hexSize;
    final center = Offset(canvasSize.width / 2, canvasSize.height / 2);

    const coord = HexCoord(2, -2);
    final local = Offset(
      center.dx + hexSize * (3 / 2 * coord.q),
      center.dy + hexSize * (sqrt(3) / 2 * coord.q + sqrt(3) * coord.r),
    );

    HexGrid gridNow() =>
        (tester.widget<CustomPaint>(paintFinder).painter as HexGridPainter).grid;

    expect(gridNow().cells[coord], Element.dead);

    await tester.tapAt(canvasTopLeft + local);
    await tester.pump();
    expect(gridNow().cells[coord], Element.alive);

    await tester.tapAt(canvasTopLeft + local);
    await tester.pump();
    expect(gridNow().cells[coord], Element.dead);
  });
}
