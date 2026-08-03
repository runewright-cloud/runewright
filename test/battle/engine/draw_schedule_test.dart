// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:rune_duel/battle/engine/draw_schedule.dart';
import 'package:rune_duel/battle/engine/hash_rng.dart';
import 'package:rune_duel/battle/engine/spell_draw.dart';
import 'package:rune_duel/spells/spell_asset.dart';

// ── Test helpers ──────────────────────────────────────────────────────────────

SpellAsset _spell(String id) => SpellAsset(
      id: id,
      createdAt: DateTime(2026),
      tier: 12,
      t: 3,
      ownerPubkeyHex: '0x${'00' * 32}',
      manaCost: 1,
      segmentCount: 0,
      dotCount: 1,
      initialGrid: List.filled(469, 0),
      proofBytes: Uint8List(0),
      name: 'Spell $id',
      commitmentHex: '0x${id.padLeft(64, '0')}',
      spellHashHex: '0x${id.padLeft(64, '0')}',
    );

Uint8List _seed(int fill) => Uint8List.fromList(List.generate(32, (i) => (i * 7 + fill) % 256));

final _entropy = _seed(0);
final _altEntropy = Uint8List.fromList(List.generate(32, (i) => 255 - i));

HashRng _turnRng(int turn) => HashRng(_seed(turn * 97 + 3));

void main() {
  // Positions 0..4 mirror a 5-spell chapter already sorted by commitmentHex
  // (chapter.dart), same shape as spell_draw_test.dart's `chapter` fixture —
  // 'aaaa'..'eeee' sort to positions 0..4 in that order.
  final chapter = [
    _spell('aaaa'),
    _spell('bbbb'),
    _spell('cccc'),
    _spell('dddd'),
    _spell('eeee'),
  ];

  group('DrawSchedule.opening — initial state', () {
    test('hand size equals bookmarkCount when chapter is large enough', () {
      final schedule = DrawSchedule.opening(5, 3, HashRng(_entropy));
      expect(schedule.hand.length, equals(3));
    });

    test('hand size is clamped to chapter size when chapter is small', () {
      final schedule = DrawSchedule.opening(2, 5, HashRng(_entropy));
      expect(schedule.hand.length, equals(2));
    });

    test('remaining has chapterSize - hand.length positions', () {
      final schedule = DrawSchedule.opening(5, 3, HashRng(_entropy));
      expect(schedule.remaining.length, equals(5 - 3));
    });

    test('hand + remaining covers every position exactly once', () {
      final schedule = DrawSchedule.opening(5, 3, HashRng(_entropy));
      final all = {...schedule.hand, ...schedule.remaining};
      expect(all, equals({0, 1, 2, 3, 4}));
    });
  });

  group('DrawSchedule.opening — agrees with SpellDraw.opening', () {
    test('same seed → DrawSchedule positions select the same spells SpellDraw drew', () {
      final draw = SpellDraw.opening(chapter, 3, HashRng(_entropy));
      final schedule = DrawSchedule.opening(chapter.length, 3, HashRng(_entropy));

      final handFromPositions = schedule.hand.map((p) => chapter[p].id).toSet();
      final handFromSpellDraw = draw.hand.map((s) => s.id).toSet();
      expect(handFromPositions, equals(handFromSpellDraw));

      final remainingFromPositions = schedule.remaining.map((p) => chapter[p].id).toSet();
      final remainingFromSpellDraw = draw.remaining.map((s) => s.id).toSet();
      expect(remainingFromPositions, equals(remainingFromSpellDraw));
    });

    test('same seed → refill draws select the same spell on both sides', () {
      var draw = SpellDraw.opening(chapter, 3, HashRng(_entropy));
      var schedule = DrawSchedule.opening(chapter.length, 3, HashRng(_entropy));

      // The owning client uses hand slot 0; the position at that slot is
      // schedule.hand[0] (both were dealt identically, so this indexing
      // agrees between draw.hand[0] and schedule.hand[0]).
      final usedPosition = schedule.hand[0];
      expect(chapter[usedPosition].id, equals(draw.hand[0].id));

      // Fresh HashRng instances from the same seed bytes — exactly how
      // TurnLoop derives them (never a shared mutable instance).
      draw = draw.useSpell(0, HashRng(_seed(500)));
      schedule = schedule.useSlotAtPosition(usedPosition, HashRng(_seed(500)));

      final handFromPositions = schedule.hand.map((p) => chapter[p].id).toSet();
      final handFromSpellDraw = draw.hand.map((s) => s.id).toSet();
      expect(handFromPositions, equals(handFromSpellDraw));
    });
  });

  group('DrawSchedule — useSlotAtPosition (draw-on-demand refill)', () {
    test('using a position shrinks then refills the hand from remaining', () {
      final schedule = DrawSchedule.opening(5, 3, HashRng(_entropy));
      final usedPosition = schedule.hand[0];
      final next = schedule.useSlotAtPosition(usedPosition, _turnRng(1));
      expect(next.hand.length, equals(3));
      expect(next.hand, isNot(contains(usedPosition)));
      expect(next.remaining.length, equals(schedule.remaining.length - 1));
    });

    test('using all remaining positions eventually empties the pool', () {
      var schedule = DrawSchedule.opening(5, 3, HashRng(_entropy));
      var turn = 1;
      while (!schedule.isDeckEmpty) {
        schedule = schedule.useSlotAtPosition(schedule.hand[0], _turnRng(turn++));
      }
      expect(schedule.isDeckEmpty, isTrue);
    });

    test('hand shrinks when pool is exhausted and a position is used', () {
      final schedule = DrawSchedule.opening(2, 2, HashRng(_entropy));
      expect(schedule.isDeckEmpty, isTrue);
      final next = schedule.useSlotAtPosition(schedule.hand[0], _turnRng(1));
      expect(next.hand.length, equals(1));
    });

    test('original schedule is immutable after useSlotAtPosition', () {
      final schedule = DrawSchedule.opening(5, 3, HashRng(_entropy));
      final originalHand = List<int>.from(schedule.hand);
      schedule.useSlotAtPosition(schedule.hand[0], _turnRng(1));
      expect(schedule.hand, equals(originalHand));
    });

    test('using a position clears its withered flag', () {
      var schedule = DrawSchedule.opening(5, 3, HashRng(_entropy));
      final position = schedule.hand[0];
      schedule = schedule.witherPositions([position]);
      expect(schedule.isWithered(position), isTrue);
      schedule = schedule.useSlotAtPosition(position, _turnRng(1));
      expect(schedule.withered.contains(position), isFalse);
    });
  });

  group('DrawSchedule — wither / reactivate (§9)', () {
    test('witherPositions marks in-hand positions withered', () {
      final schedule = DrawSchedule.opening(5, 3, HashRng(_entropy));
      final target = schedule.hand[0];
      final withered = schedule.witherPositions([target]);
      expect(withered.isWithered(target), isTrue);
      expect(withered.isCastable(target), isFalse);
    });

    test('witherPositions ignores positions not in hand', () {
      final schedule = DrawSchedule.opening(5, 3, HashRng(_entropy));
      final notInHand = schedule.remaining.first;
      final withered = schedule.witherPositions([notInHand]);
      expect(withered.isWithered(notInHand), isFalse);
    });

    test('reactivatePositions clears the withered flag and restores castability', () {
      final schedule = DrawSchedule.opening(5, 3, HashRng(_entropy));
      final target = schedule.hand[0];
      var withered = schedule.witherPositions([target]);
      expect(withered.isCastable(target), isFalse);
      final reactivated = withered.reactivatePositions([target]);
      expect(reactivated.isWithered(target), isFalse);
      expect(reactivated.isCastable(target), isTrue);
    });

    test('non-withered in-hand positions stay castable', () {
      final schedule = DrawSchedule.opening(5, 3, HashRng(_entropy));
      final target = schedule.hand[0];
      final other = schedule.hand[1];
      final withered = schedule.witherPositions([target]);
      expect(withered.isCastable(other), isTrue);
    });
  });

  group('DrawSchedule — isCastable / isInHand (§6 enforcement primitives)', () {
    test('a position not in hand is not castable', () {
      final schedule = DrawSchedule.opening(5, 3, HashRng(_entropy));
      final notInHand = schedule.remaining.first;
      expect(schedule.isInHand(notInHand), isFalse);
      expect(schedule.isCastable(notInHand), isFalse);
    });

    test('an in-hand, non-withered position is castable', () {
      final schedule = DrawSchedule.opening(5, 3, HashRng(_entropy));
      expect(schedule.isCastable(schedule.hand.first), isTrue);
    });
  });

  group('DrawSchedule — determinism', () {
    test('same entropy → same schedule on two independent calls', () {
      final a = DrawSchedule.opening(5, 3, HashRng(_entropy));
      final b = DrawSchedule.opening(5, 3, HashRng(_entropy));
      expect(a.hand, equals(b.hand));
      expect(a.remaining, equals(b.remaining));
    });

    test('different entropy → different hand (probabilistic)', () {
      final a = DrawSchedule.opening(5, 3, HashRng(_entropy));
      final b = DrawSchedule.opening(5, 3, HashRng(_altEntropy));
      expect(a.hand, isNot(equals(b.hand)));
    });
  });
}
