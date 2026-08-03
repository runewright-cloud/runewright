// SPDX-License-Identifier: GPL-3.0-or-later
//
// game_screen_drag_paint_test.dart — checks that dragging a finger across the
// grid activates every hex the drag path crosses (not just the two cells the
// pointer happened to land on at gesture start/end), and that a single tap
// still toggles as before.

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
    // Only two moveTo calls (skipping past `mid`) -- this exercises the
    // path-interpolation in _activateAlongPath, not just point sampling.
    await gesture.moveTo(canvasTopLeft + localFor(end));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    final grid = gridNow();
    expect(grid.cells[start], Element.alive);
    expect(grid.cells[mid], Element.alive, reason: 'cell between the two touch points should be filled in by interpolation');
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
