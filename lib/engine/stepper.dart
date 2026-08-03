import 'border_zones.dart';
import 'ca_rules.dart';
import 'element.dart';
import 'hex_grid.dart';
import 'ink_step.dart';

class CAStep {
  static HexGrid step(HexGrid grid, CARules rules) {
    final next = grid.copy();
    next.stepCount++;

    if (rules.isNeutral) {
      return _stepInk(grid, next);
    }

    for (final entry in grid.cells.entries) {
      final coord = entry.key;
      final state = entry.value;

      if (grid.isBorder(coord)) {
        if (state == Element.alive) {
          // Alive border cells always die the following step.
          next.cells[coord] = Element.dead;
        } else {
          // Dead border cells: count the activation but stay dead.
          // They must never become alive so they don't sit occupied across
          // a step or count as neighbours for ring-11 cells — either effect
          // would suppress future activations on the same border cell.
          final aliveNeighbors = grid.neighbors(coord)
              .where((p) => p.$2 == Element.alive)
              .length;
          if (rules.bornOn.contains(aliveNeighbors)) {
            final zone = BorderZones.forRadius(grid.radius)[coord];
            if (zone != null) {
              next.zoneActivations[zone] =
                  (next.zoneActivations[zone] ?? 0) + 1;
              next.lastActivatedBorderCells.add(coord);
            }
          }
        }
        continue;
      }

      final aliveNeighbors =
          grid.neighbors(coord).where((p) => p.$2 == Element.alive).length;

      final survives = state == Element.alive && rules.surviveOn.contains(aliveNeighbors);
      final born     = state == Element.dead  && rules.bornOn.contains(aliveNeighbors);

      next.cells[coord] = (survives || born) ? Element.alive : Element.dead;
    }

    return next;
  }

  /// Neutral substrate: the axis-based "ink" ruleset (ink_step.dart),
  /// reusing the exact same `InkStep.step` the playtest sandbox calls --
  /// one implementation, not a divergent copy. `next` is already
  /// `grid.copy()` with `stepCount` incremented (so `next.stepCount` is
  /// the generation being produced -- 1 for the first step from a seed,
  /// matching InkStep.step's `generation` contract).
  static HexGrid _stepInk(HexGrid grid, HexGrid next) {
    final active = <HexCoord>{
      for (final entry in grid.cells.entries)
        if (entry.value == Element.alive) entry.key,
    };

    // const InkRules() defaults: A/B/E on (no C -- collision burst was
    // removed in favor of Rule E's serif pulse), cadence 4.
    final nextActive = InkStep.step(
      active: active,
      radius: grid.radius,
      generation: next.stepCount,
      rules: const InkRules(),
    );

    for (final coord in next.cells.keys) {
      if (grid.isBorder(coord)) {
        // BORDER OVERRIDES RULE D: the border ring is a write-only
        // activation sink and must always die back to dead the generation
        // after it activates -- "no deaths" applies to the inscribable +
        // buffer region only, never the border ring. Getting this wrong
        // makes border cells permanent and corrupts dominance counting.
        if (nextActive.contains(coord) && !active.contains(coord)) {
          // BorderZones.forRadius hardcodes 4x18-cell segments that are
          // only geometrically correct at radius 12 (the production grid)
          // -- see border_zones.dart. This assert catches a wrong-radius
          // integration in debug rather than silently mis-zoning.
          assert(grid.radius == 12, 'BorderZones is only valid at radius 12');
          final zone = BorderZones.forRadius(grid.radius)[coord];
          if (zone != null) {
            next.zoneActivations[zone] =
                (next.zoneActivations[zone] ?? 0) + 1;
            next.lastActivatedBorderCells.add(coord);
          }
        }
        next.cells[coord] = Element.dead;
      } else {
        next.cells[coord] = nextActive.contains(coord) ? Element.alive : Element.dead;
      }
    }

    return next;
  }
}
