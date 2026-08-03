// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:test/test.dart';
import 'package:rune_duel/engine/border_zone.dart';
import 'package:rune_duel/engine/border_zones.dart';
import 'package:rune_duel/engine/ca_rules.dart';
import 'package:rune_duel/engine/ca_run.dart';
import 'package:rune_duel/engine/element.dart';
import 'package:rune_duel/engine/hex_grid.dart';
import 'package:rune_duel/engine/stepper.dart';

void main() {
  HexGrid makeGrid(int radius, Map<HexCoord, Element> setup) {
    final grid = HexGrid(radius);
    for (final e in setup.entries) {
      grid.setState(e.value, e.key);
    }
    return grid;
  }

  int aliveCount(HexGrid grid) =>
      grid.cells.values.where((e) => e == Element.alive).length;

  // ── Count-based rule path (fire, earth) ────────────────────────────────────
  //
  // Repointed from the old CARules.neutral Conway-2/2 tests. After the
  // neutral dispatch change, CARules.neutral no longer reaches the
  // count-based loop in CAStep.step at all -- this file is the only place
  // that calls CAStep.step end-to-end with assertions, so without this
  // repointing the count-based loop body would have zero direct test
  // coverage at the exact moment it's being edited. Fire (B1/S1) exercises
  // the birth-and-death branch; earth (B2/S-any) exercises "survives on any
  // nonzero neighbor count" separately.

  group('count-based rule path (fire, B1/S1)', () {
    test('dead cell stays dead with 0 alive neighbors', () {
      final grid = makeGrid(4, {});
      final result = CAStep.step(grid, CARules.fire);
      expect(result.state(const HexCoord(0, 0)), Element.dead);
    });

    test('dead cell is born with exactly 1 alive neighbor', () {
      final grid = makeGrid(4, {const HexCoord(1, 0): Element.alive});
      final result = CAStep.step(grid, CARules.fire);
      expect(result.state(const HexCoord(0, 0)), Element.alive);
    });

    test('dead cell stays dead with 2 alive neighbors (not in bornOn)', () {
      final grid = makeGrid(4, {
        const HexCoord(1, 0): Element.alive,
        const HexCoord(1, -1): Element.alive,
      });
      final result = CAStep.step(grid, CARules.fire);
      expect(result.state(const HexCoord(0, 0)), Element.dead);
    });

    test('alive cell dies with 0 alive neighbors (isolation)', () {
      final grid = makeGrid(4, {const HexCoord(0, 0): Element.alive});
      final result = CAStep.step(grid, CARules.fire);
      expect(result.state(const HexCoord(0, 0)), Element.dead);
    });

    test('alive cell survives with exactly 1 alive neighbor', () {
      final grid = makeGrid(4, {
        const HexCoord(0, 0): Element.alive,
        const HexCoord(1, 0): Element.alive,
      });
      final result = CAStep.step(grid, CARules.fire);
      expect(result.state(const HexCoord(0, 0)), Element.alive);
    });

    test('alive cell dies with 2 alive neighbors (not in surviveOn)', () {
      final grid = makeGrid(4, {
        const HexCoord(0, 0): Element.alive,
        const HexCoord(1, 0): Element.alive,
        const HexCoord(1, -1): Element.alive,
      });
      final result = CAStep.step(grid, CARules.fire);
      expect(result.state(const HexCoord(0, 0)), Element.dead);
    });
  });

  group('count-based rule path (earth, B2/S-any)', () {
    test('dead cell stays dead with 0 alive neighbors', () {
      final grid = makeGrid(4, {});
      final result = CAStep.step(grid, CARules.earth);
      expect(result.state(const HexCoord(0, 0)), Element.dead);
    });

    test('dead cell stays dead with 1 alive neighbor (not in bornOn)', () {
      final grid = makeGrid(4, {const HexCoord(1, 0): Element.alive});
      final result = CAStep.step(grid, CARules.earth);
      expect(result.state(const HexCoord(0, 0)), Element.dead);
    });

    test('dead cell is born with exactly 2 alive neighbors', () {
      final grid = makeGrid(4, {
        const HexCoord(1, 0): Element.alive,
        const HexCoord(1, -1): Element.alive,
      });
      final result = CAStep.step(grid, CARules.earth);
      expect(result.state(const HexCoord(0, 0)), Element.alive);
    });

    test('dead cell stays dead with 3 alive neighbors (not in bornOn)', () {
      final grid = makeGrid(4, {
        const HexCoord(1, 0): Element.alive,
        const HexCoord(1, -1): Element.alive,
        const HexCoord(0, -1): Element.alive,
      });
      final result = CAStep.step(grid, CARules.earth);
      expect(result.state(const HexCoord(0, 0)), Element.dead);
    });

    test('alive cell dies with 0 alive neighbors (isolation, not in surviveOn)', () {
      final grid = makeGrid(4, {const HexCoord(0, 0): Element.alive});
      final result = CAStep.step(grid, CARules.earth);
      expect(result.state(const HexCoord(0, 0)), Element.dead);
    });

    test('alive cell survives with exactly 1 alive neighbor', () {
      final grid = makeGrid(4, {
        const HexCoord(0, 0): Element.alive,
        const HexCoord(1, 0): Element.alive,
      });
      final result = CAStep.step(grid, CARules.earth);
      expect(result.state(const HexCoord(0, 0)), Element.alive);
    });

    test('alive cell survives with all 6 alive neighbors (survives on any nonzero count)', () {
      final grid = makeGrid(4, {
        const HexCoord(0, 0): Element.alive,
        const HexCoord(1, 0): Element.alive,
        const HexCoord(1, -1): Element.alive,
        const HexCoord(0, -1): Element.alive,
        const HexCoord(-1, 0): Element.alive,
        const HexCoord(-1, 1): Element.alive,
        const HexCoord(0, 1): Element.alive,
      });
      final result = CAStep.step(grid, CARules.earth);
      expect(result.state(const HexCoord(0, 0)), Element.alive);
    });
  });

  // ── Ink neutral substrate ────────────────────────────────────────────────

  group('ink neutral: straight stroke', () {
    test('both free ends extend by exactly one cell per generation; interior is static', () {
      final grid = makeGrid(4, {
        const HexCoord(-1, 0): Element.alive,
        const HexCoord(0, 0): Element.alive,
        const HexCoord(1, 0): Element.alive,
      });

      final gen1 = CAStep.step(grid, CARules.neutral);
      for (final c in const [
        HexCoord(-2, 0), HexCoord(-1, 0), HexCoord(0, 0), HexCoord(1, 0), HexCoord(2, 0),
      ]) {
        expect(gen1.state(c), Element.alive, reason: '$c should be alive at gen1');
      }
      expect(aliveCount(gen1), equals(5));

      final gen2 = CAStep.step(gen1, CARules.neutral);
      for (final c in const [HexCoord(-3, 0), HexCoord(3, 0)]) {
        expect(gen2.state(c), Element.alive, reason: '$c should be alive at gen2 (continued extension)');
      }
      expect(aliveCount(gen2), equals(7));
    });
  });

  group('ink neutral: bent stroke', () {
    test('the corner does not produce a star; only the two free ends extend', () {
      final grid = makeGrid(4, {
        const HexCoord(-2, 0): Element.alive,
        const HexCoord(-1, 0): Element.alive,
        const HexCoord(0, 0): Element.alive,
        const HexCoord(1, -1): Element.alive,
        const HexCoord(2, -2): Element.alive,
      });

      final gen1 = CAStep.step(grid, CARules.neutral);
      expect(gen1.state(const HexCoord(-3, 0)), Element.alive);
      expect(gen1.state(const HexCoord(3, -3)), Element.alive);
      // 5 seed cells + 2 new tips, no star at the corner.
      expect(aliveCount(gen1), equals(7));
    });
  });

  // ── Border interaction (radius 12 -- BorderZones is only valid there) ──────

  group('ink neutral: border override', () {
    test('a border cell whose neighbors complete an ink axis still dies, but the activation is counted', () {
      // (12,-6) is a non-corner border cell. Its only valid antipodal pair
      // is the one running parallel to the ring -- (12,-7)/(12,-5) -- since
      // its other two pairs always have one off-grid side at the border.
      // Seeding both flanking border cells completes that axis via Rule A.
      final grid = makeGrid(12, {
        const HexCoord(12, -7): Element.alive,
        const HexCoord(12, -5): Element.alive,
      });
      final zone = BorderZones.forRadius(12)[const HexCoord(12, -6)]!;

      final result = CAStep.step(grid, CARules.neutral);

      // BORDER OVERRIDES RULE D: (12,-6) activates under ink's Rule A, but
      // must die back to dead this same step -- only the activation event
      // survives, as a zoneActivations bump, exactly like the count-rule
      // branch's border handling. Getting this wrong makes border cells
      // permanent and corrupts dominance counting.
      expect(result.state(const HexCoord(12, -6)), Element.dead);
      expect(result.zoneActivations[zone], equals(1));
    });
  });

  group('ink neutral: buffer tip-extension reaching the border', () {
    test('a Rule B extension that lands on a border cell activates-then-dies it and counts the activation', () {
      // (11,-6) is the tip with exactly one active neighbor (10,-6); its
      // Rule B antipode extension lands on (12,-6), a border cell.
      final grid = makeGrid(12, {
        const HexCoord(10, -6): Element.alive,
        const HexCoord(11, -6): Element.alive,
      });
      final zone = BorderZones.forRadius(12)[const HexCoord(12, -6)]!;

      final result = CAStep.step(grid, CARules.neutral);

      expect(result.state(const HexCoord(10, -6)), Element.alive);
      expect(result.state(const HexCoord(11, -6)), Element.alive);
      expect(result.state(const HexCoord(12, -6)), Element.dead); // border override
      expect(result.zoneActivations[zone], equals(1));
    });
  });

  // ── runStepper integration (proves the dispatch path end-to-end) ───────────
  //
  // Calls runStepper -- the dominance-tracking loop in ca_run.dart, not
  // InkStep.step or CAStep.step directly -- so this closes the
  // invisible-failure risk on the dispatch itself: if CARules.isNeutral
  // silently misfired and the count-based loop ran instead of ink, this
  // seed (two cells, each with exactly 1 alive neighbor) would produce
  // zero growth and zero border activations under the OLD Conway 2/2
  // neutral (surviveOn/bornOn = {2}), which a unit test calling InkStep
  // directly could never catch.

  group('runStepper integration (neutral dispatch end-to-end)', () {
    test('ink antipodal extension reaches the border through the full dominance loop', () {
      // Re-derived after Rule C's removal and Rule E's repurposing (serif
      // flare): unchanged. T=1 means CAStep.step computes exactly
      // generation 1 (next.stepCount = 0+1), and 1 % cadence(4) != 0, so
      // Rule E's pulse never fires within this single generation -- only
      // Rule B's straight extension drives (11,-6) into the border, same
      // as before. Rule C never touched this seed either (no complete
      // axis anywhere in it), so this test's expected values are identical
      // to the pre-change ones.
      final grid = HexGrid(12);
      grid.setState(Element.alive, const HexCoord(10, -6));
      grid.setState(Element.alive, const HexCoord(11, -6));
      final zone = BorderZones.forRadius(12)[const HexCoord(12, -6)]!;

      final result = runStepper(grid.packGridState(), 1, 12);

      expect(result.borderActivations[zoneIndex(zone)], equals(1));
      for (final z in BorderZone.values) {
        if (z != zone) expect(result.borderActivations[zoneIndex(z)], equals(0));
      }
    });
  });

  // ── Step count ───────────────────────────────────────────────────────────────

  group('step count', () {
    test('increments each step', () {
      final grid = HexGrid(4);
      final r1 = CAStep.step(grid, CARules.neutral);
      final r2 = CAStep.step(r1, CARules.neutral);
      expect(r1.stepCount, 1);
      expect(r2.stepCount, 2);
    });
  });
}
