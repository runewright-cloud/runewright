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

// ── Dominance helpers ──────────────────────────────────────────────────────
//
// Single source for the dominance/decay/supreme system: both runStepper
// (below) and main.dart's GameScreen (the live per-step Rune Craft display)
// call into activeZoneFor/isSupreme/advanceDominance. Previously GameScreen
// carried its own independent copy of this logic -- two oracles is exactly
// the failure mode this codebase's "Dart is canonical" discipline exists to
// prevent, so it was consolidated here. _nextRule and _decayAtMaxPressure
// stay private; they're only ever called through advanceDominance.

// Zone whose CARules are currently active; null for neutral.
BorderZone? activeZoneFor(CARules rules) {
  if (rules == CARules.fire)  return BorderZone.fire;
  if (rules == CARules.wind)  return BorderZone.air;
  if (rules == CARules.water) return BorderZone.water;
  if (rules == CARules.earth) return BorderZone.earth;
  return null;
}

// Decay every zone currently at the max net pressure, splitting D evenly
// (by ceiling) across however many zones are tied for the lead. Replaces
// the old "only the dispatched zone decays" rule, which conflated decay
// with dispatch for no principled reason. A unique leader (k=1) decays by
// the full D -- behavior-identical to the old single-zone decay in the
// no-tie case.
//
// D = floor((stepCount)/2). Must be called with the RETURNED grid (after
// stepCount has been incremented by CAStep.step), so stepCount = gen + 1
// and D = (gen+1)~/2.
//
// Decay sequence for gen 0..6: 0, 1, 1, 2, 2, 3, 3  (= floor((gen+1)/2))
// This matches the Noir circuit's (t+1)/2.
//
// Pure function of the pressure table now -- independent of which rule is
// or was dispatched, unlike the old per-rule decay.
void _decayAtMaxPressure(HexGrid grid) {
  final a = grid.zoneActivations;
  if (a.isEmpty) return;
  final maxP = a.values.reduce(max);
  if (maxP == 0) return;
  final leaders = a.entries.where((e) => e.value == maxP).map((e) => e.key).toList();
  final k = leaders.length;
  final d = grid.stepCount ~/ 2;
  final dec = (d + k - 1) ~/ k; // ceil(d / k)
  for (final zone in leaders) {
    a[zone] = max(0, maxP - dec);
  }
}

// Select the dominant rule from decayed zone pressures (= grid.zoneActivations).
// A tie at the top pressure reports no dominant (CARules.neutral) -- ties
// are unreportable as "the" dominant element, and (see isSupreme) can
// never be supreme anyway, so dispatch is unaffected by this choice.
// All zero → neutral.
CARules _nextRule(HexGrid grid) {
  final a = grid.zoneActivations;
  if (a.isEmpty || a.values.every((v) => v == 0)) return CARules.neutral;
  final maxCount = a.values.reduce(max);
  final leaders = a.entries.where((e) => e.value == maxCount).toList();
  if (leaders.length != 1) return CARules.neutral;
  final zone = leaders.first.key;
  switch (zone) {
    case BorderZone.fire:  return CARules.fire;
    case BorderZone.air:   return CARules.wind;
    case BorderZone.water: return CARules.water;
    case BorderZone.earth: return CARules.earth;
  }
}

// Returns true when [rule]'s zone has decayed pressure strictly exceeding
// the sum of all other zones' pressures (and [rule] is non-neutral).
// Matches circuit: (rule != 0) && (p_dom > total_p - p_dom)
//
// A pure query over already-committed state -- no "current rule" input,
// unlike _nextRule -- which is what lets GameScreen.build() re-derive
// supreme status on every rebuild without re-running a step transition.
bool isSupreme(CARules rule, HexGrid grid) {
  if (rule == CARules.neutral) return false;
  final a = grid.zoneActivations;
  if (a.isEmpty) return false;
  final total = a.values.fold(0, (s, v) => s + v);
  if (total == 0) return false;
  final zone = activeZoneFor(rule)!;
  final pDom = a[zone] ?? 0;
  return pDom * 2 > total;
}

// Advances the dominance system by one generation: decays zones at max
// pressure, selects the dominant element from the updated pressures, and
// determines whether that dominant is supreme -- bundled into one call so
// a caller can't accidentally pair a freshly-selected rule with a stale or
// independently-recomputed supreme value. [grid] must already be the
// post-CAStep.step grid (stepCount incremented).
//
// [dominant] is the SELECTED leader (CARules.neutral on a tie or no
// pressure) -- this is what dominance_trajectory must record: the spell's
// elemental signature, reported regardless of dispatch.
//
// [rule] is the GATED rule that actually evolves the grid next step:
// neutral unless [dominant] is supreme. [isSupreme] is computed once, on
// [dominant], and is the exact value used both for the gate and for
// supremeFlags -- never recomputed separately for either use.
//
// [currentRule] is accepted for call-site stability with existing callers
// but is no longer read: decay is now a pure function of the pressure
// table, and a tie resolves to neutral rather than sticking to the
// previous rule, so nothing here depends on history anymore.
({CARules rule, CARules dominant, bool isSupreme}) advanceDominance(
  CARules currentRule,
  HexGrid grid,
) {
  _decayAtMaxPressure(grid);
  final dominant = _nextRule(grid);
  final supreme = isSupreme(dominant, grid);
  return (
    rule: supreme ? dominant : CARules.neutral,
    dominant: dominant,
    isSupreme: supreme,
  );
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

    // Step 3: decay + select the new dominant rule + supreme check, all in
    // one call so trajectory and the flag can never see inconsistent values
    // (next.stepCount == gen + 1 at this point; decay = (gen+1)~/2).
    final dominance = advanceDominance(currentRule, next);

    // Step 4: record outputs for this generation. Trajectory records the
    // DOMINANT element (the spell's elemental signature) even on
    // non-supreme generations; dispatch (currentRule, below) uses the
    // gated dominance.rule, which differs from dominant whenever the
    // dominant isn't supreme -- that decoupling is intentional (A1).
    dominanceTrajectory[gen] = ruleIndex(dominance.dominant);
    supremeFlags[gen]        = dominance.isSupreme ? 1 : 0;

    grid = next;
    currentRule = dominance.rule;
  }
  // Entries for gen >= T remain 0 (neutral, no flags) — matches circuit masking.

  return StepperResult(
    borderActivations: borderActivations,
    dominanceTrajectory: dominanceTrajectory,
    supremeFlags: supremeFlags,
  );
}
