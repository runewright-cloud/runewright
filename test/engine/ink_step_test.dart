// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:test/test.dart';
import 'package:rune_duel/engine/hex_grid.dart' show HexCoord;
import 'package:rune_duel/engine/ink_step.dart';

void main() {
  group('InkStep.step', () {
    test('rule B alone: a 2-cell straight stroke grows by one cell at each end', () {
      const rules = InkRules(ruleA: false, ruleB: true, ruleE: false);
      final seed = <HexCoord>{const HexCoord(0, 0), const HexCoord(1, 0)};

      final gen1 = InkStep.step(active: seed, radius: 8, generation: 1, rules: rules);

      expect(gen1, containsAll(seed)); // interior/original cells stay put
      expect(gen1, contains(const HexCoord(-1, 0))); // grows off the (0,0) end
      expect(gen1, contains(const HexCoord(2, 0))); // grows off the (1,0) end
      expect(gen1.length, equals(4));
    });

    test('rule B alone: interior cells of a longer stroke do not change', () {
      const rules = InkRules(ruleA: false, ruleB: true, ruleE: false);
      final seed = <HexCoord>{
        const HexCoord(-1, 0),
        const HexCoord(0, 0),
        const HexCoord(1, 0),
      };

      final gen1 = InkStep.step(active: seed, radius: 8, generation: 1, rules: rules);

      // Only the two free ends extend; the interior cell (0,0) has 2 active
      // neighbors so rule B does not fire there.
      expect(gen1, equals({...seed, const HexCoord(-2, 0), const HexCoord(2, 0)}));
    });

    test('a bent stroke does not star at the corner; both free ends extend straight under rule B', () {
      const rules = InkRules(ruleA: false, ruleB: true, ruleE: false);
      // Axis A arm (-2,0)-(-1,0)-(0,0) bending onto axis C arm (0,0)-(1,-1)-(2,-2).
      final seed = <HexCoord>{
        const HexCoord(-2, 0),
        const HexCoord(-1, 0),
        const HexCoord(0, 0),
        const HexCoord(1, -1),
        const HexCoord(2, -2),
      };

      final gen1 = InkStep.step(active: seed, radius: 8, generation: 1, rules: rules);

      // The corner (0,0) has 2 active neighbors on different (non-antipodal)
      // directions, so it has 0 complete axes -- no star, even with Rule C
      // gone there's nothing left that could have starred it anyway.
      expect(gen1, equals({...seed, const HexCoord(-3, 0), const HexCoord(3, -3)}));
    });

    test('rule A: a 1-cell gap between two collinear approaching strokes is filled', () {
      const rules = InkRules(ruleA: true, ruleB: false, ruleE: false);
      final seed = <HexCoord>{
        const HexCoord(-3, 0),
        const HexCoord(-2, 0),
        const HexCoord(0, 0),
        const HexCoord(1, 0),
      };

      final gen1 = InkStep.step(active: seed, radius: 8, generation: 1, rules: rules);

      expect(gen1, equals({...seed, const HexCoord(-1, 0)}));
    });

    test('rule E serif flare: a pulse generation fans the tip forward, not sideways into the body', () {
      // Default rules: A, B, E all on, cadence 4 -- generation 4 is a pulse.
      const rules = InkRules();
      final seed = <HexCoord>{
        const HexCoord(-1, 0),
        const HexCoord(0, 0),
        const HexCoord(1, 0),
      };

      final gen4 = InkStep.step(active: seed, radius: 8, generation: 4, rules: rules);

      // The leading tip (1,0) gains the straight continuation (Rule B) plus
      // the two forward diagonals (Rule E) -- each of these three empties
      // touches ONLY the tip (exactly one active neighbor).
      expect(gen4, contains(const HexCoord(2, 0))); // straight continuation
      expect(gen4, contains(const HexCoord(2, -1))); // forward diagonal
      expect(gen4, contains(const HexCoord(1, 1))); // forward diagonal

      // The two backward diagonals touch BOTH (1,0) and (0,0) -- 2 active
      // neighbors -- so Rule E does not fire there: the serif sits at the
      // tip, not along the stroke's side.
      expect(gen4, isNot(contains(const HexCoord(1, -1))));
      expect(gen4, isNot(contains(const HexCoord(0, 1))));

      // (The opposite end (-1,0) mirrors this same forward fan by the
      // identical symmetric rule -- expected, and not what's under test
      // here. The interior cell (0,0) gains nothing: it already has 2
      // active neighbors, so neither B nor E ever fires there.)
    });

    test('rule E alone: only exactly-one-neighbor empties fire; a 2-neighbor flanking cell never does', () {
      const rules = InkRules(ruleA: false, ruleB: false, ruleE: true, cadence: 4);
      final seed = <HexCoord>{
        const HexCoord(-1, 0),
        const HexCoord(0, 0),
        const HexCoord(1, 0),
      };

      final gen4 = InkStep.step(active: seed, radius: 8, generation: 4, rules: rules);

      // Every empty touching the tip at exactly 1 active neighbor fires --
      // direction doesn't matter to Rule E, only the neighbor count does.
      expect(gen4, contains(const HexCoord(2, 0)));
      expect(gen4, contains(const HexCoord(2, -1)));
      expect(gen4, contains(const HexCoord(1, 1)));

      // Cells flanking the stroke's body touch TWO active cells, so they
      // never satisfy "exactly one" and never fire, on any cadence.
      expect(gen4, isNot(contains(const HexCoord(1, -1))));
      expect(gen4, isNot(contains(const HexCoord(0, 1))));
    });

    test('cells never deactivate across steps', () {
      const rules = InkRules();
      final seed = <HexCoord>{const HexCoord(0, 0)};
      var gen = seed;
      for (var g = 1; g <= 5; g++) {
        final next = InkStep.step(active: gen, radius: 8, generation: g, rules: rules);
        expect(next, containsAll(gen));
        gen = next;
      }
    });
  });

  group('InkStep.borderContactGeneration', () {
    test('returns null until an outer-ring cell is active', () {
      final history = <Set<HexCoord>>[
        {const HexCoord(0, 0)},
        {const HexCoord(0, 0), const HexCoord(1, 0)},
      ];
      expect(InkStep.borderContactGeneration(history, 8), isNull);
    });

    test('returns the first generation index touching the border ring', () {
      final history = <Set<HexCoord>>[
        {const HexCoord(0, 0)},
        {const HexCoord(8, 0)}, // radius-8 border cell
      ];
      expect(InkStep.borderContactGeneration(history, 8), equals(1));
    });
  });
}
