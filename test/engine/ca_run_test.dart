import 'package:test/test.dart';
import 'package:rune_duel/engine/border_zone.dart';
import 'package:rune_duel/engine/border_zones.dart';
import 'package:rune_duel/engine/ca_rules.dart';
import 'package:rune_duel/engine/ca_run.dart';
import 'package:rune_duel/engine/hex_grid.dart';

void main() {

  // ── 1. DECAY SEQUENCE ──────────────────────────────────────────────────────
  //
  // Pins the exact decay formula: decay = floor((gen+1)/2), where gen is
  // 0-indexed. Derivation: CAStep.step increments stepCount BEFORE returning,
  // so after the step at gen the returned grid has stepCount = gen+1.
  // _decayActiveZone subtracts stepCount ~/ 2, giving (gen+1) ~/ 2.
  // This matches the Noir circuit's `(t + 1) / 2` exactly.
  //
  // Expected sequence for gen 0..9:
  //   gen:   0  1  2  3  4  5  6  7  8  9
  //   decay: 0  1  1  2  2  3  3  4  4  5

  group('decay sequence', () {
    const expectedDecay = [0, 1, 1, 2, 2, 3, 3, 4, 4, 5];

    test('floor((gen+1)/2) for gen 0..9', () {
      for (int gen = 0; gen < expectedDecay.length; gen++) {
        final actual = (gen + 1) ~/ 2;
        expect(actual, equals(expectedDecay[gen]),
            reason: 'gen=$gen: got $actual, want ${expectedDecay[gen]}');
      }
    });

    test('floor((gen+1)/2) differs from floor(gen/2) starting at gen=1', () {
      // Guard against the common off-by-one: floor(gen/2) gives 0,0,1,1,...
      // but the correct formula gives 0,1,1,2,... The first divergence is gen=1.
      expect(1 ~/ 2,       equals(0), reason: 'floor(gen/2) at gen=1 is 0');
      expect((1 + 1) ~/ 2, equals(1), reason: 'floor((gen+1)/2) at gen=1 is 1');
    });

    test('anchor_empty produces all-zero CA outputs', () {
      final flatState = List<int>.filled(469, 0);
      final result = runStepper(flatState, 6, 12);
      expect(result.borderActivations,   equals([0, 0, 0, 0]));
      expect(result.dominanceTrajectory, equals(List.filled(12, 0)));
      expect(result.supremeFlags,        equals(List.filled(12, 0)));
    });

    test('anchor_single_center produces all-zero CA outputs', () {
      // Center cell (q=0, r=0) is at flat index 234 in the canonical q×r
      // ordering (see GRID_ORDERING_v2.md and seeds.json anchor_single_center).
      // A lone cell with 0 alive neighbours dies at gen 1; everything else
      // stays empty, so all outputs are zero.
      final flatState = List<int>.filled(469, 0);
      flatState[234] = 1;
      final result = runStepper(flatState, 6, 12);
      expect(result.borderActivations,   equals([0, 0, 0, 0]));
      expect(result.dominanceTrajectory, equals(List.filled(12, 0)));
      expect(result.supremeFlags,        equals(List.filled(12, 0)));
    });
  });

  // ── 2. BORDER ZONE PER-CELL DIFF ───────────────────────────────────────────
  //
  // Verifies gen_grid_constants.py's BORDER_ZONE table agrees with
  // BorderZones.forRadius(12) per cell (not just in aggregate counts).
  //
  // Both now use the same algorithm: CCW from ring[36]=(0,12) (bottom vertex),
  // segments water(18)|air(18)|fire(18)|earth(18). Confirmed 2026-06-14 —
  // the old 9-9-9-18-9-9-9 segmentation was a pre-playtest draft.
  //
  // Spatial layout:
  //   Water: (0,12) → (12,-5)  [bottom-right quad + right side]
  //   Air:   (12,-6) → (1,-12) [upper-right + most of top edge]
  //   Fire:  (0,-12) → (-12,5) [top vertex + entire left side]
  //   Earth: (-12,6) → (-1,12) [lower-left + bottom edge]

  group('border zone per-cell diff', () {

    test('Dart BorderZones gives 18 cells per zone', () {
      final dartMap = BorderZones.forRadius(12);
      expect(dartMap.length, equals(72));
      final counts = <BorderZone, int>{};
      for (final z in dartMap.values) {
        counts[z] = (counts[z] ?? 0) + 1;
      }
      for (final zone in BorderZone.values) {
        expect(counts[zone], equals(18),
            reason: '$zone should have 18 border cells, got ${counts[zone]}');
      }
    });

    test('Python algorithm gives 18 cells per zone', () {
      final pythonMap = _pythonBorderZones();
      expect(pythonMap.length, equals(72));
      final counts = <BorderZone, int>{};
      for (final z in pythonMap.values) {
        counts[z] = (counts[z] ?? 0) + 1;
      }
      for (final zone in BorderZone.values) {
        expect(counts[zone], equals(18),
            reason: '$zone should have 18 python border cells, got ${counts[zone]}');
      }
    });

    test('Python algorithm and Dart BorderZones agree on all 72 cells', () {
      final dartMap   = BorderZones.forRadius(12);
      final pythonMap = _pythonBorderZones();

      final mismatches = <String>[];
      for (final entry in pythonMap.entries) {
        final coord    = entry.key;
        final pyZone   = entry.value;
        final dartZone = dartMap[coord];
        if (dartZone == null) {
          mismatches.add('(${coord.q},${coord.r}): python=$pyZone, dart=MISSING');
        } else if (dartZone != pyZone) {
          mismatches.add('(${coord.q},${coord.r}): python=$pyZone, dart=$dartZone');
        }
      }

      if (mismatches.isNotEmpty) {
        fail('Border zone per-cell mismatches (${mismatches.length}/72).\n'
             '${mismatches.join('\n')}');
      }
    });
  });

  // ── 3. SINGLE-GENERATION DART ↔ NOIR RULE DIFF ─────────────────────────────
  //
  // !! BLOCKER FOR M1 GATE ITEMS 3 AND 4 !!
  //
  // Checks whether the Dart CARules definitions match the Noir circuit's
  // FLAT_TRANSITION table for every (rule_index, cell_state, neighbor_count)
  // combination. This is a pure logic comparison — no nargo run required.
  //
  // EXPECTED RESULT: tests for fire, water, and earth will FAIL.
  // Neutral and air (wind) agree between Dart and circuit.
  //
  // Known discrepancies:
  //
  //   FIRE (index 1):
  //     Dead cell, nb=2..6:  Dart→dead, Circuit→alive
  //     (Dart bornOn={1};  Circuit bornOn={1..6})
  //
  //   WATER (index 3):
  //     Dead cell, nb=1:     Dart→alive, Circuit→dead
  //     Dead cell, nb=3..6:  Dart→dead,  Circuit→alive
  //     (Dart bornOn={1,2}; Circuit bornOn={2..6})
  //
  //   EARTH (index 4):
  //     Alive cell, nb=1:    Dart→alive, Circuit→dead
  //     Dead cell, nb=3..6:  Dart→dead,  Circuit→alive
  //     (Dart survive={1..6},bornOn={2}; Circuit survive={2..6},bornOn={2..6})
  //
  // ACTION REQUIRED (Soren):
  //   Per CLAUDE.md, stepper.dart is canonical → Dart rules win unless you
  //   explicitly re-ratify the circuit's version. Decide which is correct for
  //   v2.4 and update the other to match before proceeding to M3.

  group('dart vs circuit rule diff', () {
    test('neutral rule (0): Dart == circuit FLAT_TRANSITION', () {
      _expectRuleMatch(CARules.neutral, 0);
    });

    test('fire rule (1): Dart == circuit FLAT_TRANSITION  [EXPECTED TO FAIL]', () {
      _expectRuleMatch(CARules.fire, 1);
    });

    test('air/wind rule (2): Dart == circuit FLAT_TRANSITION', () {
      _expectRuleMatch(CARules.wind, 2);
    });

    test('water rule (3): Dart == circuit FLAT_TRANSITION  [EXPECTED TO FAIL]', () {
      _expectRuleMatch(CARules.water, 3);
    });

    test('earth rule (4): Dart == circuit FLAT_TRANSITION  [EXPECTED TO FAIL]', () {
      _expectRuleMatch(CARules.earth, 4);
    });
  });
}

// ── Helpers ───────────────────────────────────────────────────────────────────

// Replicate gen_grid_constants.py border_zones() — must match BorderZones._compute.
// Algorithm: start at ring[3*r] (bottom vertex), go counter-clockwise,
// assign water(18) | air(18) | fire(18) | earth(18).
Map<HexCoord, BorderZone> _pythonBorderZones() {
  final ring = _ringClockwisePy(12);
  final n    = ring.length;
  const start    = 3 * 12; // ring[36] = (0,12) bottom vertex
  final segZones  = [BorderZone.water, BorderZone.air, BorderZone.fire, BorderZone.earth];
  const segCounts = [18, 18, 18, 18];
  final map = <HexCoord, BorderZone>{};
  int idx = 0;
  for (int s = 0; s < segZones.length; s++) {
    for (int j = 0; j < segCounts[s]; j++) {
      map[ring[(start - idx + n) % n]] = segZones[s];
      idx++;
    }
  }
  assert(idx == 72);
  return map;
}

// Replicate Dart's _ringClockwise (and Python's ring_clockwise).
List<HexCoord> _ringClockwisePy(int r) {
  const sideCorners = [(0, -1), (1, -1), (1, 0), (0, 1), (-1, 1), (-1, 0)];
  const sideDirs    = [(1, 0), (0, 1), (-1, 1), (-1, 0), (0, -1), (1, -1)];
  final coords = <HexCoord>[];
  for (int s = 0; s < 6; s++) {
    int q = sideCorners[s].$1 * r;
    int row = sideCorners[s].$2 * r;
    for (int step = 0; step < r; step++) {
      coords.add(HexCoord(q, row));
      q   += sideDirs[s].$1;
      row += sideDirs[s].$2;
    }
  }
  return coords;
}

// Circuit FLAT_TRANSITION[rule * 14 + stateBit * 7 + nb].
// stateBit: 0=dead, 1=alive. nb: 0..6.
const _flatTransition = [
  // rule 0 - neutral
  0, 0, 1, 0, 0, 0, 0,  // dead
  0, 0, 1, 0, 0, 0, 0,  // alive
  // rule 1 - fire
  0, 1, 1, 1, 1, 1, 1,  // dead
  0, 1, 0, 0, 0, 0, 0,  // alive
  // rule 2 - air (wind)
  0, 0, 1, 0, 0, 0, 0,  // dead
  1, 1, 1, 0, 0, 0, 0,  // alive
  // rule 3 - water
  0, 0, 1, 1, 1, 1, 1,  // dead
  0, 0, 0, 1, 1, 1, 1,  // alive
  // rule 4 - earth
  0, 0, 1, 1, 1, 1, 1,  // dead
  0, 0, 1, 1, 1, 1, 1,  // alive
];

void _expectRuleMatch(CARules dartRule, int circuitIdx) {
  final mismatches = <String>[];
  for (int state = 0; state <= 1; state++) {
    for (int nb = 0; nb <= 6; nb++) {
      final alive    = state == 1;
      final dartOut  = alive
          ? (dartRule.surviveOn.contains(nb) ? 1 : 0)
          : (dartRule.bornOn.contains(nb)    ? 1 : 0);
      final circOut  = _flatTransition[circuitIdx * 14 + state * 7 + nb];
      if (dartOut != circOut) {
        final stateStr = alive ? 'alive' : 'dead ';
        mismatches.add('  $stateStr nb=$nb: Dart→$dartOut, Circuit→$circOut');
      }
    }
  }
  if (mismatches.isNotEmpty) {
    fail('${dartRule.name} (index $circuitIdx) has ${mismatches.length} '
         'mismatches.\nSee test file for ACTION REQUIRED.\n'
         '${mismatches.join('\n')}');
  }
}
