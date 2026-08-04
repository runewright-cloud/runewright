// SPDX-License-Identifier: GPL-3.0-or-later
//
// attack_animation_test.dart — the attack timeline: the melee swipe
// (meleeSlashStrokeAt) and the lead-in that lets a strike ride a walk playback
// (attackProgressAt), plus the painter pass that draws both forms.
//
// This is cosmetic code, so "correct" means "reads as the thing that happened":
//   - the blade crosses the tile that was struck, square to the line of attack,
//     so the mark says "hit here" rather than "pointing that way";
//   - it travels — head first, tail following — instead of growing out of one
//     point, which is what makes a swipe a swipe;
//   - it clears itself, because the controller driving it is one-shot and sits
//     at t=1 forever once it finishes;
//   - and a strike that rides a lunge does not land before the lunging token
//     arrives.
//
// That last one is why startFraction exists at all: the blow and the lunge are
// one event, played on two controllers.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rune_duel/battle/models/effect_kind.dart' show SpellAffinity;
import 'package:rune_duel/engine/hex_grid.dart';
import 'package:rune_duel/ui/battlefield_painter.dart';

void main() {
  const center = Offset(200, 200);
  const hexSize = 24.0;
  Offset px(HexCoord h) => hexToPixel(h, center, hexSize);

  // Pixel geometry is flat-top axial, so +q runs diagonally, not across the
  // screen: every claim below is made against the attack vector itself rather
  // than against dx/dy, which is also what keeps them true for all six
  // directions.
  double dot(Offset a, Offset b) => a.dx * b.dx + a.dy * b.dy;

  const swipe = AttackAnimation(
    fromHex: HexCoord(-1, 0),
    toHex: HexCoord(0, 0),
    color: Colors.red,
    melee: true,
  );
  final attackVec = px(const HexCoord(0, 0)) - px(const HexCoord(-1, 0));

  MeleeSlashStroke strokeAt(double p) =>
      meleeSlashStrokeAt(swipe, p, center, hexSize);

  /// How far along the swipe's own axis [point] sits, measured from where the
  /// blade enters. Progress along the sweep, in pixels.
  double across(Offset point) =>
      (point - meleeSlashStrokeAt(swipe, 0.0, center, hexSize).head).distance;

  group('meleeSlashStrokeAt', () {
    test('lies across the line of attack, over the struck tile', () {
      final mid = strokeAt(0.25);
      final blade = mid.head - mid.tail;
      // Square to the attack, not pointing along it.
      expect(
        dot(blade, attackVec).abs() / (blade.distance * attackVec.distance),
        lessThan(0.001),
      );
      expect(blade.distance, greaterThan(hexSize * 0.3));
      // On the struck tile, biting slightly toward the attacker rather than
      // landing behind the target.
      final target = px(const HexCoord(0, 0));
      expect((mid.head - target).distance, lessThan(hexSize));
      expect(dot(mid.head - target, attackVec), lessThan(0));
    });

    test('travels head-first with the tail following', () {
      final early = strokeAt(0.1);
      final mid = strokeAt(0.3);
      // The head keeps advancing across the tile...
      expect(across(mid.head), greaterThan(across(early.head)));
      // ...while the tail stays pinned at the start until the head is past
      // halfway, which is what gives the stroke visible length.
      expect(early.tail, strokeAt(0.0).tail);
      expect(across(mid.tail), greaterThan(across(early.tail)));
      expect(across(mid.tail), lessThan(across(mid.head)));
    });

    test('is fully drawn through the sweep, then fades to nothing', () {
      expect(strokeAt(0.2).alpha, 1.0);
      expect(strokeAt(0.45).alpha, closeTo(1.0, 0.001));
      expect(strokeAt(0.7).alpha, lessThan(1.0));
      expect(strokeAt(0.7).alpha, greaterThan(0.0));
      // A spent playback holds at t=1: the stroke MUST be gone there, or it
      // stays burned onto the board until the next turn.
      expect(strokeAt(1.0).alpha, 0.0);
      expect(strokeAt(1.0).isVisible, isFalse);
    });

    test(
      'nothing is drawn on the first frame — the blade has no length yet',
      () {
        expect(strokeAt(0.0).isVisible, isFalse);
        expect(strokeAt(0.25).isVisible, isTrue);
      },
    );

    test('a blow from the other side bites toward its own attacker', () {
      const backhand = AttackAnimation(
        fromHex: HexCoord(1, 0),
        toHex: HexCoord(0, 0),
        color: Colors.red,
        melee: true,
      );
      final target = px(const HexCoord(0, 0));
      final back = meleeSlashStrokeAt(backhand, 0.25, center, hexSize);
      final backVec = target - px(const HexCoord(1, 0));

      // Both strikes land on the same tile and bite the same distance short of
      // its centre — but each toward the wizard who threw it, so the two marks
      // sit on opposite faces of the tile.
      final forth = strokeAt(0.25);
      double bite(Offset head, Offset attack) =>
          dot(head - target, attack) / attack.distance;
      expect(
        bite(back.head, backVec),
        closeTo(bite(forth.head, attackVec), 1e-9),
      );
      expect(bite(back.head, backVec), lessThan(0));
      expect(
        dot(back.head - target, attackVec),
        greaterThan(0),
        reason: 'measured against the FIRST attacker it is on the far side',
      );
    });
  });

  group('attackProgressAt', () {
    test('with no lead-in, the attack is its own timeline', () {
      expect(attackProgressAt(swipe, 0.0), 0.0);
      expect(attackProgressAt(swipe, 0.5), closeTo(0.5, 1e-9));
      expect(attackProgressAt(swipe, 1.0), 1.0);
    });

    test('a strike riding a walk stays invisible until the lunge connects', () {
      const riding = AttackAnimation(
        fromHex: HexCoord(-1, 0),
        toHex: HexCoord(0, 0),
        color: Colors.red,
        melee: true,
        startFraction: 0.5,
      );
      // Nothing at all before the lead-in elapses — not "progress 0", but no
      // frame to draw, so the painter skips it entirely.
      expect(attackProgressAt(riding, 0.0), isNull);
      expect(attackProgressAt(riding, 0.49), isNull);
      expect(attackProgressAt(riding, 0.5), 0.0);
      expect(attackProgressAt(riding, 0.75), closeTo(0.5, 1e-9));
      expect(attackProgressAt(riding, 1.0), 1.0);
    });

    test('kAttackStrikeStart lands the blow as the walkers arrive', () {
      // The lead-in is derived from the movement timeline, and leads it very
      // slightly so the blade is already moving on the frame of contact —
      // exactly like the collision spark.
      expect(kAttackStrikeStart, greaterThan(0.5));
      expect(kAttackStrikeStart, lessThan(0.72));
    });
  });

  group('BattlefieldPainter — attack pass', () {
    // Same contract as the other painter tests: no pixel baseline, this catches
    // the paint()-time crash class.
    testWidgets('paints swipes and thrown orbs without throwing', (
      tester,
    ) async {
      final controller = AnimationController(
        vsync: const TestVSync(),
        duration: const Duration(milliseconds: 620),
      );
      addTearDown(controller.dispose);

      Widget board(double t) {
        controller.value = t;
        return MaterialApp(
          home: Scaffold(
            body: CustomPaint(
              size: const Size(400, 400),
              painter: BattlefieldPainter(
                radius: 4,
                hexSize: hexSize,
                localPlayerId: 'me',
                occupancy: const {'me': HexCoord(-1, 0), 'foe': HexCoord(0, 0)},
                attackAnimations: [
                  // A haymaker...
                  const AttackAnimation(
                    fromHex: HexCoord(-1, 0),
                    toHex: HexCoord(0, 0),
                    color: BattlefieldPainter.meleeStrikeColor,
                    melee: true,
                  ),
                  // ...a creature's shot from across the board...
                  AttackAnimation(
                    fromHex: const HexCoord(0, 3),
                    toHex: const HexCoord(0, 0),
                    color: BattlefieldPainter.colorForAffinity(
                      SpellAffinity.water,
                    ),
                    melee: false,
                  ),
                  // ...and one still waiting out its lunge.
                  const AttackAnimation(
                    fromHex: HexCoord(1, 0),
                    toHex: HexCoord(0, 0),
                    color: BattlefieldPainter.meleeStrikeColor,
                    melee: true,
                    startFraction: 0.5,
                  ),
                ],
                attackAnimation: controller,
              ),
            ),
          ),
        );
      }

      // Sample the whole timeline: lead-in, sweep, impact, fade, rest.
      for (final t in [0.0, 0.2, 0.5, 0.72, 0.9, 1.0]) {
        await tester.pumpWidget(board(t));
        await tester.pump();
        expect(tester.takeException(), isNull, reason: 'threw at t=$t');
      }
    });
  });
}
