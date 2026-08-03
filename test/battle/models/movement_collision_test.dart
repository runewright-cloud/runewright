// SPDX-License-Identifier: GPL-3.0-or-later
//
// movement_collision_test.dart — Battlefield.resolveMovement's contested-tile
// arbitration (design doc §Movement Collision).
//
// The load-bearing rule: a collision loser stops "on their previous position
// along their path" — one tile short — NOT back at their origin. Ties push
// every contestant back one tile; a unique fastest contestant claims the tile
// and only the losers give ground. Because a pushed-back player can land on a
// tile someone else claimed, arbitration re-runs to a fixed point, so a chain
// of collisions can cost a player more than one tile.

import 'package:test/test.dart';
import 'package:rune_duel/battle/models/hex_battlefield.dart';
import 'package:rune_duel/battle/models/terrain.dart';
import 'package:rune_duel/engine/hex_grid.dart';

void main() {
  // A straight line of adjacent tiles along the +q axis: (-2,0) … (3,0).
  HexCoord q(int i) => HexCoord(i, 0);

  group('resolveMovement — contested destination', () {
    test('equal speed: both stop one tile short, not back at origin', () {
      final field = Battlefield(radius: 4);
      field.occupancy['a'] = q(-2);
      field.occupancy['b'] = q(2);

      // Both declare 2 tiles and meet head-on at (0,0).
      final result = field.resolveMovement(
        {
          'a': [q(-1), q(0)],
          'b': [q(1), q(0)],
        },
        {'a': 2, 'b': 2},
      );

      expect(result.bounced, {'a', 'b'});
      expect(result.paths['a'], [q(-1)]);
      expect(result.paths['b'], [q(1)]);
    });

    test('higher speed claims the tile; the loser stops one tile short', () {
      final field = Battlefield(radius: 4);
      field.occupancy['fast'] = q(-2);
      field.occupancy['slow'] = q(2);

      final result = field.resolveMovement(
        {
          'fast': [q(-1), q(0)],
          'slow': [q(1), q(0)],
        },
        {'fast': 3, 'slow': 2},
      );

      expect(result.bounced, {'slow'});
      expect(result.paths['fast'], [q(-1), q(0)]);
      expect(result.paths['slow'], [q(1)]);
    });

    test('uncontested movement is untouched', () {
      final field = Battlefield(radius: 4);
      field.occupancy['a'] = q(-2);
      field.occupancy['b'] = q(2);

      final result = field.resolveMovement(
        {
          'a': [q(-1)],
          'b': [q(1)],
        },
        {'a': 2, 'b': 2},
      );

      expect(result.bounced, isEmpty);
      expect(result.paths['a'], [q(-1)]);
      expect(result.paths['b'], [q(1)]);
    });

    test('a one-step mover falls back to its origin', () {
      final field = Battlefield(radius: 4);
      field.occupancy['a'] = q(-1);
      field.occupancy['b'] = q(1);

      final result = field.resolveMovement(
        {
          'a': [q(0)],
          'b': [q(0)],
        },
        {'a': 2, 'b': 2},
      );

      expect(result.bounced, {'a', 'b'});
      expect(result.paths['a'], isEmpty);
      expect(result.paths['b'], isEmpty);
    });

    test('nobody can be shoved off the tile they started on', () {
      final field = Battlefield(radius: 4);
      field.occupancy['sitter'] = q(0);
      field.occupancy['charger'] = q(2);

      // The charger is faster, but the sitter never declared a move, so the
      // charger is the one who gives ground.
      final result = field.resolveMovement(
        {
          'sitter': const [],
          'charger': [q(1), q(0)],
        },
        {'sitter': 2, 'charger': 4},
      );

      expect(result.bounced, {'charger'});
      expect(result.paths['sitter'], isEmpty);
      expect(result.paths['charger'], [q(1)]);
    });

    test('a fallback tile that is itself contested cascades', () {
      final field = Battlefield(radius: 4);
      // a and b tie head-on for (1,0): both fall back, a to (0,0) and b to
      // (2,0). c also ends its move on (0,0) at a lower speed, so c — not the
      // already-bounced a — gives way and returns to its origin.
      field.occupancy['a'] = q(-1);
      field.occupancy['b'] = q(3);
      field.occupancy['c'] = q(0);

      final result = field.resolveMovement(
        {
          'a': [q(0), q(1)],
          'b': [q(2), q(1)],
          'c': const [],
        },
        {'a': 2, 'b': 2, 'c': 2},
      );

      // a's fallback (0,0) is c's origin, which c can't be shoved off, so a
      // keeps giving ground all the way back to (-1,0).
      expect(result.paths['a'], isEmpty);
      expect(result.paths['b'], [q(2)]);
      expect(result.paths['c'], isEmpty);
      expect(result.bounced, {'a', 'b'});
    });

    test('impassable-clamped path still arbitrates on the clamped tile', () {
      final field = Battlefield(radius: 4);
      field.occupancy['a'] = q(-2);
      field.occupancy['b'] = q(2);

      final result = field.resolveMovement(
        {
          'a': [q(-1), q(0)],
          'b': [q(1), q(0)],
        },
        {'a': 2, 'b': 2},
        tileEffects: {q(0): const ImpassableTile()},
      );

      // Neither reaches (0,0), so their clamped destinations don't collide.
      expect(result.bounced, isEmpty);
      expect(result.paths['a'], [q(-1)]);
      expect(result.paths['b'], [q(1)]);
    });
  });

  // MovementResult.contests is UI-only — it is what lets the battlefield play
  // "both wizards reached for that tile and one was shoved off" instead of
  // teleporting the loser to their consolation tile. It must therefore report
  // the tile and the winner, not just that somebody bounced.
  group('resolveMovement — contest reporting', () {
    test('a speed win names the tile, the winner and the loser', () {
      final field = Battlefield(radius: 4);
      field.occupancy['fast'] = q(-2);
      field.occupancy['slow'] = q(2);

      final result = field.resolveMovement(
        {
          'fast': [q(-1), q(0)],
          'slow': [q(1), q(0)],
        },
        {'fast': 3, 'slow': 2},
      );

      expect(result.contests, hasLength(1));
      final contest = result.contests.single;
      expect(contest.tile, q(0));
      expect(contest.contestants, unorderedEquals(['fast', 'slow']));
      expect(contest.winnerId, 'fast');
      expect(contest.losers, ['slow']);
    });

    test('a tie for fastest has no winner — everyone lunged and lost', () {
      final field = Battlefield(radius: 4);
      field.occupancy['a'] = q(-2);
      field.occupancy['b'] = q(2);

      final result = field.resolveMovement(
        {
          'a': [q(-1), q(0)],
          'b': [q(1), q(0)],
        },
        {'a': 2, 'b': 2},
      );

      final contest = result.contests.single;
      expect(contest.tile, q(0));
      expect(contest.winnerId, isNull);
      expect(contest.losers, unorderedEquals(['a', 'b']));
    });

    test('an origin holder is reported as the winner', () {
      final field = Battlefield(radius: 4);
      field.occupancy['sitter'] = q(0);
      field.occupancy['charger'] = q(2);

      final result = field.resolveMovement(
        {
          'sitter': const [],
          'charger': [q(1), q(0)],
        },
        {'sitter': 2, 'charger': 4},
      );

      final contest = result.contests.single;
      expect(contest.tile, q(0));
      expect(contest.winnerId, 'sitter');
      expect(contest.losers, ['charger']);
    });

    test('no collision reports no contests', () {
      final field = Battlefield(radius: 4);
      field.occupancy['a'] = q(-2);
      field.occupancy['b'] = q(2);

      final result = field.resolveMovement(
        {
          'a': [q(-1)],
          'b': [q(1)],
        },
        {'a': 2, 'b': 2},
      );

      expect(result.contests, isEmpty);
    });

    test('a cascading push-back reports each contest in the order it settled', () {
      final field = Battlefield(radius: 4);
      field.occupancy['a'] = q(-1);
      field.occupancy['b'] = q(3);
      field.occupancy['c'] = q(0);

      final result = field.resolveMovement(
        {
          'a': [q(0), q(1)],
          'b': [q(2), q(1)],
          'c': const [],
        },
        {'a': 2, 'b': 2, 'c': 2},
      );

      // a and b tie for (1,0) first; a's fallback then collides with c's
      // origin. The UI lunges a at (1,0) — the FIRST tile they lost — which is
      // the one they visibly reached furthest for.
      expect(result.contests.first.tile, q(1));
      expect(result.contests.first.winnerId, isNull);
      expect(
        result.contests.map((c) => c.tile),
        containsAllInOrder([q(1), q(0)]),
      );
      final second = result.contests.firstWhere((c) => c.tile == q(0));
      expect(second.winnerId, 'c');
      expect(second.losers, ['a']);
    });
  });
}
