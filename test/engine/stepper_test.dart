import 'package:test/test.dart';
import 'package:rune_duel/engine/element.dart';
import 'package:rune_duel/engine/hex_grid.dart';
import 'package:rune_duel/engine/stepper.dart';

void main() {
  // No directional bias — keeps most tests simple.
  const noDirection = <Element, int>{};

  // Build a grid with specific cells already set.
  HexGrid makeGrid(Map<HexCoord, Element> setup) {
    final grid = HexGrid(4);
    for (final e in setup.entries) {
      grid.setState(e.value, e.key);
    }
    return grid;
  }

  // ── Empty cell rules ────────────────────────────────────────────────────────

  group('empty cell', () {
    test('stays empty with only 1 fire neighbor', () {
      final grid = makeGrid({
        HexCoord(1, 0): Element.fire,
      });
      final result = CAStep.step(grid, noDirection);
      expect(result.state(HexCoord(0, 0)), Element.empty);
    });

    test('becomes fire when surrounded by 3 fire neighbors', () {
      final grid = makeGrid({
        HexCoord(1,  0): Element.fire,
        HexCoord(1, -1): Element.fire,
        HexCoord(0, -1): Element.fire,
      });
      final result = CAStep.step(grid, noDirection);
      expect(result.state(HexCoord(0, 0)), Element.fire);
    });

    test('becomes fireWater when fire and water each contribute 3 neighbors', () {
      // 3 fire neighbors on one side, 3 water on the other.
      // Both are independently eligible → the cell becomes their hybrid.
      final grid = makeGrid({
        HexCoord( 1,  0): Element.fire,
        HexCoord( 1, -1): Element.fire,
        HexCoord( 0, -1): Element.fire,
        HexCoord(-1,  0): Element.water,
        HexCoord(-1,  1): Element.water,
        HexCoord( 0,  1): Element.water,
      });
      final result = CAStep.step(grid, noDirection);
      expect(result.state(HexCoord(0, 0)), Element.fireWater);
    });

    test('becomes chaos when 3 pure elements are each eligible', () {
      // 3 fireWater neighbors → fire score 3, water score 3 (each eligible).
      // 3 earth neighbors → earth score 3 (eligible).
      // 3 eligible elements → can't resolve to a single hybrid → chaos.
      final grid = makeGrid({
        HexCoord( 1,  0): Element.fireWater,
        HexCoord( 1, -1): Element.fireWater,
        HexCoord( 0, -1): Element.fireWater,
        HexCoord(-1,  0): Element.earth,
        HexCoord(-1,  1): Element.earth,
        HexCoord( 0,  1): Element.earth,
      });
      final result = CAStep.step(grid, noDirection);
      expect(result.state(HexCoord(0, 0)), Element.chaos);
    });

    test('becomes voidEl when 3 pure elements each saturate at count 4', () {
      // 2 fireWater + 2 fireEarth + 2 waterEarth:
      //   fire   = 2+2   = 4
      //   water  = 2+2   = 4
      //   earth  = 2+2   = 4
      // Three elements at count >= 4 simultaneously → void, even on an empty cell.
      final grid = makeGrid({
        HexCoord( 1,  0): Element.fireWater,
        HexCoord( 1, -1): Element.fireWater,
        HexCoord( 0, -1): Element.fireEarth,
        HexCoord(-1,  0): Element.fireEarth,
        HexCoord(-1,  1): Element.waterEarth,
        HexCoord( 0,  1): Element.waterEarth,
      });
      final result = CAStep.step(grid, noDirection);
      expect(result.state(HexCoord(0, 0)), Element.voidEl);
    });
  });

  // ── Active cell — pure element ───────────────────────────────────────────────

  group('active cell — pure element', () {
    test('fire survives with 3 same-type neighbors', () {
      final grid = makeGrid({
        HexCoord(0,  0): Element.fire,
        HexCoord(1,  0): Element.fire,
        HexCoord(1, -1): Element.fire,
        HexCoord(0, -1): Element.fire,
      });
      final result = CAStep.step(grid, noDirection);
      expect(result.state(HexCoord(0, 0)), Element.fire);
    });

    test('fire dies with 4 same-type neighbors (overpopulation)', () {
      final grid = makeGrid({
        HexCoord( 0,  0): Element.fire,
        HexCoord( 1,  0): Element.fire,
        HexCoord( 1, -1): Element.fire,
        HexCoord( 0, -1): Element.fire,
        HexCoord(-1,  0): Element.fire,
      });
      final result = CAStep.step(grid, noDirection);
      expect(result.state(HexCoord(0, 0)), Element.empty);
    });
  });

  // ── Void — overrides active cells too ───────────────────────────────────────

  group('void — state-independent', () {
    test('active fire cell becomes voidEl under triple saturation', () {
      // Same neighbour setup as the empty-cell void test, but the centre is fire.
      // Void overrides active cell resolution.
      final grid = makeGrid({
        HexCoord( 0,  0): Element.fire,
        HexCoord( 1,  0): Element.fireWater,
        HexCoord( 1, -1): Element.fireWater,
        HexCoord( 0, -1): Element.fireEarth,
        HexCoord(-1,  0): Element.fireEarth,
        HexCoord(-1,  1): Element.waterEarth,
        HexCoord( 0,  1): Element.waterEarth,
      });
      final result = CAStep.step(grid, noDirection);
      expect(result.state(HexCoord(0, 0)), Element.voidEl);
    });
  });

  // ── Active cell — hybrid ─────────────────────────────────────────────────────

  group('active cell — hybrid', () {
    test('fireWater survives when neither component reaches 4', () {
      final grid = makeGrid({
        HexCoord(0,  0): Element.fireWater,
        HexCoord(1,  0): Element.fire,
        HexCoord(1, -1): Element.fire,   // fire count = 2, safe
        HexCoord(0, -1): Element.water,  // water count = 1, safe
      });
      final result = CAStep.step(grid, noDirection);
      expect(result.state(HexCoord(0, 0)), Element.fireWater);
    });

    test('fireWater dies when fire component reaches 4', () {
      final grid = makeGrid({
        HexCoord( 0,  0): Element.fireWater,
        HexCoord( 1,  0): Element.fire,
        HexCoord( 1, -1): Element.fire,
        HexCoord( 0, -1): Element.fire,
        HexCoord(-1,  0): Element.fire,  // fire count = 4 → collapse
      });
      final result = CAStep.step(grid, noDirection);
      expect(result.state(HexCoord(0, 0)), Element.empty);
    });
  });
}
