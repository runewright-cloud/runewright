// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:typed_data';

import 'package:test/test.dart';
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

// Turn-N seeds: distinct per turn, mirroring how TurnLoop._phaseSeed would
// derive a per-turn, domain-separated draw seed from that turn's freshly
// revealed joint entropy (turn_loop.dart:1097). The exact derivation isn't
// under test here — only that SpellDraw treats each injected HashRng as
// independent, unpredictable input.
HashRng _turnRng(int turn) => HashRng(_seed(turn * 97 + 3));

void main() {
  final chapter = [
    _spell('aaaa'),
    _spell('bbbb'),
    _spell('cccc'),
    _spell('dddd'),
    _spell('eeee'),
  ];

  group('SpellDraw.opening — initial state', () {
    test('hand size equals bookmarkCount when chapter is large enough', () {
      final draw = SpellDraw.opening(chapter, 3, HashRng(_entropy));
      expect(draw.hand.length, equals(3));
    });

    test('hand size is clamped to chapter size when chapter is small', () {
      final draw = SpellDraw.opening(chapter.sublist(0, 2), 5, HashRng(_entropy));
      expect(draw.hand.length, equals(2));
    });

    test('remaining deck has chapter.length - hand.length spells', () {
      final draw = SpellDraw.opening(chapter, 3, HashRng(_entropy));
      expect(draw.remaining.length, equals(chapter.length - 3));
    });

    test('hand + remaining covers all chapter spells (no duplicates)', () {
      final draw = SpellDraw.opening(chapter, 3, HashRng(_entropy));
      final all = {...draw.hand.map((s) => s.id), ...draw.remaining.map((s) => s.id)};
      expect(all, equals(chapter.map((s) => s.id).toSet()));
    });

    test('remaining pool stays in canonical (chapter) order', () {
      final draw = SpellDraw.opening(chapter, 3, HashRng(_entropy));
      final remainingIds = draw.remaining.map((s) => s.id).toList();
      final canonicalOrder = chapter.map((s) => s.id).where(remainingIds.contains).toList();
      expect(remainingIds, equals(canonicalOrder));
    });
  });

  group('SpellDraw.opening — determinism', () {
    test('same entropy → same hand on two independent calls', () {
      final draw1 = SpellDraw.opening(chapter, 3, HashRng(_entropy));
      final draw2 = SpellDraw.opening(chapter, 3, HashRng(_entropy));
      expect(
        draw1.hand.map((s) => s.id).toList(),
        equals(draw2.hand.map((s) => s.id).toList()),
      );
    });

    test('different entropy → different hand (probabilistic)', () {
      final draw1 = SpellDraw.opening(chapter, 3, HashRng(_entropy));
      final draw2 = SpellDraw.opening(chapter, 3, HashRng(_altEntropy));
      // With 5 spells and 2 entropy values the hands should differ.
      // There is a ~1/120 chance they're identical by coincidence; acceptable.
      expect(
        draw1.hand.map((s) => s.id).toList(),
        isNot(equals(draw2.hand.map((s) => s.id).toList())),
      );
    });
  });

  group('SpellDraw — useSpell (draw-on-demand refill)', () {
    test('using a spell shrinks the hand then refills from remaining pool', () {
      final draw = SpellDraw.opening(chapter, 3, HashRng(_entropy));
      final beforeIds = draw.hand.map((s) => s.id).toList();
      final nextDraw = draw.useSpell(0, _turnRng(1));
      // Hand stays same size (one removed, one drawn from the pool).
      expect(nextDraw.hand.length, equals(3));
      // The used spell is gone from the hand.
      expect(nextDraw.hand.map((s) => s.id), isNot(contains(beforeIds[0])));
      // The remaining pool shrinks by 1.
      expect(nextDraw.remaining.length, equals(draw.remaining.length - 1));
    });

    test('using all remaining pool spells eventually empties the pool', () {
      var draw = SpellDraw.opening(chapter, 3, HashRng(_entropy));
      var turn = 1;
      while (!draw.isDeckEmpty) {
        draw = draw.useSpell(0, _turnRng(turn++));
      }
      expect(draw.isDeckEmpty, isTrue);
    });

    test('hand shrinks when pool is exhausted and a spell is used', () {
      // Chapter of 2, hand size 2 → remaining = 0 from the start.
      final draw = SpellDraw.opening(chapter.sublist(0, 2), 2, HashRng(_entropy));
      expect(draw.isDeckEmpty, isTrue);
      final next = draw.useSpell(0, _turnRng(1));
      expect(next.hand.length, equals(1)); // shrinks; nothing to refill from
    });

    test('original draw is immutable after useSpell', () {
      final draw = SpellDraw.opening(chapter, 3, HashRng(_entropy));
      final originalIds = draw.hand.map((s) => s.id).toList();
      draw.useSpell(0, _turnRng(1)); // should not mutate draw
      expect(draw.hand.map((s) => s.id).toList(), equals(originalIds));
    });
  });

  group('SpellDraw — auditability (replay from recorded entropy)', () {
    test('replaying the draw sequence from the same per-turn entropy gives the same results', () {
      var drawA = SpellDraw.opening(chapter, 3, HashRng(_entropy));
      var drawB = SpellDraw.opening(chapter, 3, HashRng(_entropy));

      // Both clients use spell at index 1 on turn 1, seeded by that turn's
      // (recorded, replayable) entropy.
      drawA = drawA.useSpell(1, _turnRng(1));
      drawB = drawB.useSpell(1, _turnRng(1));

      expect(
        drawA.hand.map((s) => s.id).toList(),
        equals(drawB.hand.map((s) => s.id).toList()),
      );
    });
  });

  group('SpellDraw — unpredictability (peek-ahead backstop)', () {
    // A wide chapter, so the remaining pool stays large at the point the two
    // branches diverge — with a small pool (e.g. 2 remaining spells) a 50%
    // coincidental collision is expected and would make this vector flaky,
    // not wrong. 20 spells / hand size 2 keeps the pool at 17+ throughout.
    final wideChapter = List.generate(20, (i) => _spell(i.toString().padLeft(4, '0')));

    // This is the vector that would fail under the old "shuffle everything
    // at construction" design: there, the entire future draw order was fixed
    // by the opening seed alone, so varying a later turn's entropy could
    // never change that turn's draw. Under draw-on-demand it must.
    test('changing only turn-2 entropy changes the turn-2 draw, not turn-1', () {
      var baseline = SpellDraw.opening(wideChapter, 2, HashRng(_entropy));
      var variant = SpellDraw.opening(wideChapter, 2, HashRng(_entropy));

      // Turn 1: identical entropy for both branches.
      baseline = baseline.useSpell(0, _turnRng(1));
      variant = variant.useSpell(0, _turnRng(1));
      expect(
        baseline.hand.map((s) => s.id).toList(),
        equals(variant.hand.map((s) => s.id).toList()),
        reason: 'turn-1 draw must be identical when turn-1 entropy is identical',
      );

      // Turn 2: diverging entropy between the two branches.
      final baselineAfter = baseline.useSpell(0, _turnRng(2));
      final variantAfter = variant.useSpell(0, HashRng(_altEntropy));

      expect(
        baselineAfter.hand.map((s) => s.id).toList(),
        isNot(equals(variantAfter.hand.map((s) => s.id).toList())),
        reason: 'turn-2 draw must depend on turn-2 entropy, not be fixed at construction',
      );
    });

    test('the opening seed alone does not determine later draws', () {
      // Given only the opening hand/pool (i.e. what a player's own client can
      // see immediately after the battle-start reveal), the turn-2 draw is
      // not a pure function of that state plus a fixed walk order — it
      // requires turn-2's entropy, which does not exist yet at turn 1.
      var drawA = SpellDraw.opening(wideChapter, 2, HashRng(_entropy));
      var drawB = SpellDraw.opening(wideChapter, 2, HashRng(_entropy));
      // Identical opening state.
      expect(drawA.remaining.map((s) => s.id).toList(),
          equals(drawB.remaining.map((s) => s.id).toList()));

      drawA = drawA.useSpell(0, _turnRng(1)).useSpell(0, _turnRng(2));
      drawB = drawB.useSpell(0, _turnRng(1)).useSpell(0, HashRng(_altEntropy));

      expect(
        drawA.hand.map((s) => s.id).toList(),
        isNot(equals(drawB.hand.map((s) => s.id).toList())),
      );
    });
  });

  group('SpellDraw — draw distribution sanity (no modulo bias artifacts)', () {
    // Exercises non-power-of-2 pool sizes (5, 3, 1 remaining) across many
    // independent seeds and checks every remaining spell is reachable — a
    // regression guard on HashRng.nextInt's rejection sampling being used
    // correctly at each pool size SpellDraw actually produces.
    test('every remaining spell is reachable as a refill draw across many seeds', () {
      final seen = <String>{};
      for (var i = 0; i < 200; i++) {
        var draw = SpellDraw.opening(chapter, 1, HashRng(_seed(i)));
        draw = draw.useSpell(0, HashRng(_seed(1000 + i)));
        seen.addAll(draw.hand.map((s) => s.id));
      }
      expect(seen, equals(chapter.map((s) => s.id).toSet()));
    });
  });
}
