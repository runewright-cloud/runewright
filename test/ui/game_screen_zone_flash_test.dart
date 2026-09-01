// SPDX-License-Identifier: GPL-3.0-or-later
//
// game_screen_zone_flash_test.dart — the elemental tracker flashes the
// counter of an element at the moment that element is added to the formula.
//
// This is the screen's only "you earned something" cue now that the ink bar
// is gone: the formula bar grows a chip, but a chip appearing at the end of
// a horizontally-scrolling row is easy to miss mid-run. The flash is what
// ties the two rows together, so it's worth pinning.
//
// _ZoneCounters is private to main.dart, so the flash is observed the only
// way a foreign library can: through the rendered Text's color, which lerps
// from the resting readout grey toward parchment white at the peak.

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/engine/hex_grid.dart' show HexCoord;
import 'package:rune_duel/main.dart';
import 'package:rune_duel/ui/hex_grid_painter.dart';

// No pumpAndSettle: the supreme banner pulses forever once mounted, so it
// never settles (see game_screen_dominance_characterization_test.dart).

const _resting = Color(0xFFB8A898);

Offset _hexScreenPosition(WidgetTester tester, Finder paintFinder, HexCoord coord) {
  final canvasSize = tester.getSize(paintFinder);
  final canvasTopLeft = tester.getTopLeft(paintFinder);
  final hexSize = (tester.widget<CustomPaint>(paintFinder).painter as HexGridPainter).hexSize;
  final center = Offset(canvasSize.width / 2, canvasSize.height / 2);
  return canvasTopLeft +
      Offset(
        center.dx + hexSize * (3 / 2 * coord.q),
        center.dy + hexSize * (sqrt(3) / 2 * coord.q + sqrt(3) * coord.r),
      );
}

Color _counterColor(WidgetTester tester, String label) {
  final text = tester.widgetList<Text>(find.textContaining('$label: ')).first;
  return text.style!.color!;
}

void main() {
  testWidgets('the counter of a newly-earned element flashes, and only that one',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: GameScreen()));
    await tester.pump();

    final paintFinder =
        find.byWidgetPredicate((w) => w is CustomPaint && w.painter is HexGridPainter);

    // Same straight stroke as the dominance characterization test: Water is
    // the only zone touched, and it touches on generation 4 -- a lead change
    // out of neutral, so the formula commits Water on that generation.
    for (final coord in [const HexCoord(7, 0), const HexCoord(8, 0)]) {
      await tester.tapAt(_hexScreenPosition(tester, paintFinder, coord));
      await tester.pump();
    }

    final stepButton = find.text('Step');
    for (var i = 0; i < 3; i++) {
      await tester.tap(stepButton);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(_counterColor(tester, 'Water'), equals(_resting),
          reason: 'nothing has been earned yet -- no counter should be lit');
    }

    // Generation 4: Water reaches the border and is committed.
    await tester.tap(stepButton);
    await tester.pump();
    // 200ms in is the flash's peak (a quarter of its 800ms).
    await tester.pump(const Duration(milliseconds: 200));

    expect(_counterColor(tester, 'Water'), isNot(equals(_resting)),
        reason: 'water was just added to the formula -- its counter must light up');
    for (final other in ['Fire', 'Air', 'Earth']) {
      expect(_counterColor(tester, other), equals(_resting),
          reason: '$other was not earned -- only the earned element flashes');
    }

    // ...and it settles back on its own, without another step.
    await tester.pump(const Duration(milliseconds: 900));
    expect(_counterColor(tester, 'Water'), equals(_resting),
        reason: 'the flash is transient -- it must not leave the counter lit');
  });
}
