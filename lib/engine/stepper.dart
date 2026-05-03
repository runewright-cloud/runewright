import 'element.dart';
import 'hex_grid.dart';

class CAStep {
  // Compute the next generation of the grid.
  // [direction] maps each pure element to its preferred growth direction.
  static HexGrid step(HexGrid grid, Map<Element, int> direction) {
    final next = grid.copy();
    next.stepCount++;

    for (final entry in grid.cells.entries) {
      final coord = entry.key;
      final state = entry.value;
      final neighborStates =
          grid.neighbors(coord).map((p) => p.$2).toList();

      // Outermost ring cells always deactivate — they can be born but never survive.
      if (state != Element.empty && grid.isBorder(coord)) {
        next.cells[coord] = Element.empty;
        final bucket = next.borderTriggers.putIfAbsent(coord, () => {});
        final comps = state.components;
        if (comps != null) {
          bucket[comps.$1] = (bucket[comps.$1] ?? 0) + 1;
          bucket[comps.$2] = (bucket[comps.$2] ?? 0) + 1;
        } else {
          bucket[state] = (bucket[state] ?? 0) + 1;
        }
        continue;
      }

      // Void check: triple saturation overrides everything.
      // Chaos counts as one saturating entity here, not as all four elements,
      // so its contribution is a single slot rather than pushing every element count up.
      final nonChaosNeighbors = neighborStates.where((n) => n != Element.chaos).toList();
      final chaosBonus = neighborStates.any((n) => n == Element.chaos) ? 1 : 0;
      final saturatedCount = _pureElements
          .where((e) => _neighborCount(e, nonChaosNeighbors) + chaosBonus >= 3)
          .length;
      if (saturatedCount >= 3) {
        next.cells[coord] = Element.voidEl;
        continue;
      }

      next.cells[coord] = state == Element.empty
          ? _resolveEmpty(
              coord: coord,
              neighborStates: neighborStates,
              grid: grid,
              direction: direction,
            )
          : _resolveActive(
              coord: coord,
              state: state,
              neighborStates: neighborStates,
              grid: grid,
              direction: direction,
            );
    }

    // Chaos corruptor pass: any cell — active or empty — that would transition
    // to a new element while adjacent to a current chaos cell becomes chaos
    // instead. Void transitions and stable cells are not affected.
    for (final coord in grid.cells.keys) {
      final currentState = grid.cells[coord]!;
      final nextState = next.cells[coord]!;
      if (currentState == nextState) continue; // stable — not transitioning
      if (nextState == Element.empty) continue; // dying cells, not a transition
      if (nextState == Element.voidEl) continue; // void is immune to chaos
      if (nextState == Element.chaos) continue;  // already becoming chaos
      if (grid.neighbors(coord).any((p) => p.$2 == Element.chaos)) {
        next.cells[coord] = Element.chaos;
      }
    }

    // Void expansion pass: any active cell that just died (→ empty) while
    // adjacent to a current void cell becomes void instead of empty.
    for (final coord in grid.cells.keys) {
      final currentState = grid.cells[coord]!;
      final nextState = next.cells[coord]!;
      if (nextState != Element.empty) continue;
      if (currentState == Element.empty) continue; // was already empty
      if (grid.neighbors(coord).any((p) => p.$2 == Element.voidEl)) {
        next.cells[coord] = Element.voidEl;
      }
    }

    return next;
  }

  // ---------------------------------------------------------------------------
  // Empty cell resolution

  static Element _resolveEmpty({
    required HexCoord coord,
    required List<Element> neighborStates,
    required HexGrid grid,
    required Map<Element, int> direction,
  }) {
    if (_neighborCount(Element.chaos, neighborStates) >= 3) return Element.chaos;

    final eligible = _pureElements
        .where((e) => _growthPower(e, coord, neighborStates, grid, direction) > 0)
        .toList();

    switch (eligible.length) {
      case 0:
        return Element.empty;
      case 1:
        return eligible[0];
      case 2:
        return _hybrid(eligible[0], eligible[1])!;
      default:
        return Element.chaos;
    }
  }

  // ---------------------------------------------------------------------------
  // Active cell resolution (with overwrite check)

  static Element _resolveActive({
    required HexCoord coord,
    required Element state,
    required List<Element> neighborStates,
    required HexGrid grid,
    required Map<Element, int> direction,
  }) {
    // Void is permanent — immune to death and overwrite.
    if (state == Element.voidEl) return state;

    // Chaos follows loneliness / overpopulation rules; cannot be overwritten.
    if (state == Element.chaos) {
      final count = _neighborCount(Element.chaos, neighborStates);
      return (count < 2 || count >= 4) ? Element.empty : state;
    }

    // Check if any foreign element can overwrite this cell.
    final defense = _defenseScore(state, neighborStates);
    final overwriters = _pureElements.where((y) {
      if (y == state) return false;
      final comps = state.components;
      if (comps != null && (comps.$1 == y || comps.$2 == y)) return false;
      return _growthPower(y, coord, neighborStates, grid, direction) > defense;
    }).toList();

    if (overwriters.isNotEmpty) {
      switch (overwriters.length) {
        case 1:
          return overwriters[0];
        case 2:
          return _hybrid(overwriters[0], overwriters[1]) ?? Element.chaos;
        default:
          return Element.chaos;
      }
    }

    // Normal survival rules. Void neighbors count toward both loneliness and
    // overpopulation pressure on all elemental cells.
    final voidPressure = neighborStates.where((n) => n == Element.voidEl).length;

    if (state.isInscribable) {
      final count = _neighborCount(state, neighborStates) + voidPressure;
      return (count < 2 || count >= 4) ? Element.empty : state;
    }

    if (state.isHybrid) {
      final comps = state.components!;
      final countA = _neighborCount(comps.$1, neighborStates) + voidPressure;
      final countB = _neighborCount(comps.$2, neighborStates) + voidPressure;
      if (countA < 2 && countB < 2) return Element.empty;
      final aOver = countA >= 4;
      final bOver = countB >= 4;
      if (aOver && bOver) return Element.empty;
      if (aOver) return comps.$2;
      if (bOver) return comps.$1;
      return state;
    }

    return state;
  }

  // ---------------------------------------------------------------------------
  // Helpers

  static double _growthPower(
    Element element,
    HexCoord coord,
    List<Element> neighborStates,
    HexGrid grid,
    Map<Element, int> direction,
  ) {
    final count = _neighborCount(element, neighborStates);
    if (count >= 3) return count.toDouble();
    if (count == 2) {
      final dirIndex = direction[element];
      if (dirIndex == null) return 0;
      final offset = HexGrid.clockwiseDirections[(dirIndex + 3) % 6];
      final sourceCoord = HexCoord(coord.q + offset.q, coord.r + offset.r);
      final sourceState = grid.cells[sourceCoord];
      if (sourceState != null && sourceState != Element.chaos &&
          _neighborCount(element, [sourceState]) > 0) {
        return 2.5;
      }
    }
    return 0;
  }

  static double _defenseScore(Element state, List<Element> neighborStates) {
    if (state.isInscribable) {
      return _neighborCount(state, neighborStates).toDouble();
    }
    if (state.isHybrid) {
      final comps = state.components!;
      final a = _neighborCount(comps.$1, neighborStates);
      final b = _neighborCount(comps.$2, neighborStates);
      return (a > b ? a : b).toDouble();
    }
    return double.infinity;
  }

  static int _neighborCount(Element element, List<Element> neighbors) {
    return neighbors.where((n) {
      if (n == element) return true;
      // Chaos counts as all 4 pure elements in every elemental calculation.
      if (n == Element.chaos && element != Element.chaos) return true;
      final comps = n.components;
      return comps != null && (comps.$1 == element || comps.$2 == element);
    }).length;
  }

  static Element? _hybrid(Element a, Element b) {
    final pair = {a, b};
    if (pair.containsAll([Element.fire,  Element.water])) return Element.fireWater;
    if (pair.containsAll([Element.fire,  Element.earth])) return Element.fireEarth;
    if (pair.containsAll([Element.fire,  Element.air]))   return Element.fireAir;
    if (pair.containsAll([Element.water, Element.earth])) return Element.waterEarth;
    if (pair.containsAll([Element.water, Element.air]))   return Element.waterAir;
    if (pair.containsAll([Element.earth, Element.air]))   return Element.earthAir;
    return null;
  }

  static const _pureElements = [
    Element.fire, Element.water, Element.earth, Element.air,
  ];
}
