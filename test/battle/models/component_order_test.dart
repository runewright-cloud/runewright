// SPDX-License-Identifier: GPL-3.0-or-later
//
// component_order_test.dart — the seating and rotation that decide who
// performs their spell components first (docs/SPELL_COMPONENTS_PLAN.md §5.2).
//
// What makes these worth pinning: both values are derived independently on
// every device with no exchange to reconcile them. A disagreement does not
// desync the state hash — it deadlocks the pacing gate, with each client
// waiting on a player the other thinks has already gone. Determinism here is
// the whole safety property.

import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:rune_duel/battle/models/component_order.dart';
import 'package:rune_duel/battle/models/hex_battlefield.dart' show Battlefield;
import 'package:rune_duel/engine/hex_grid.dart';

void main() {
  const radius = 4;
  final v = clockwiseVertices(radius);

  group('seating', () {
    test('orders players clockwise by the vertex they spawned on', () {
      // Deliberately handed in anti-clockwise order, so passing cannot be an
      // accident of input order.
      final order = clockwiseComponentOrder(
        playerIds: ['lowerLeft', 'bottom', 'lowerRight', 'top'],
        startPositions: [v[4], v[3], v[2], v[0]],
        radius: radius,
      );
      expect(order, ['top', 'lowerRight', 'bottom', 'lowerLeft']);
    });

    test('agrees with Battlefield.spawnPositions for every player count', () {
      // The seating table is transcribed from spawnPositions' own vertex list
      // (they must stay identical). This is the check that catches a drift
      // between the two — every spawn a real match hands out has to be a
      // recognised seat, or that player silently sorts to the back.
      final field = Battlefield(radius: radius);
      for (var n = 1; n <= 4; n++) {
        final spawns = field.spawnPositions(n);
        for (final s in spawns) {
          expect(
            v.contains(s),
            isTrue,
            reason: '$n-player spawn $s is not a recognised clockwise seat',
          );
        }
      }
    });

    test('a non-vertex start sorts last, and stably', () {
      // Solo's dummy sits one tile off its vertex. Nothing in the shipped
      // builders seats it, but the ordering must still be total.
      final order = clockwiseComponentOrder(
        playerIds: ['offBoard', 'bottom'],
        startPositions: [const HexCoord(0, 0), v[3]],
        radius: radius,
      );
      expect(order, ['bottom', 'offBoard']);
    });

    test('ties break on playerId, so both devices agree', () {
      final order = clockwiseComponentOrder(
        playerIds: ['zed', 'alice'],
        startPositions: [const HexCoord(0, 0), const HexCoord(0, 0)],
        radius: radius,
      );
      expect(order, ['alice', 'zed']);
    });
  });

  group('rotation', () {
    const seating = ['a', 'b', 'c'];

    test('advances the lead by one seat every turn', () {
      List<String> at(int turn) =>
          componentOrderForTurn(seating: seating, startSeat: 0, turnNumber: turn);
      expect(at(1), ['a', 'b', 'c']);
      expect(at(2), ['b', 'c', 'a']);
      expect(at(3), ['c', 'a', 'b']);
      expect(at(4), ['a', 'b', 'c']); // wraps
    });

    test('whoever went second leads the next turn', () {
      // The ratified rule, stated the way §5.2 states it.
      for (var turn = 1; turn <= 6; turn++) {
        final thisTurn =
            componentOrderForTurn(seating: seating, startSeat: 2, turnNumber: turn);
        final nextTurn = componentOrderForTurn(
            seating: seating, startSeat: 2, turnNumber: turn + 1);
        expect(nextTurn.first, thisTurn[1]);
      }
    });

    test('every seat leads equally often over a full cycle', () {
      final leads = [
        for (var turn = 1; turn <= 9; turn++)
          componentOrderForTurn(
              seating: seating, startSeat: 1, turnNumber: turn).first,
      ];
      for (final id in seating) {
        expect(leads.where((l) => l == id).length, 3);
      }
    });

    test('empty seating yields an empty order rather than throwing', () {
      expect(
        componentOrderForTurn(seating: const [], startSeat: 0, turnNumber: 1),
        isEmpty,
      );
    });

    test('componentSlotOf locates a player, or reports -1 for a stranger', () {
      int slot(String id) => componentSlotOf(
            seating: seating,
            startSeat: 0,
            turnNumber: 2,
            playerId: id,
          );
      expect(slot('b'), 0);
      expect(slot('c'), 1);
      expect(slot('a'), 2);
      expect(slot('nobody'), -1);
    });
  });

  group('start seat', () {
    test('is stable for the same entropy and player count', () {
      final e = Uint8List.fromList(List.generate(32, (i) => i * 7));
      expect(componentStartSeat(e, 2), componentStartSeat(e, 2));
    });

    test('stays in range', () {
      for (var b = 0; b < 256; b += 17) {
        final e = Uint8List.fromList(List.filled(32, b));
        for (var n = 1; n <= 6; n++) {
          final seat = componentStartSeat(e, n);
          expect(seat, greaterThanOrEqualTo(0));
          expect(seat, lessThan(n));
        }
      }
    });

    test('depends on the whole buffer, not one byte', () {
      // A peer who grinds their own nonce should have to grind the whole
      // digest, not hunt for a favourable first byte.
      final base = Uint8List.fromList(List.filled(32, 0));
      final lastByteChanged = Uint8List.fromList(List.filled(32, 0))
        ..[31] = 0x01;
      expect(
        componentStartSeat(base, 6) == componentStartSeat(lastByteChanged, 6),
        isFalse,
      );
    });

    test('a single seat always leads', () {
      final e = Uint8List.fromList(List.filled(32, 0xFF));
      expect(componentStartSeat(e, 1), 0);
    });
  });
}
