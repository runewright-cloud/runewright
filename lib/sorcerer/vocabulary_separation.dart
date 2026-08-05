// SPDX-License-Identifier: GPL-3.0-or-later
//
// vocabulary_separation.dart — will these two words be confused for each other?
//
// VOCAL_RECALL_PLAN.md §8.7. §8.6 makes a collapsed vocabulary PRICE itself:
// two words that sound alike get mistaken for one another, and every mistake
// costs mana. That is the right mechanism, and it needs no threshold — but it
// cannot tell an exploiter from a player who innocently picked two similar
// words and now bleeds mana without understanding why.
//
// So this is a DISCLOSURE tool, not a gate. It measures the separation, shows
// it, and warns plainly. It never refuses a vocabulary.
//
// ── Why a warning and not a ban ───────────────────────────────────────────
//
// A ban needs a threshold that is correct across every accent and voice, and a
// wrong threshold locks a player out of words they say perfectly well. A
// warning degrades gracefully when the threshold is off, and it turns the
// exploit into an informed choice — which is what makes the "Mumbling Wizard"
// (opacity bought with permanent mana) a legitimate archetype rather than a
// trap. §8.6 prices it either way.
//
// ── Why the openers matter most ──────────────────────────────────────────
//
// Opener-vs-opener is the one pair a player is actively MOTIVATED to collapse,
// because it hides whether a cast is a summon. Every other pair only degrades
// by accident. So it gets the loudest warning.

import 'incantation_recall_scorer.dart';
import 'mfcc.dart';
import 'vocal_slot.dart';

/// How confusable one pair of words is.
class SlotPairSeparation {
  const SlotPairSeparation({
    required this.a,
    required this.b,
    required this.margin,
    required this.isOpenerPair,
  });

  final VocalSlot a;
  final VocalSlot b;

  /// Between-word distance as a multiple of the words' own within-word spread.
  ///
  /// A ratio, not a raw DTW distance, because raw distance is uncalibratable
  /// across speakers and microphones — the whole reason enrollment exists
  /// (docs/M4_findings.md, 2026-07-16: reliable *ranking* same-voice, useless
  /// absolute scale). Dividing by how much a speaker's own repeats of a word
  /// already vary makes the number mean the same thing for everyone: "these
  /// two words are N times further apart than your own repeats of one of
  /// them."
  ///
  /// Below ~1.0 the words are closer to each other than a word is to itself,
  /// which is the regime where confusion is routine.
  final double margin;

  /// True for the general/summon opener pair — see the file header.
  final bool isOpenerPair;

  /// The bar this pair has to clear.
  ///
  /// UNRATIFIED (§8.11 leaves the threshold open). These are starting points
  /// chosen to be legible, not measured: the openers get a higher bar because
  /// collapsing them is the one confusion worth money.
  double get requiredMargin => isOpenerPair ? 1.6 : 1.1;

  bool get isTooClose => margin < requiredMargin;

  /// 0.0 (indistinguishable) → 1.0 (comfortably clear). For a meter.
  double get meter => (margin / (requiredMargin * 1.5)).clamp(0.0, 1.0);
}

/// The full pairwise picture for one vocabulary.
class VocabularySeparation {
  const VocabularySeparation(this.pairs);

  final List<SlotPairSeparation> pairs;

  /// Pairs that will be confused, worst first — openers ahead of elements at
  /// equal severity, since that is the costlier confusion.
  List<SlotPairSeparation> get warnings {
    final flagged = [...pairs.where((p) => p.isTooClose)]..sort((x, y) {
        if (x.isOpenerPair != y.isOpenerPair) return x.isOpenerPair ? -1 : 1;
        return x.margin.compareTo(y.margin);
      });
    return flagged;
  }

  bool get isClean => warnings.isEmpty;

  /// The opener pair, if both openers were enrolled.
  SlotPairSeparation? get openerPair =>
      pairs.where((p) => p.isOpenerPair).firstOrNull;

  /// Measures every pair among the slots present in [takesBySlot].
  ///
  /// [takesBySlot] is the player's enrolled exemplars — the same take sets the
  /// scorer will rank against, so this measures the vocabulary that will
  /// actually be used rather than a proxy for it.
  static VocabularySeparation measure(
    Map<VocalSlot, List<List<List<double>>>> takesBySlot,
  ) {
    // Conditioned by the SCORER's own normalise(), not a copy of it. A copy
    // would drift, and then this would measure the separation of a feature
    // space nothing actually uses — reassuring the player about a confusion
    // the recogniser still makes.
    final usable = {
      for (final e in takesBySlot.entries)
        if (e.value.isNotEmpty) e.key: e.value.map(IncantationRecallScorer.normalise).toList(),
    };
    final slots = usable.keys.toList();
    final pairs = <SlotPairSeparation>[];

    for (var i = 0; i < slots.length; i++) {
      for (var j = i + 1; j < slots.length; j++) {
        final a = slots[i];
        final b = slots[j];
        // Only compare like with like: an element is never a candidate for the
        // opener position and vice versa, so their separation is not a thing
        // the recogniser can get wrong.
        if (a.isOpener != b.isOpener) continue;

        final between = _minCross(usable[a]!, usable[b]!);
        final within = (_spread(usable[a]!) + _spread(usable[b]!)) / 2;
        pairs.add(SlotPairSeparation(
          a: a,
          b: b,
          // A speaker with only one take per word has no measurable spread.
          // Fall back to the raw distance rather than dividing by zero; the
          // number is less comparable, but a second take fixes it and the UI
          // asks for one.
          margin: within > 1e-9 ? between / within : between,
          isOpenerPair: a.isOpener && b.isOpener,
        ));
      }
    }
    return VocabularySeparation(pairs);
  }

  /// Closest approach between any take of one word and any take of the other —
  /// the min, not the mean, because the recogniser decides on the min too.
  /// One unlucky pair of takes is all a confusion needs.
  static double _minCross(
    List<List<List<double>>> a,
    List<List<List<double>>> b,
  ) {
    var best = double.infinity;
    for (final x in a) {
      for (final y in b) {
        final d = DtwMatcher.distance(x, y);
        if (d < best) best = d;
      }
    }
    return best.isFinite ? best : 0.0;
  }

  /// How much a speaker's own repeats of one word differ. With a single take
  /// there is nothing to compare, so the spread is unknown (0.0).
  static double _spread(List<List<List<double>>> takes) {
    if (takes.length < 2) return 0.0;
    var total = 0.0;
    var count = 0;
    for (var i = 0; i < takes.length; i++) {
      for (var j = i + 1; j < takes.length; j++) {
        final d = DtwMatcher.distance(takes[i], takes[j]);
        if (d.isFinite) {
          total += d;
          count++;
        }
      }
    }
    return count == 0 ? 0.0 : total / count;
  }

}
