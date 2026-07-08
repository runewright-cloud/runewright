// SPDX-License-Identifier: GPL-3.0-or-later
//
// trajectory_parser.dart — TrajectoryParser: proof outputs → formula triplets.
// REAL — fully specified, unit-tested.
//
// Turns the dominance_trajectory + supreme_dominance_flags arrays from a
// verified proof (VerifiedSpellOutputs) into ordered ParsedFormulas and
// residuals by driving the existing FormulaTracker one generation at a time.
//
// FormulaTracker (lib/engine/formula.dart) is the canonical implementation of
// the formula-accumulation rules; this parser wraps it for the batch
// (completed proof) case rather than the streaming (live play) case.
//
// Formula triplet structure (design doc §spells, FormulaTracker):
//   triplet[0] = affinity   (first entry, the "element" axis)
//   triplet[1] = effectType1
//   triplet[2] = effectType2
//
// Residuals: 0–2 activations that haven't filled a group of 3 yet.

import 'package:rune_duel/engine/border_zone.dart';
import 'package:rune_duel/engine/ca_run.dart' show ruleFromIndex, activeZoneFor;
import 'package:rune_duel/engine/formula.dart';

import 'proof_intake.dart' show VerifiedSpellOutputs;

// ── Parsed formula ────────────────────────────────────────────────────────────

/// One complete formula triplet from a spell's trajectory.
class ParsedFormula {
  const ParsedFormula({
    required this.affinity,
    required this.effectType1,
    required this.effectType2,
  });

  /// First entry of the triplet — the elemental affinity (the "row" in the
  /// effect table).
  final BorderZone affinity;

  /// Second triplet entry — narrows the effect type.
  final BorderZone effectType1;

  /// Third triplet entry — selects the final column.
  final BorderZone effectType2;

  @override
  String toString() => 'ParsedFormula($affinity, $effectType1, $effectType2)';

  @override
  bool operator ==(Object other) =>
      other is ParsedFormula &&
      affinity == other.affinity &&
      effectType1 == other.effectType1 &&
      effectType2 == other.effectType2;

  @override
  int get hashCode => Object.hash(affinity, effectType1, effectType2);
}

// ── Result ────────────────────────────────────────────────────────────────────

class TrajectoryResult {
  const TrajectoryResult({required this.formulas, required this.residuals});

  /// Complete formula triplets in the order they were committed.
  final List<ParsedFormula> formulas;

  /// 0–2 leftover activations that didn't fill a group of 3.
  final List<BorderZone> residuals;
}

// ── Parser ────────────────────────────────────────────────────────────────────

class TrajectoryParser {
  /// Parse [outputs.dominanceTrajectory] + [outputs.supremeDominanceFlags]
  /// into ordered formula triplets and residuals.
  ///
  /// Only the first [outputs.t] generations are fed to the tracker; entries
  /// at gen ≥ t are 0 (masked) and correctly contribute nothing.
  static TrajectoryResult parse(VerifiedSpellOutputs outputs) {
    final tracker = FormulaTracker();

    for (var gen = 0; gen < outputs.t; gen++) {
      final domIdx = outputs.dominanceTrajectory[gen];
      final isSupreme = outputs.supremeDominanceFlags[gen] == 1;
      final rule = ruleFromIndex(domIdx);
      final zone = activeZoneFor(rule); // null for neutral
      tracker.step(zone, supremeDominant: isSupreme);
    }

    // FormulaTracker.formulas returns List<List<BorderZone>>, each of length 3.
    final formulas = tracker.formulas
        .map((triplet) => ParsedFormula(
              affinity: triplet[0],
              effectType1: triplet[1],
              effectType2: triplet[2],
            ))
        .toList();

    return TrajectoryResult(
      formulas: formulas,
      residuals: List<BorderZone>.from(tracker.residuals),
    );
  }
}
