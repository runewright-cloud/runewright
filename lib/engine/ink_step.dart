// SPDX-License-Identifier: GPL-3.0-or-later
//
// ink_step.dart — neutral "magic ink" CA step for the playtest sandbox
// (docs/ink_sandbox brief). Throwaway feel-test code: no ZK circuit, no
// dominance/border-sink semantics, no relation to CAStep/CARules (those are
// neighbor-COUNT rulesets; ink is antipodal-AXIS based, which count rules
// can't express). Operates on a sparse `Set<HexCoord>` of active cells
// rather than `HexGrid`/`Element`, since ink has no notion of element state,
// border zones, or dead/alive-with-meaning beyond "drawn or not."
//
// Reuses HexCoord and the same axial neighbor-direction convention as
// hex_grid.dart (HexGrid.directions): directions[i] and directions[(i+3)%6]
// are always the antipodal pair, which is what makes axis-completeness a
// simple index-pairing check below.

import 'dart:math';

import 'hex_grid.dart' show HexCoord;

class InkRules {
  /// Rule A — gap-fill/merge: an inactive cell with >=1 complete axis
  /// (both antipodal endpoints active) becomes active.
  final bool ruleA;

  /// Rule B — tip extension: an active cell with exactly one active
  /// neighbor activates that neighbor's antipode, growing the line straight.
  final bool ruleB;

  /// Rule C — collision burst: any cell (active or not) with >=2 complete
  /// axes activates itself and all in-grid neighbors.
  final bool ruleC;

  /// Rule E — periodic tip-bloom: when `generation % cadence == 0`, an
  /// active cell with exactly one active neighbor activates ALL neighbors.
  final bool ruleE;

  /// Cadence N for rule E. Only meaningful when [ruleE] is true.
  final int cadence;

  const InkRules({
    this.ruleA = true,
    this.ruleB = true,
    this.ruleC = true,
    this.ruleE = false,
    this.cadence = 4,
  });

  InkRules copyWith({
    bool? ruleA,
    bool? ruleB,
    bool? ruleC,
    bool? ruleE,
    int? cadence,
  }) {
    return InkRules(
      ruleA: ruleA ?? this.ruleA,
      ruleB: ruleB ?? this.ruleB,
      ruleC: ruleC ?? this.ruleC,
      ruleE: ruleE ?? this.ruleE,
      cadence: cadence ?? this.cadence,
    );
  }
}

class InkStep {
  // Same 6 directions as HexGrid.directions, in an order where index i and
  // index (i+3)%6 are always the antipodal pair — verified against
  // hex_grid.dart: (1,0)/(-1,0), (1,-1)/(-1,1), (0,-1)/(0,1).
  static const List<HexCoord> directions = [
    HexCoord(1, 0),
    HexCoord(1, -1),
    HexCoord(0, -1),
    HexCoord(-1, 0),
    HexCoord(-1, 1),
    HexCoord(0, 1),
  ];

  /// The 3 antipodal axes, as index pairs into [directions].
  static const List<(int, int)> axisPairs = [(0, 3), (1, 4), (2, 5)];

  /// All valid coords for a hex grid of the given [radius] — same
  /// enumeration order/shape as `HexGrid`'s constructor loop.
  static List<HexCoord> cellsInRadius(int radius) {
    final result = <HexCoord>[];
    for (int q = -radius; q <= radius; q++) {
      final r1 = max(-radius, -q - radius);
      final r2 = min(radius, -q + radius);
      for (int r = r1; r <= r2; r++) {
        result.add(HexCoord(q, r));
      }
    }
    return result;
  }

  /// Computes generation [generation] from the prior generation's [active]
  /// set, synchronously and birth-only: every newly-activated cell is
  /// derived purely from [active] (never from cells activated earlier in
  /// this same step), then unioned in. Because every rule only turns cells
  /// on, rule order doesn't matter and there are no conflicts to resolve.
  ///
  /// [generation] is the generation number being produced by this call
  /// (i.e. call with `generation: 1` to compute the first step from a seed)
  /// — rule E's cadence check uses it directly.
  static Set<HexCoord> step({
    required Set<HexCoord> active,
    required int radius,
    required int generation,
    required InkRules rules,
  }) {
    final allCells = cellsInRadius(radius);
    final allCellSet = allCells.toSet();
    final next = Set<HexCoord>.from(active);

    for (final coord in allCells) {
      final neighborCoords = List.generate(
        6,
        (i) => HexCoord(coord.q + directions[i].q, coord.r + directions[i].r),
      );
      final neighborActive = List.generate(
        6,
        (i) => active.contains(neighborCoords[i]),
      );
      final activeNeighborCount = neighborActive.where((b) => b).length;

      int completeAxes = 0;
      for (final (i, j) in axisPairs) {
        if (neighborActive[i] && neighborActive[j]) completeAxes++;
      }

      final isActive = active.contains(coord);

      // Rule A — gap-fill/merge.
      if (!isActive && rules.ruleA && completeAxes >= 1) {
        next.add(coord);
      }

      // Rule B — tip extension.
      if (isActive && rules.ruleB && activeNeighborCount == 1) {
        final srcIdx = neighborActive.indexOf(true);
        final antipode = neighborCoords[(srcIdx + 3) % 6];
        if (allCellSet.contains(antipode)) next.add(antipode);
      }

      // Rule C — collision burst (any cell, active or not).
      if (rules.ruleC && completeAxes >= 2) {
        next.add(coord);
        for (final nc in neighborCoords) {
          if (allCellSet.contains(nc)) next.add(nc);
        }
      }

      // Rule E — periodic tip-bloom.
      if (isActive &&
          rules.ruleE &&
          activeNeighborCount == 1 &&
          generation % rules.cadence == 0) {
        for (final nc in neighborCoords) {
          if (allCellSet.contains(nc)) next.add(nc);
        }
      }
    }

    return next;
  }

  /// The first generation index (0 = seed) at which any outermost-ring
  /// cell of [history] is active, or null if none yet — used for the
  /// sandbox's "border-contact generation" readout.
  static int? borderContactGeneration(List<Set<HexCoord>> history, int radius) {
    for (int g = 0; g < history.length; g++) {
      if (history[g].any((c) => isBorder(c, radius))) return g;
    }
    return null;
  }

  static bool isBorder(HexCoord coord, int radius) {
    return [coord.q.abs(), coord.r.abs(), (coord.q + coord.r).abs()]
            .reduce(max) ==
        radius;
  }
}
