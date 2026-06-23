// SPDX-License-Identifier: GPL-3.0-or-later
//
// ink_step.dart — neutral "magic ink" CA step. The canonical, single
// implementation of the ink ruleset, shared by two callers: the playtest
// sandbox (lib/ui/ink_sandbox_screen.dart), and the main engine's neutral
// substrate (stepper.dart's CAStep.step, dispatched via CARules.isNeutral).
// Operates on a sparse `Set<HexCoord>` of active cells rather than
// `HexGrid`/`Element`/border-zone/dominance state -- those are stepper.dart's
// concern (it owns the border-override and zoneActivations bookkeeping
// around calls to InkStep.step); this file only knows "active or not."
// Distinct from CARules (those are neighbor-COUNT rulesets; ink is
// antipodal-AXIS based, which count rules can't express).
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

  /// Rule E — periodic serif flare: on a pulse generation
  /// (`generation % cadence == 0`), an INACTIVE cell with exactly one
  /// active neighbor becomes active. Every empty cell touching a stroke
  /// tip at degree 1 qualifies -- the straight continuation Rule B already
  /// covers, plus the two forward diagonals -- giving tips a periodic
  /// forward "serif" flare on the beat. A cell touching two or more active
  /// cells (flanking a stroke's body, or sitting in a bend) has
  /// activeNeighborCount != 1 and never fires, so the serif appears only
  /// at tips, never along a line's side.
  final bool ruleE;

  /// Cadence N for rule E. Only meaningful when [ruleE] is true.
  final int cadence;

  const InkRules({
    this.ruleA = true,
    this.ruleB = true,
    this.ruleE = true,
    this.cadence = 4,
  });

  InkRules copyWith({
    bool? ruleA,
    bool? ruleB,
    bool? ruleE,
    int? cadence,
  }) {
    return InkRules(
      ruleA: ruleA ?? this.ruleA,
      ruleB: ruleB ?? this.ruleB,
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

  /// The 3 antipodal axes, as index pairs into [directions]. Still needed
  /// by Rule A (gap-fill) even though Rule C (collision burst) -- the only
  /// other former consumer of "is this axis complete" -- has been removed:
  /// the burst scattered activation onto neighbors, the expensive
  /// distance-2 shape in-circuit, and has been replaced by Rule E's
  /// distance-1 serif pulse below.
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

      // Rule E — periodic serif flare: on a pulse generation, an inactive
      // cell with exactly one active neighbor becomes active. `coord` is
      // already a valid grid cell (we're iterating allCells), so unlike
      // the old burst there's no separate in-grid check needed here.
      if (!isActive &&
          rules.ruleE &&
          activeNeighborCount == 1 &&
          generation % rules.cadence == 0) {
        next.add(coord);
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
