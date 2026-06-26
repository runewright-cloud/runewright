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
  // Populated by CAStep.step; reset to empty on copy(). Tracks which border
  // cells received a countable activation in the most recent step — used by
  // HexGridPainter to drive the per-cell flicker+glow effect.
  final Set<HexCoord> lastActivatedBorderCells;
  int stepCount;

  HexGrid(this.radius) : cells = {}, zoneActivations = {}, lastActivatedBorderCells = {}, stepCount = 0 {
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
        zoneActivations = Map.of(sourceActivations),
        lastActivatedBorderCells = {};

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

  /// Flattens this grid into the canonical packed `grid_state` witness
  /// array the circuit expects: one 0/1 per cell, in q-major/r-minor order
  /// (index 0 = (-radius, 0)) -- see circuits/GRID_ORDERING_v2.md. This is
  /// exactly the constructor's insertion order, and every mutation in this
  /// codebase (CAStep.step, copy(), setState) only ever updates values at
  /// existing keys, never the key set -- so a grid's Map iteration order is
  /// fixed for its whole lifetime and always matches the canonical order.
  List<int> packGridState() =>
      cells.values.map((e) => e == Element.alive ? 1 : 0).toList(growable: false);

  /// Inverse of [packGridState]: reconstruct a HexGrid from the flat 0/1 list
  /// produced by that method. The cell ordering is the constructor's q-major
  /// insertion order, identical to the canonical circuit order, so the
  /// round-trip is exact. Used by SpellViewScreen to replay an inscribed spell
  /// without re-running the prover.
  ///
  /// NOTE: [flatState] is local-only (SpellAsset.initialGrid). It is never
  /// included in proof payloads or shared with opponents — only the commitment
  /// and proof bytes cross the wire in battle.
  static HexGrid fromPackedState(List<int> flatState, int radius) {
    final g = HexGrid(radius);
    final coords = g.cells.keys.toList();
    assert(flatState.length == coords.length,
        'flatState length ${flatState.length} != expected ${coords.length}');
    for (int i = 0; i < flatState.length; i++) {
      if (flatState[i] == 1) g.cells[coords[i]] = Element.alive;
    }
    return g;
  }
}
