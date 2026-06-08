import 'dart:math';
import 'border_zone.dart';
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
// Sparse representation: only valid coords are stored (all initialised to dead).
class HexGrid {
  final int radius;
  final Map<HexCoord, Element> cells;
  final Map<BorderZone, int> zoneActivations;
  int stepCount;

  HexGrid(this.radius) : cells = {}, zoneActivations = {}, stepCount = 0 {
    for (int q = -radius; q <= radius; q++) {
      final r1 = max(-radius, -q - radius);
      final r2 = min(radius, -q + radius);
      for (int r = r1; r <= r2; r++) {
        cells[HexCoord(q, r)] = Element.dead;
      }
    }
  }

  HexGrid._copy(
    this.radius,
    Map<HexCoord, Element> source,
    this.stepCount,
    Map<BorderZone, int> sourceActivations,
  )   : cells = Map.of(source),
        zoneActivations = Map.of(sourceActivations);

  HexGrid copy() => HexGrid._copy(radius, cells, stepCount, zoneActivations);

  Element? state(HexCoord coord) => cells[coord];

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

  static const List<HexCoord> directions = [
    HexCoord( 1,  0),
    HexCoord( 1, -1),
    HexCoord( 0, -1),
    HexCoord(-1,  0),
    HexCoord(-1,  1),
    HexCoord( 0,  1),
  ];

  static const List<HexCoord> clockwiseDirections = [
    HexCoord( 0, -1), // 0 top
    HexCoord( 1, -1), // 1 top-right
    HexCoord( 1,  0), // 2 bottom-right
    HexCoord( 0,  1), // 3 bottom
    HexCoord(-1,  1), // 4 bottom-left
    HexCoord(-1,  0), // 5 top-left
  ];

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
