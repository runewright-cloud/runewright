import 'dart:math';
import 'border_zone.dart';
import 'ca_rules.dart';
import 'element.dart';
import 'hex_grid.dart';
import 'stepper.dart';

// Multi-step CA oracle.
//
// This is the Dart-side oracle for golden vector generation and stepper
// regression testing. It wraps the canonical single-step primitive (CAStep.step)
// and adds the dominance-tracking loop that matches the Noir circuit's main().
//
// Authority: when Dart and circuit disagree on CA behaviour, Dart wins (see
// CLAUDE.md). The circuit must be updated to match; never the reverse.
//
// Border-activation accounting:
//   - zoneActivations on HexGrid: cumulative, decayed (= circuit's zone_pressure)
//   - StepperResult.borderActivations: cumulative, NEVER decayed (= circuit's
//     total_border_acts, and the border_activations public output in CIRCUIT_IO.md)
// These are two different quantities. Do not confuse them.

// ── Public types ─────────────────────────────────────────────────────────────

class StepperResult {
  // Per-element raw (undecayed) border activation totals, indexed
  // [fire, air, water, earth] — matches circuit's total_border_acts and
  // CIRCUIT_IO.md §8 border_activations ordering (fire=0, air=1, water=2, earth=3).
  final List<int> borderActivations;

  // Dominant rule index per generation, length = tierMax.
  // 0=neutral, 1=fire, 2=air, 3=water, 4=earth.
  // Entries for gen >= T are 0 (neutral, no dominant element active).
  final List<int> dominanceTrajectory;

  // 0 or 1 per generation, length = tierMax.
  // 1 when the dominant zone's decayed pressure strictly exceeds the sum of
  // all other zones' pressures (and the rule is non-neutral).
  // Entries for gen >= T are 0.
  final List<int> supremeFlags;

  const StepperResult({
    required this.borderActivations,
    required this.dominanceTrajectory,
    required this.supremeFlags,
  });
}

// ── Rule ↔ index mapping ──────────────────────────────────────────────────────

// Rule indices match the circuit (GRID_ORDERING_v2.md §Rule indices):
//   0=neutral, 1=fire, 2=air (Dart name: wind), 3=water, 4=earth
int ruleIndex(CARules rule) {
  if (rule == CARules.fire)  return 1;
  if (rule == CARules.wind)  return 2;
  if (rule == CARules.water) return 3;
  if (rule == CARules.earth) return 4;
  return 0;
}

CARules ruleFromIndex(int idx) {
  switch (idx) {
    case 1: return CARules.fire;
    case 2: return CARules.wind;
    case 3: return CARules.water;
    case 4: return CARules.earth;
    default: return CARules.neutral;
  }
}

// Zone → index in borderActivations / total_border_acts array.
// [0]=fire, [1]=air, [2]=water, [3]=earth
int zoneIndex(BorderZone zone) {
  switch (zone) {
    case BorderZone.fire:  return 0;
    case BorderZone.air:   return 1;
    case BorderZone.water: return 2;
    case BorderZone.earth: return 3;
  }
}

// ── Dominance helpers (mirror of main.dart private statics) ──────────────────

// Zone whose CARules are currently active; null for neutral.
BorderZone? _activeZone(CARules rules) {
  if (rules == CARules.fire)  return BorderZone.fire;
  if (rules == CARules.wind)  return BorderZone.air;
  if (rules == CARules.water) return BorderZone.water;
  if (rules == CARules.earth) return BorderZone.earth;
  return null;
}

// Apply floor((stepCount)/2) decay to the active zone's cumulative pressure.
// Must be called with the RETURNED grid (after stepCount has been incremented
// by CAStep.step), so stepCount = gen + 1 and decay = (gen+1)~/2.
//
// Decay sequence for gen 0..6: 0, 1, 1, 2, 2, 3, 3  (= floor((gen+1)/2))
// This matches main.dart's _decayActiveZone and the Noir circuit's (t+1)/2.
void _decayActiveZone(HexGrid grid, CARules currentRule) {
  final zone = _activeZone(currentRule);
  if (zone == null) return;
  final count = grid.zoneActivations[zone] ?? 0;
  grid.zoneActivations[zone] = max(0, count - grid.stepCount ~/ 2);
}

// Select the dominant rule from decayed zone pressures (= grid.zoneActivations).
// Sticky on ties: multiple zones tied → keep current rule.
// All zero → neutral.
CARules _nextRule(CARules current, HexGrid grid) {
  final a = grid.zoneActivations;
  if (a.isEmpty || a.values.every((v) => v == 0)) return CARules.neutral;
  final maxCount = a.values.reduce(max);
  final leaders = a.entries.where((e) => e.value == maxCount).toList();
  if (leaders.length != 1) return current;
  final zone = leaders.first.key;
  switch (zone) {
    case BorderZone.fire:  return CARules.fire;
    case BorderZone.air:   return CARules.wind;
    case BorderZone.water: return CARules.water;
    case BorderZone.earth: return CARules.earth;
  }
}

// Returns true when the dominant zone's decayed pressure strictly exceeds
// the sum of all other zones' pressures, AND the rule is non-neutral.
// Matches circuit: (rule != 0) && (p_dom > total_p - p_dom)
bool _isSupreme(CARules dominantRule, HexGrid grid) {
  if (dominantRule == CARules.neutral) return false;
  final a = grid.zoneActivations;
  if (a.isEmpty) return false;
  final total = a.values.fold(0, (s, v) => s + v);
  if (total == 0) return false;
  final zone = _activeZone(dominantRule)!;
  final pDom = a[zone] ?? 0;
  return pDom * 2 > total;
}

// ── Flat grid ↔ HexGrid conversion ───────────────────────────────────────────

// Build the canonical flat-index → HexCoord list (q×r ordering matching
// gen_grid_constants.py and HexGrid(12) constructor insertion order).
List<HexCoord> _buildFlatIndex(int radius) {
  final coords = <HexCoord>[];
  for (int q = -radius; q <= radius; q++) {
    final rMin = max(-radius, -q - radius);
    final rMax = min(radius, -q + radius);
    for (int r = rMin; r <= rMax; r++) {
      coords.add(HexCoord(q, r));
    }
  }
  return coords;
}

HexGrid _gridFromFlat(List<int> flatState, int radius) {
  final coords = _buildFlatIndex(radius);
  assert(flatState.length == coords.length,
      'flatState length ${flatState.length} != expected ${coords.length}');
  final g = HexGrid(radius);
  for (int i = 0; i < flatState.length; i++) {
    if (flatState[i] == 1) {
      g.cells[coords[i]] = Element.alive;
    }
  }
  return g;
}

// ── Public API ────────────────────────────────────────────────────────────────

// Run the CA for T steps and return trajectory + activation outputs.
//
// gridState: flat list of 469 cells (0/1) in canonical q×r order.
// T:         active generation count, 1 ≤ T ≤ tierMax.
// tierMax:   tier circuit size (12, 24, or 48).
//
// The oracle is the Dart stepper (CAStep.step), not the Noir circuit.
// See CIRCUIT_IO.md §0 oracle principle.
StepperResult runStepper(List<int> gridState, int T, int tierMax) {
  assert(T >= 1 && T <= tierMax, 'T=$T out of range for tierMax=$tierMax');

  var grid = _gridFromFlat(gridState, 12);
  var currentRule = CARules.neutral;

  final borderActivations = [0, 0, 0, 0]; // [fire, air, water, earth], raw totals
  final dominanceTrajectory = List<int>.filled(tierMax, 0);
  final supremeFlags        = List<int>.filled(tierMax, 0);

  for (int gen = 0; gen < T; gen++) {
    // Snapshot decayed cumulative pressures BEFORE this step's additions,
    // so we can compute the per-step delta below.
    final prevActivations = Map<BorderZone, int>.from(grid.zoneActivations);

    // Step 1: run the CA (increments stepCount, adds border births to
    //         next.zoneActivations). Uses canonical Dart rules.
    final next = CAStep.step(grid, currentRule);

    // Step 2: accumulate raw per-step border birth counts (NO decay ever applied).
    for (final zone in BorderZone.values) {
      final delta = (next.zoneActivations[zone] ?? 0) -
                    (prevActivations[zone] ?? 0);
      if (delta > 0) borderActivations[zoneIndex(zone)] += delta;
    }

    // Step 3: decay active zone's cumulative pressure.
    // next.stepCount == gen + 1 at this point; decay = (gen+1)~/2.
    _decayActiveZone(next, currentRule);

    // Step 4: select new dominant rule from updated (decayed) pressures.
    final newRule = _nextRule(currentRule, next);

    // Step 5: record outputs for this generation.
    dominanceTrajectory[gen] = ruleIndex(newRule);
    supremeFlags[gen]        = _isSupreme(newRule, next) ? 1 : 0;

    grid = next;
    currentRule = newRule;
  }
  // Entries for gen >= T remain 0 (neutral, no flags) — matches circuit masking.

  return StepperResult(
    borderActivations: borderActivations,
    dominanceTrajectory: dominanceTrajectory,
    supremeFlags: supremeFlags,
  );
}
