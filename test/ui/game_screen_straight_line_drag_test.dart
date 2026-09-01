// SPDX-License-Identifier: GPL-3.0-or-later
//
// game_screen_straight_line_drag_test.dart — a held drag on the rune-crafting
// grid draws a straight hex line, not a freehand path.
//
// Straight runs are what the ink rules reward (Rule B extends a stroke's tip),
// so players draw a lot of them; normalizing the drag is what makes them easy
// to hit. These tests pin the four things that make the normalization usable
// rather than merely present: it snaps off-axis drags to a spoke, it rotates,
// it retracts, and it never eats ink it didn't draw.

import 'dart:math';

import 'package:flutter/material.dart' hide Element;
import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/engine/element.dart';
import 'package:rune_duel/engine/hex_grid.dart' show HexCoord;
import 'package:rune_duel/main.dart';
import 'package:rune_duel/ui/hex_grid_painter.dart';

// A drag harness over the real GameScreen: hex<->pixel in the same layout the
// painter uses, plus the alive-cell set as the single thing worth asserting on.
class _Grid {
  _Grid(this.tester)
      : _finder = find.byWidgetPredicate(
          (w) => w is CustomPaint && w.painter is HexGridPainter,
        ) {
    final canvasSize = tester.getSize(_finder);
    _topLeft = tester.getTopLeft(_finder);
    _hexSize = (tester.widget<CustomPaint>(_finder).painter as HexGridPainter).hexSize;
    _center = Offset(canvasSize.width / 2, canvasSize.height / 2);
  }

  final WidgetTester tester;
  final Finder _finder;
  late final Offset _topLeft;
  late final double _hexSize;
  late final Offset _center;

  // The pixel distance between two edge-adjacent cells -- the same for all six
  // directions, which is why a single "one step" length is meaningful.
  double get step => _hexSize * sqrt(3);

  Offset at(HexCoord coord) =>
      _topLeft +
      Offset(
        _center.dx + _hexSize * (3 / 2 * coord.q),
        _center.dy + _hexSize * (sqrt(3) / 2 * coord.q + sqrt(3) * coord.r),
      );

  // A point [steps] cell-widths from the center of [from], at [degrees]
  // measured clockwise from screen-right. The six spokes sit at 30 degree
  // multiples offset by 30 (see HexGrid.directions under this layout), so an
  // angle like 10 lands genuinely between two of them.
  Offset ray(HexCoord from, double degrees, double steps) {
    final radians = degrees * pi / 180;
    return at(from) + Offset(cos(radians), sin(radians)) * (steps * step);
  }

  Set<HexCoord> get alive {
    final grid = (tester.widget<CustomPaint>(_finder).painter as HexGridPainter).grid;
    return grid.cells.entries
        .where((e) => e.value == Element.alive)
        .map((e) => e.key)
        .toSet();
  }
}

// The straight line of [length] cells running from [anchor] along [dir].
Set<HexCoord> _line(HexCoord anchor, HexCoord dir, int length) => {
      for (var k = 0; k <= length; k++)
        HexCoord(anchor.q + dir.q * k, anchor.r + dir.r * k),
    };

const _east = HexCoord(1, 0);
const _northEast = HexCoord(1, -1);
const _north = HexCoord(0, -1);
const _origin = HexCoord(0, 0);

Future<_Grid> _openGrid(WidgetTester tester) async {
  await tester.pumpWidget(const MaterialApp(home: GameScreen()));
  await tester.pump();
  return _Grid(tester);
}

void main() {
  testWidgets('an off-axis drag snaps to the nearest spoke and paints only that line',
      (tester) async {
    final grid = await _openGrid(tester);

    // 10 degrees is 20 off the (1,0) spoke and 40 off (1,-1) -- a drag no
    // human would call straight, which must still come out straight.
    final gesture = await tester.startGesture(grid.at(_origin));
    await tester.pump();
    await gesture.moveTo(grid.ray(_origin, 10, 4));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(grid.alive, equals(_line(_origin, _east, 4)),
        reason: 'the stroke must be exactly the snapped line -- nothing beside it, '
            'and nothing left over from the path the finger actually took');
  });

  testWidgets('swinging the finger around the anchor rotates the line rather than smearing',
      (tester) async {
    final grid = await _openGrid(tester);

    final gesture = await tester.startGesture(grid.at(_origin));
    await tester.pump();
    await gesture.moveTo(grid.ray(_origin, 30, 4));
    await tester.pump();
    expect(grid.alive, equals(_line(_origin, _east, 4)));

    // Swing up to the (0,-1) spoke without lifting.
    await gesture.moveTo(grid.ray(_origin, -90, 3));
    await tester.pump();
    expect(grid.alive, equals(_line(_origin, _north, 3)),
        reason: 'the abandoned direction must be released, not kept as a smear');

    await gesture.up();
    await tester.pump();
    expect(grid.alive, equals(_line(_origin, _north, 3)),
        reason: 'lifting commits whatever line was showing');
  });

  testWidgets('sliding back toward the anchor shortens the line', (tester) async {
    final grid = await _openGrid(tester);

    final gesture = await tester.startGesture(grid.at(_origin));
    await tester.pump();
    await gesture.moveTo(grid.ray(_origin, -30, 5));
    await tester.pump();
    expect(grid.alive, equals(_line(_origin, _northEast, 5)));

    await gesture.moveTo(grid.ray(_origin, -30, 2));
    await tester.pump();
    expect(grid.alive, equals(_line(_origin, _northEast, 2)));

    // All the way back: a drag that returns to where it started leaves the
    // one cell it anchored on, never zero.
    await gesture.moveTo(grid.at(_origin));
    await tester.pump();
    expect(grid.alive, equals({_origin}));

    await gesture.up();
    await tester.pump();
  });

  testWidgets('a stroke moving off a cell it did not draw leaves that cell alive',
      (tester) async {
    final grid = await _openGrid(tester);

    // Ink laid down beforehand, sitting on the path the stroke will sweep
    // across. Retraction must put back only what the stroke itself painted.
    await tester.tapAt(grid.at(const HexCoord(2, 0)));
    await tester.pump();
    expect(grid.alive, equals({const HexCoord(2, 0)}));

    final gesture = await tester.startGesture(grid.at(_origin));
    await tester.pump();
    await gesture.moveTo(grid.ray(_origin, 30, 4));
    await tester.pump();
    expect(grid.alive, equals(_line(_origin, _east, 4)));

    await gesture.moveTo(grid.ray(_origin, -90, 2));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(grid.alive, equals({..._line(_origin, _north, 2), const HexCoord(2, 0)}),
        reason: 'the pre-existing cell at (2,0) was never this stroke\'s to erase');
  });

  testWidgets('a line stops at the edge of the inscribable region', (tester) async {
    final grid = await _openGrid(tester);

    // Dragged far enough to run off the radius-8 inscribable area into the
    // buffer ring; the line must stop at the last cell a player may inscribe.
    final gesture = await tester.startGesture(grid.at(const HexCoord(6, 0)));
    await tester.pump();
    await gesture.moveTo(grid.ray(const HexCoord(6, 0), 30, 9));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(grid.alive, equals(_line(const HexCoord(6, 0), _east, 2)),
        reason: 'stops at (8,0) -- the buffer ring is not inscribable');
  });

  testWidgets('a drag that begins outside the inscribable region anchors where it enters',
      (tester) async {
    final grid = await _openGrid(tester);

    // Starts on a buffer cell (radius 10), sweeps inward along the -q spoke.
    final gesture = await tester.startGesture(grid.at(const HexCoord(10, 0)));
    await tester.pump();
    await gesture.moveTo(grid.at(const HexCoord(8, 0)));
    await tester.pump();
    await gesture.moveTo(grid.at(const HexCoord(5, 0)));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(grid.alive, equals(_line(const HexCoord(8, 0), const HexCoord(-1, 0), 3)),
        reason: 'the line anchors on the first inscribable cell the finger reaches');
  });

  testWidgets('dragging does nothing once the simulation has stepped', (tester) async {
    final grid = await _openGrid(tester);

    await tester.tapAt(grid.at(_origin));
    await tester.pump();
    await tester.tap(find.text('Step'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    final before = grid.alive;
    final gesture = await tester.startGesture(grid.at(const HexCoord(-5, 0)));
    await tester.pump();
    await gesture.moveTo(grid.ray(const HexCoord(-5, 0), 30, 3));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(grid.alive, equals(before),
        reason: 'the initial state is frozen once it has been stepped');
  });
}
