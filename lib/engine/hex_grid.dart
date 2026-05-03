import 'dart:math';
import 'element.dart';

// Axial coordinates — standard for hex grids.
// q = column, r = row in a pointy-top hex layout.
class HexCoord {
  final int q;
  final int r;

  const HexCoord(this.q, this.r);

  @override
  bool operator ==(Object other) =>
      other is HexCoord && other.q == q && other.r == r;

  @override
  int get hashCode => Object.hash(q, r);

  @override
  String toString() => 'HexCoord($q, $r)';
}

// The grid — a flat dictionary of coord -> state.
// Sparse representation: only valid coords are stored (all initialised to empty).
class HexGrid {
  final int radius;
  final Map<HexCoord, Element> cells;
  final Map<HexCoord, Map<Element, int>> borderTriggers;
  int stepCount;

  HexGrid(this.radius) : cells = {}, borderTriggers = {}, stepCount = 0 {
    for (int q = -radius; q <= radius; q++) {
      final r1 = max(-radius, -q - radius);
      final r2 = min(radius, -q + radius);
      for (int r = r1; r <= r2; r++) {
        cells[HexCoord(q, r)] = Element.empty;
      }
    }
  }

  // Private constructor used by [copy].
  HexGrid._copy(this.radius, Map<HexCoord, Element> source, this.stepCount,
      Map<HexCoord, Map<Element, int>> sourceTriggers)
      : cells = Map.of(source),
        borderTriggers = {
          for (final e in sourceTriggers.entries) e.key: Map.of(e.value)
        };

  // Returns a shallow copy — cells map is duplicated so mutations don't alias.
  HexGrid copy() => HexGrid._copy(radius, cells, stepCount, borderTriggers);

  // Returns null if coord is outside the grid.
  Element? state(HexCoord coord) => cells[coord];

  // Silently ignores coords outside the grid.
  void setState(Element element, HexCoord coord) {
    if (cells.containsKey(coord)) {
      cells[coord] = element;
    }
  }

  bool isBorder(HexCoord coord) {
    return [coord.q.abs(), coord.r.abs(), (coord.q + coord.r).abs()]
            .reduce(max) ==
        radius;
  }

  // Neighbour offsets — order is arbitrary, used only for iteration.
  static const List<HexCoord> directions = [
    HexCoord( 1,  0),
    HexCoord( 1, -1),
    HexCoord( 0, -1),
    HexCoord(-1,  0),
    HexCoord(-1,  1),
    HexCoord( 0,  1),
  ];

  // Clockwise from top (flat-top layout): index 0 = top, 1 = top-right, …, 5 = top-left.
  static const List<HexCoord> clockwiseDirections = [
    HexCoord( 0, -1), // 0 top
    HexCoord( 1, -1), // 1 top-right
    HexCoord( 1,  0), // 2 bottom-right
    HexCoord( 0,  1), // 3 bottom
    HexCoord(-1,  1), // 4 bottom-left
    HexCoord(-1,  0), // 5 top-left
  ];

  // Returns all (coord, state) pairs for valid neighbours of [coord].
  List<(HexCoord, Element)> neighbors(HexCoord coord) {
    final result = <(HexCoord, Element)>[];
    for (final dir in directions) {
      final neighbor = HexCoord(coord.q + dir.q, coord.r + dir.r);
      final s = cells[neighbor];
      if (s != null) result.add((neighbor, s));
    }
    return result;
  }
}
