// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:typed_data';

import 'package:test/test.dart';
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

final _entropy = Uint8List.fromList(List.generate(32, (i) => i * 7 % 256));
final _altEntropy = Uint8List.fromList(List.generate(32, (i) => 255 - i));

void main() {
  final chapter = [
    _spell('aaaa'),
    _spell('bbbb'),
    _spell('cccc'),
    _spell('dddd'),
    _spell('eeee'),
  ];

  group('SpellDraw — initial state', () {
    test('hand size equals bookmarkCount when chapter is large enough', () {
      final draw = SpellDraw(chapter, 3, _entropy);
      expect(draw.hand.length, equals(3));
    });

    test('hand size is clamped to chapter size when chapter is small', () {
      final draw = SpellDraw(chapter.sublist(0, 2), 5, _entropy);
      expect(draw.hand.length, equals(2));
    });

    test('remaining deck has chapter.length - hand.length spells', () {
      final draw = SpellDraw(chapter, 3, _entropy);
      expect(draw.remaining.length, equals(chapter.length - 3));
    });

    test('hand + remaining covers all chapter spells (no duplicates)', () {
      final draw = SpellDraw(chapter, 3, _entropy);
      final all = {...draw.hand.map((s) => s.id), ...draw.remaining.map((s) => s.id)};
      expect(all, equals(chapter.map((s) => s.id).toSet()));
    });
  });

  group('SpellDraw — determinism', () {
    test('same entropy → same hand on two independent calls', () {
      final draw1 = SpellDraw(chapter, 3, _entropy);
      final draw2 = SpellDraw(chapter, 3, _entropy);
      expect(
        draw1.hand.map((s) => s.id).toList(),
        equals(draw2.hand.map((s) => s.id).toList()),
      );
    });

    test('different entropy → different hand (probabilistic)', () {
      final draw1 = SpellDraw(chapter, 3, _entropy);
      final draw2 = SpellDraw(chapter, 3, _altEntropy);
      // With 5 spells and 2 entropy values the hands should differ.
      // There is a ~1/120 chance they're identical by coincidence; acceptable.
      expect(
        draw1.hand.map((s) => s.id).toList(),
        isNot(equals(draw2.hand.map((s) => s.id).toList())),
      );
    });
  });

  group('SpellDraw — useSpell', () {
    test('using a spell shrinks the hand then refills from remaining deck', () {
      final draw = SpellDraw(chapter, 3, _entropy);
      final beforeIds = draw.hand.map((s) => s.id).toList();
      final nextDraw = draw.useSpell(0);
      // Hand stays same size (one removed, one drawn from deck).
      expect(nextDraw.hand.length, equals(3));
      // The used spell is gone from the hand.
      expect(nextDraw.hand.map((s) => s.id), isNot(contains(beforeIds[0])));
      // The remaining deck shrinks by 1.
      expect(nextDraw.remaining.length, equals(draw.remaining.length - 1));
    });

    test('using all remaining deck spells eventually empties the deck', () {
      var draw = SpellDraw(chapter, 3, _entropy);
      while (!draw.isDeckEmpty) {
        draw = draw.useSpell(0);
      }
      expect(draw.isDeckEmpty, isTrue);
    });

    test('hand shrinks when deck is exhausted and a spell is used', () {
      // Chapter of 2, hand size 2 → remaining = 0 from the start.
      final draw = SpellDraw(chapter.sublist(0, 2), 2, _entropy);
      expect(draw.isDeckEmpty, isTrue);
      final next = draw.useSpell(0);
      expect(next.hand.length, equals(1)); // shrinks; nothing to refill from
    });

    test('original draw is immutable after useSpell', () {
      final draw = SpellDraw(chapter, 3, _entropy);
      final originalIds = draw.hand.map((s) => s.id).toList();
      draw.useSpell(0); // should not mutate draw
      expect(draw.hand.map((s) => s.id).toList(), equals(originalIds));
    });
  });

  group('SpellDraw — auditability', () {
    test('replaying the draw sequence from entropy gives the same results', () {
      var drawA = SpellDraw(chapter, 3, _entropy);
      var drawB = SpellDraw(chapter, 3, _entropy);

      // Both clients use spell at index 1 on turn 1.
      drawA = drawA.useSpell(1);
      drawB = drawB.useSpell(1);

      expect(
        drawA.hand.map((s) => s.id).toList(),
        equals(drawB.hand.map((s) => s.id).toList()),
      );
    });
  });
}
