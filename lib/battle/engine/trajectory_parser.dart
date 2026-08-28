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

import 'proof_outputs.dart' show VerifiedSpellOutputs;

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
    final tracker = _drive(outputs);

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

  /// Certified analog of `SpellAsset.formula` (design doc "Summons"):
  /// replays the SNARK-certified trajectory and returns the full flat
  /// committed element sequence -- including any trailing residual, exactly
  /// like `FormulaTracker.committed` populates `SpellAsset.formula` in
  /// main.dart -- rather than [parse]'s complete-triplets-only view.
  ///
  /// Used to derive a peer's summoned creature (CreatureSpec.fromElements)
  /// from certified data instead of the untrusted wire SpellAsset.formula:
  /// the same B-1/B-8 trust-boundary pattern [certifiedSupremeTags] and
  /// [parse] already apply to effect resolution and enhancement claims,
  /// extended to creature summoning.
  static List<BorderZone> certifiedElementSequence(VerifiedSpellOutputs outputs) =>
      _drive(outputs).committed;

  /// One certified dominant element for EVERY non-neutral generation in
  /// `0 .. outputs.t - 1`, in order, with repeated generations preserved.
  /// Aetherial Armor semantics (lib/battle/models/certified_armor.dart) read
  /// this; nothing else should without reading the next paragraph first.
  ///
  /// This is deliberately NOT [certifiedElementSequence], which is the
  /// compressed spell-formula view. That one runs the trajectory through
  /// [FormulaTracker], which is the *formula* rule set —
  /// it commits an element only on a lead change, a supreme generation, or a
  /// cadence pulse, so four consecutive fire generations yield two entries,
  /// not four. Formulas want that (a spell's inscribed word); anything that
  /// scores how long an element actually held the lead does not.
  ///
  /// Both readings come from the same certified array via the same
  /// [ruleFromIndex]/[activeZoneFor] pair, so there is still exactly one
  /// interpretation of a dominance index in the codebase; what differs is the
  /// accumulation rule layered on top. Neutral generations (index 0, ties, and
  /// the masked entries at gen ≥ t) contribute nothing to either.
  static List<BorderZone> certifiedPerGenerationDominantSequence(VerifiedSpellOutputs outputs) {
    final seq = <BorderZone>[];
    for (var gen = 0; gen < outputs.t; gen++) {
      final zone = activeZoneFor(ruleFromIndex(outputs.dominanceTrajectory[gen]));
      if (zone != null) seq.add(zone);
    }
    return List.unmodifiable(seq);
  }

  static FormulaTracker _drive(VerifiedSpellOutputs outputs) {
    final tracker = FormulaTracker();
    for (var gen = 0; gen < outputs.t; gen++) {
      final domIdx = outputs.dominanceTrajectory[gen];
      final isSupreme = outputs.supremeDominanceFlags[gen] == 1;
      final rule = ruleFromIndex(domIdx);
      final zone = activeZoneFor(rule); // null for neutral
      tracker.step(zone, supremeDominant: isSupreme);
    }
    return tracker;
  }

  /// Certified analog of `deriveSupremeTags` (lib/spells/supreme_tags.dart),
  /// which replays a spell's CA locally. This derives the same zone-name set
  /// from the SNARK-certified [outputs] instead — used by
  /// TurnLoop._verifyPeerSpellCast to check that a peer's claimed cast-time
  /// enhancement (Potency/Velocity/Efficiency/Mystery) is actually backed by
  /// this spell's own certified supreme-dominance data, not merely
  /// self-declared on the wire.
  static Set<String> certifiedSupremeTags(VerifiedSpellOutputs outputs) {
    final tags = <String>{};
    for (var gen = 0; gen < outputs.t; gen++) {
      if (outputs.supremeDominanceFlags[gen] != 1) continue;
      final rule = ruleFromIndex(outputs.dominanceTrajectory[gen]);
      final zone = activeZoneFor(rule);
      if (zone != null) tags.add(zone.name);
    }
    return tags;
  }
}
