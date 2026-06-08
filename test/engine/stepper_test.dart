import 'package:test/test.dart';
import 'package:rune_duel/engine/ca_rules.dart';
import 'package:rune_duel/engine/element.dart';
import 'package:rune_duel/engine/hex_grid.dart';
import 'package:rune_duel/engine/stepper.dart';

void main() {
  HexGrid makeGrid(Map<HexCoord, Element> setup) {
    final grid = HexGrid(4);
    for (final e in setup.entries) {
      grid.setState(e.value, e.key);
    }
    return grid;
  }

  // ── Dead cell rules ─────────────────────────────────────────────────────────

  group('dead cell', () {
    test('stays dead with 0 alive neighbors', () {
      final grid = makeGrid({});
      final result = CAStep.step(grid, CARules.neutral);
      expect(result.state(HexCoord(0, 0)), Element.dead);
    });

    test('stays dead with 1 alive neighbor', () {
      final grid = makeGrid({HexCoord(1, 0): Element.alive});
      final result = CAStep.step(grid, CARules.neutral);
      expect(result.state(HexCoord(0, 0)), Element.dead);
    });

    test('becomes alive with exactly 2 alive neighbors', () {
      final grid = makeGrid({
        HexCoord(1,  0): Element.alive,
        HexCoord(1, -1): Element.alive,
      });
      final result = CAStep.step(grid, CARules.neutral);
      expect(result.state(HexCoord(0, 0)), Element.alive);
    });

    test('stays dead with 3 alive neighbors', () {
      final grid = makeGrid({
        HexCoord(1,  0): Element.alive,
        HexCoord(1, -1): Element.alive,
        HexCoord(0, -1): Element.alive,
      });
      final result = CAStep.step(grid, CARules.neutral);
      expect(result.state(HexCoord(0, 0)), Element.dead);
    });

    test('stays dead with 4 alive neighbors', () {
      final grid = makeGrid({
        HexCoord( 1,  0): Element.alive,
        HexCoord( 1, -1): Element.alive,
        HexCoord( 0, -1): Element.alive,
        HexCoord(-1,  0): Element.alive,
      });
      final result = CAStep.step(grid, CARules.neutral);
      expect(result.state(HexCoord(0, 0)), Element.dead);
    });
  });

  // ── Alive cell rules ────────────────────────────────────────────────────────

  group('alive cell', () {
    test('dies with 0 alive neighbors (isolation)', () {
      final grid = makeGrid({HexCoord(0, 0): Element.alive});
      final result = CAStep.step(grid, CARules.neutral);
      expect(result.state(HexCoord(0, 0)), Element.dead);
    });

    test('dies with 1 alive neighbor (isolation)', () {
      final grid = makeGrid({
        HexCoord(0, 0): Element.alive,
        HexCoord(1, 0): Element.alive,
      });
      final result = CAStep.step(grid, CARules.neutral);
      expect(result.state(HexCoord(0, 0)), Element.dead);
    });

    test('survives with exactly 2 alive neighbors', () {
      final grid = makeGrid({
        HexCoord(0,  0): Element.alive,
        HexCoord(1,  0): Element.alive,
        HexCoord(1, -1): Element.alive,
      });
      final result = CAStep.step(grid, CARules.neutral);
      expect(result.state(HexCoord(0, 0)), Element.alive);
    });

    test('dies with 3 alive neighbors (overpopulation)', () {
      final grid = makeGrid({
        HexCoord(0,  0): Element.alive,
        HexCoord(1,  0): Element.alive,
        HexCoord(1, -1): Element.alive,
        HexCoord(0, -1): Element.alive,
      });
      final result = CAStep.step(grid, CARules.neutral);
      expect(result.state(HexCoord(0, 0)), Element.dead);
    });

    test('dies with 4 alive neighbors (overpopulation)', () {
      final grid = makeGrid({
        HexCoord( 0,  0): Element.alive,
        HexCoord( 1,  0): Element.alive,
        HexCoord( 1, -1): Element.alive,
        HexCoord( 0, -1): Element.alive,
        HexCoord(-1,  0): Element.alive,
      });
      final result = CAStep.step(grid, CARules.neutral);
      expect(result.state(HexCoord(0, 0)), Element.dead);
    });
  });

  // ── Border rule ──────────────────────────────────────────────────────────────

  group('border cells', () {
    test('active border cell always dies', () {
      // Coord (4, 0) is on the border of a radius-4 grid.
      // Give it 2 alive neighbors so it would survive under normal rules.
      final grid = makeGrid({
        HexCoord(4,  0): Element.alive,
        HexCoord(3,  0): Element.alive,
        HexCoord(3,  1): Element.alive, // only 2 neighbors exist on border
      });
      final result = CAStep.step(grid, CARules.neutral);
      expect(result.state(HexCoord(4, 0)), Element.dead);
    });

    test('dead border cell stays dead even with 2 alive neighbors', () {
      final grid = makeGrid({
        HexCoord(3,  0): Element.alive,
        HexCoord(3,  1): Element.alive,
      });
      final result = CAStep.step(grid, CARules.neutral);
      expect(result.state(HexCoord(4, 0)), Element.dead);
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
