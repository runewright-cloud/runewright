// SPDX-License-Identifier: GPL-3.0-or-later
//
// game_screen_revert_test.dart — Revert returns the grid to the start of the
// CURRENT simulation, re-snapshotted every time a new one begins.
//
// The snapshot used to be latched on the first run only (`_initialGrid ??=`),
// so revert -> edit the seed -> run again -> Revert handed back the original
// drawing and discarded the edits. That snapshot is also the T=0 grid
// Inscribe certifies and the grid the mana readout is priced from, so a stale
// one meant the proof and the price described a different spell than the
// formula bar on screen -- which is why this is pinned with tests rather than
// left to the UI.

import 'dart:math';

import 'package:flutter/material.dart' hide Element;
import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/engine/element.dart';
import 'package:rune_duel/engine/hex_grid.dart' show HexCoord;
import 'package:rune_duel/main.dart';
import 'package:rune_duel/ui/hex_grid_painter.dart';

class _Screen {
  _Screen(this.tester)
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

  HexGridPainter get _painter =>
      tester.widget<CustomPaint>(_finder).painter as HexGridPainter;

  Set<HexCoord> get alive => _painter.grid.cells.entries
      .where((e) => e.value == Element.alive)
      .map((e) => e.key)
      .toSet();

  int get stepCount => _painter.grid.stepCount;

  Future<void> toggle(HexCoord coord) async {
    await tester.tapAt(
      _topLeft +
          Offset(
            _center.dx + _hexSize * (3 / 2 * coord.q),
            _center.dy + _hexSize * (sqrt(3) / 2 * coord.q + sqrt(3) * coord.r),
          ),
    );
    await tester.pump();
  }

  Future<void> step() async {
    await tester.tap(find.text('Step'));
    await tester.pump();
    // Past the 500ms growth animation and the banner's 400ms switch, without
    // pumpAndSettle (the supreme banner pulses forever once mounted).
    await tester.pump(const Duration(milliseconds: 600));
  }

  Future<void> revert() async {
    await tester.tap(find.byIcon(Icons.undo));
    await tester.pump();
  }

  Future<void> reset() async {
    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pump();
  }

  bool get canRevert =>
      tester.widget<IconButton>(find.ancestor(
        of: find.byIcon(Icons.undo),
        matching: find.byType(IconButton),
      )).onPressed !=
      null;
}

Future<_Screen> _open(WidgetTester tester) async {
  await tester.pumpWidget(const MaterialApp(home: GameScreen()));
  await tester.pump();
  return _Screen(tester);
}

void main() {
  testWidgets('Revert restores the seed the simulation started from', (tester) async {
    final screen = await _open(tester);
    expect(screen.canRevert, isFalse, reason: 'nothing to revert to before the first step');

    // A 2-cell straight stroke: Rule B extends its tip, so stepping visibly
    // changes the grid and a wrong snapshot would be obvious.
    final seed = {const HexCoord(0, 0), const HexCoord(1, 0)};
    for (final cell in seed) {
      await screen.toggle(cell);
    }
    expect(screen.alive, equals(seed));

    await screen.step();
    expect(screen.canRevert, isTrue);
    expect(screen.stepCount, equals(1));

    await screen.revert();
    expect(screen.alive, equals(seed));
    expect(screen.stepCount, equals(0));
  });

  testWidgets('re-running after editing the seed reverts to the NEW seed, not the old one',
      (tester) async {
    final screen = await _open(tester);

    final first = {const HexCoord(0, 0), const HexCoord(1, 0)};
    for (final cell in first) {
      await screen.toggle(cell);
    }
    await screen.step();
    await screen.revert();
    expect(screen.alive, equals(first));

    // Edit the seed: a new stroke drawn elsewhere and one of the originals
    // toggled back off, so the new seed differs from the old in both
    // directions and neither is a subset of the other.
    await screen.toggle(const HexCoord(-4, 0));
    await screen.toggle(const HexCoord(-3, 0));
    await screen.toggle(const HexCoord(1, 0));
    final second = {const HexCoord(0, 0), const HexCoord(-4, 0), const HexCoord(-3, 0)};
    expect(screen.alive, equals(second));

    await screen.step();
    await screen.revert();

    expect(screen.alive, equals(second),
        reason: 'the second run started from `second` -- Revert must not resurrect `first`');
  });

  testWidgets('continuing a run is not a new simulation: the snapshot is not re-taken',
      (tester) async {
    final screen = await _open(tester);

    // A 2-cell straight stroke: Rule B extends its tip, so stepping visibly
    // changes the grid and a wrong snapshot would be obvious.
    final seed = {const HexCoord(0, 0), const HexCoord(1, 0)};
    for (final cell in seed) {
      await screen.toggle(cell);
    }

    await screen.step();
    final afterFirstStep = screen.alive;
    await screen.step();
    await screen.step();
    expect(screen.stepCount, equals(3));

    await screen.revert();
    expect(screen.alive, equals(seed),
        reason: 'steps 2 and 3 continue the same simulation -- they must not '
            're-snapshot the evolved grid');
    expect(screen.alive, isNot(equals(afterFirstStep)),
        reason: 'sanity: the grid really did evolve, so a re-snapshot would be visible');
    expect(screen.stepCount, equals(0));
  });

  testWidgets('Reset drops the snapshot entirely', (tester) async {
    final screen = await _open(tester);

    await screen.toggle(const HexCoord(0, 0));
    await screen.toggle(const HexCoord(1, 0));
    await screen.step();
    expect(screen.canRevert, isTrue);

    await screen.reset();
    expect(screen.alive, isEmpty);
    expect(screen.stepCount, equals(0));
    expect(screen.canRevert, isFalse,
        reason: 'a reset grid has no simulation to revert to');
  });
}
