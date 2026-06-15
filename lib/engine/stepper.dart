import 'border_zones.dart';
import 'ca_rules.dart';
import 'element.dart';
import 'hex_grid.dart';

class CAStep {
  static HexGrid step(HexGrid grid, CARules rules) {
    final next = grid.copy();
    next.stepCount++;

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
}
