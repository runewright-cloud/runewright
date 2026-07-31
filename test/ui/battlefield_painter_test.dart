// SPDX-License-Identifier: GPL-3.0-or-later
//
// Smoke test for BattlefieldPainter's terrain/cloud rendering pass: confirms
// a full set of TileEffect and CloudKind variants paints without throwing.
// This does not assert pixel output (procedural Canvas drawing has no
// snapshot baseline here) -- it exists to catch the paint()-time crash class
// (unhandled variant in a switch, clipPath/save-restore mismatch, etc).
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/battle/models/terrain.dart';
import 'package:rune_duel/engine/hex_grid.dart';
import 'package:rune_duel/ui/battlefield_painter.dart';

void main() {
  testWidgets('paints all TileEffect and CloudKind variants without throwing',
      (tester) async {
    final tileEffects = <HexCoord, TileEffect>{
      const HexCoord(0, 0): const FloorIsLava(),
      const HexCoord(1, 0): const ImpassableTile(),
      const HexCoord(-1, 0): const SlowTile(),
      const HexCoord(0, 1): const ConveyorTile(direction: HexCoord(1, -1)),
      const HexCoord(0, -1): const ConveyorTile(), // direction not yet set
    };

    final clouds = [
      CloudObject(
        id: 'toxic',
        position: const HexCoord(2, 0),
        kind: const ToxicCloud(),
        remainingTurns: 2,
        ownerId: 'p1',
      ),
      CloudObject(
        id: 'dust',
        position: const HexCoord(-2, 0),
        kind: const DustCloud(),
        remainingTurns: 1,
        ownerId: 'p1',
      ),
      CloudObject(
        id: 'water',
        position: const HexCoord(0, 2),
        kind: const WaterCloud(),
        remainingTurns: 3,
        ownerId: 'p1',
        radius: 2,
      ),
      CloudObject(
        id: 'mobile',
        position: const HexCoord(0, -2),
        kind: const MobileCloud(),
        remainingTurns: 4,
        ownerId: 'p1',
      ),
    ];

    // castAnimation is left null so t defaults to 1.0 (fully played), which
    // exercises the killed/red-burst tail of _drawConveyorChainAnimation in
    // this single paint without needing to drive an AnimationController.
    final conveyorChainAnimations = [
      const ConveyorChainAnimation(
        path: [HexCoord(0, 0), HexCoord(1, 0), HexCoord(1, -1)],
        killed: false,
      ),
      const ConveyorChainAnimation(path: [HexCoord(-1, -1)], killed: false), // < 2 tiles: no-op guard
      const ConveyorChainAnimation(
        path: [HexCoord(2, 0), HexCoord(2, -1), HexCoord(2, -2)],
        killed: true,
      ),
    ];

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CustomPaint(
          size: const Size(400, 400),
          painter: BattlefieldPainter(
            radius: 4,
            hexSize: 24,
            occupancy: const {},
            tileEffects: tileEffects,
            clouds: clouds,
            directionPickHexes: const [HexCoord(1, 0), HexCoord(0, 1)],
            conveyorChainAnimations: conveyorChainAnimations,
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(CustomPaint), findsWidgets);
  });

  testWidgets(
      'paints pending cast orbs (held + range ring) and a travel-only '
      'cast animation without throwing', (tester) async {
    // castAnimation left null (t defaults to 1.0) exercises the burst tail
    // of the now-travel-only _drawCastAnimation timeline (appear is no
    // longer part of it -- see PendingCastOrb for that leg instead).
    final castAnimations = [
      const CastAnimation(
        fromHex: HexCoord(0, 0),
        toHex: HexCoord(2, 0),
        color: Colors.orange,
      ),
    ];

    final pendingCastOrbs = [
      const PendingCastOrb(
        origin: HexCoord(-2, 0),
        color: Colors.blue,
      ),
      const PendingCastOrb(
        origin: HexCoord(-2, 2),
        color: Colors.brown,
        rangeRadius: 2,
      ),
    ];

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CustomPaint(
          size: const Size(400, 400),
          painter: BattlefieldPainter(
            radius: 4,
            hexSize: 24,
            occupancy: const {},
            castAnimations: castAnimations,
            pendingCastOrbs: pendingCastOrbs,
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(CustomPaint), findsWidgets);
  });

  // ── Resolution hold-back ────────────────────────────────────────────────
  //
  // Pixels, not smoke, because "was it drawn?" is the entire question here.
  // The painter repaints every frame off the pulse controller while the engine
  // is still mutating BattleState between network awaits, so an effect the
  // applicator has created but no card has revealed yet must be skipped on the
  // strength of the baseline alone — a hidden-set the caller computed in
  // build() is already stale by then. See ResolutionBaseline.

  group('ResolutionBaseline', () {
    final cloud = CloudObject(
      id: 'conjured-this-turn',
      position: const HexCoord(0, 0),
      kind: const ToxicCloud(),
      remainingTurns: 2,
      ownerId: 'p1',
    );

    Future<Uint8List> render(
      WidgetTester tester, {
      required List<CloudObject> clouds,
      ResolutionBaseline? baseline,
    }) async {
      late Uint8List bytes;
      await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        BattlefieldPainter(
          radius: 3,
          hexSize: 24,
          occupancy: const {},
          clouds: clouds,
          resolutionBaseline: baseline,
        ).paint(Canvas(recorder), const Size(300, 300));
        final image = await recorder.endRecording().toImage(300, 300);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        bytes = data!.buffer.asUint8List();
      });
      return bytes;
    }

    testWidgets('holds back a cloud that post-dates the snapshot',
        (tester) async {
      final empty = await render(tester, clouds: const []);
      final held = await render(
        tester,
        clouds: [cloud],
        // Snapshot taken before the cloud existed — i.e. at turn submission.
        baseline: const ResolutionBaseline(
          cloudIds: {},
          tileHexes: {},
          minionIds: {},
        ),
      );

      expect(held, equals(empty),
          reason: 'a cloud created mid-turn must draw nothing until its '
              'spell card reveals it');
    });

    testWidgets('draws a cloud that was already on the field', (tester) async {
      final empty = await render(tester, clouds: const []);
      final shown = await render(
        tester,
        clouds: [cloud],
        baseline: ResolutionBaseline(
          cloudIds: {cloud.id},
          tileHexes: const {},
          minionIds: const {},
        ),
      );

      expect(shown, isNot(equals(empty)),
          reason: 'the hold-back must not swallow clouds that predate the turn');
    });

    testWidgets('draws everything once the baseline is released',
        (tester) async {
      final empty = await render(tester, clouds: const []);
      final released = await render(tester, clouds: [cloud]);

      expect(released, isNot(equals(empty)));
    });
  });
}
