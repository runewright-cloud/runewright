// SPDX-License-Identifier: GPL-3.0-or-later
//
// trajectory_parser.dart — TrajectoryParser: proof outputs → formulas.
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
// Formula structure (design doc §spells, FormulaTracker):
//   chunk[0]     = affinity   (first entry, the "element" axis)
//   chunk[1..]   = the tail    (ordinarily effectType1, effectType2)
//
// Ordinarily a formula is 3 elements; under a Mutable Leyline it is 4-6
// (LEYLINE_SEED_PLAN.md §16), which is what [parse]'s formulaLength selects.
// Segmentation itself lives in formula_segmentation.dart and is shared with
// live play, so a certified replay and a live cast cut identically.
//
// Residuals: activations that haven't filled a complete formula yet.

import 'package:rune_duel/engine/border_zone.dart';
import 'package:rune_duel/engine/ca_run.dart' show ruleFromIndex, activeZoneFor;
import 'package:rune_duel/engine/formula.dart';
import 'package:rune_duel/engine/formula_segmentation.dart';

import 'proof_outputs.dart' show VerifiedSpellOutputs;

// ── Parsed formula ────────────────────────────────────────────────────────────

/// One complete formula from a spell's trajectory: an affinity and its tail.
///
/// **A purely STRUCTURAL fact.** It is what segmentation cut out of the
/// certified trajectory, and it carries no interpretation — under a Mutable
/// Leyline the very same [ParsedFormula] may mean an effect or mean noise, and
/// which one is a question for `IncantationLexicon`, not for this class. That
/// separation is what keeps a certificate free of leyline semantics.
///
/// Ordinarily the tail is two elements (`Affinity | key | key`); under a
/// mutable leyline it is 3–5 (§16's lengths 4–6). [tail] is therefore the
/// canonical shape and [effectType1]/[effectType2] are ordinary-only readings
/// of it.
class ParsedFormula {
  /// The ordinary triplet: affinity plus a two-element tail.
  ///
  /// Kept as the primary constructor because ordinary play, every fixture and
  /// the whole existing corpus speak triplets, and because a caller writing two
  /// named zones cannot get the tail length wrong.
  ParsedFormula({
    required this.affinity,
    required BorderZone effectType1,
    required BorderZone effectType2,
  }) : tail = List<BorderZone>.unmodifiable([effectType1, effectType2]);

  /// A formula of any ratified length: affinity plus an arbitrary tail.
  ///
  /// The tail must be non-empty — a formula with no tail has nothing to look
  /// up, under either grammar.
  ParsedFormula.withTail({
    required this.affinity,
    required List<BorderZone> tail,
  }) : tail = List<BorderZone>.unmodifiable(tail) {
    if (tail.isEmpty) {
      throw ArgumentError.value(tail, 'tail', 'a formula tail cannot be empty');
    }
  }

  /// First entry of the formula — the elemental affinity (the "row" in the
  /// effect table).
  ///
  /// Never part of a codebook key: §3's protected invariant is that a leyline
  /// changes what a TAIL means and never what an affinity means.
  final BorderZone affinity;

  /// The formula's tail: everything after the affinity, in order. Length
  /// `formulaLength - 1` — 2 ordinarily, 3–5 under a mutable leyline.
  ///
  /// This is the codebook key under a mutable leyline, and the
  /// `effectKindFromPair` argument pair under an ordinary one.
  final List<BorderZone> tail;

  /// True when this formula has the ordinary two-element tail.
  bool get isOrdinaryLength => tail.length == 2;

  /// Second formula entry — narrows the effect type. **Ordinary tails only.**
  BorderZone get effectType1 => _ordinaryTail()[0];

  /// Third formula entry — selects the final column. **Ordinary tails only.**
  ///
  /// Throws on a mutable-length tail rather than returning `tail[1]`, which
  /// would be a real element in the wrong role: under `L = 5` the third entry
  /// is the second of four key elements, and reading it as "the column" would
  /// silently resolve a mutable formula through the ordinary table. Fail-closed
  /// is the whole point — a mutable formula must reach the codebook or reach
  /// nothing.
  BorderZone get effectType2 => _ordinaryTail()[1];

  List<BorderZone> _ordinaryTail() {
    if (tail.length != 2) {
      throw StateError(
        'effectType1/effectType2 are the ORDINARY reading of a formula tail, '
        'but this tail has ${tail.length} elements (formula length '
        '${tail.length + 1}). A mutable-length formula is interpreted through '
        'IncantationLexicon.meaningOf, never through effectKindFromPair.',
      );
    }
    return tail;
  }

  @override
  String toString() =>
      'ParsedFormula($affinity, ${tail.map((z) => z.name).join(", ")})';

  @override
  bool operator ==(Object other) {
    if (other is! ParsedFormula) return false;
    if (affinity != other.affinity || tail.length != other.tail.length) {
      return false;
    }
    for (var i = 0; i < tail.length; i++) {
      if (tail[i] != other.tail[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(affinity, Object.hashAll(tail));
}

// ── Result ────────────────────────────────────────────────────────────────────

class TrajectoryResult {
  const TrajectoryResult({required this.formulas, required this.residuals});

  /// Complete formulas in the order they were committed.
  final List<ParsedFormula> formulas;

  /// Leftover activations that didn't fill a complete formula — 0–2 under the
  /// ordinary grammar, 0 to `formulaLength - 1` under a mutable one.
  final List<BorderZone> residuals;
}

// ── Parser ────────────────────────────────────────────────────────────────────

class TrajectoryParser {
  /// Parse [outputs.dominanceTrajectory] + [outputs.supremeDominanceFlags]
  /// into ordered formulas and residuals.
  ///
  /// Only the first [outputs.t] generations are fed to the tracker; entries
  /// at gen ≥ t are 0 (masked) and correctly contribute nothing.
  ///
  /// [formulaLength] is the active leyline's grammar — 3 ordinarily, 4–6 under
  /// a mutable leyline. It defaults to the ordinary length so that the many
  /// callers who are *about* ordinary play (the whole existing corpus, and
  /// `spell_asset_integrity`'s persisted-metadata check) say what they mean by
  /// saying nothing. **Every in-match caller must pass
  /// `IncantationLexicon.formulaLength` explicitly**; a posture test pins that
  /// they do.
  ///
  /// Note what does NOT move with it: the flat committed sequence
  /// ([certifiedElementSequence]) is produced by `FormulaTracker`'s three
  /// commit rules, all of which are length-independent. A leyline re-cuts the
  /// certified trajectory; it never rewrites it. That is why proofs,
  /// `behaviouralKinKey`, heraldry and the Wild Magic v2 preimage are all
  /// leyline-invariant.
  static TrajectoryResult parse(
    VerifiedSpellOutputs outputs, {
    int formulaLength = kIncantationFormulaLength,
  }) {
    final tracker = _drive(outputs);
    final committed = tracker.committed;

    final chunks =
        segmentFormulas(committed, formulaLength: formulaLength);
    final formulas = [
      for (final chunk in chunks)
        ParsedFormula.withTail(
          affinity: chunk[0],
          tail: chunk.sublist(1),
        ),
    ];

    return TrajectoryResult(
      formulas: formulas,
      residuals: committed.sublist(
        completeFormulaElementCount(
          committed.length,
          formulaLength: formulaLength,
        ),
      ),
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
