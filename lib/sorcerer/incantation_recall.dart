// SPDX-License-Identifier: GPL-3.0-or-later
//
// incantation_recall.dart — IncantationRecall: what the caster actually said,
// and what it costs them.
//
// VOCAL_RECALL_PLAN.md §3/§6/§8.5. This replaces VocalScore's pronunciation
// model. The difference is not one of degree: pronunciation quality is
// structurally unverifiable (vocal_score.dart says outright that the peer
// "does not and cannot recalculate the score from audio"), whereas the
// correct incantation is a pure function of `dominance_trajectory` — a
// PUBLIC INPUT to the proof — so the peer can recompute it and check the
// claim. What crosses the wire is therefore what was SAID, not a score.
//
// ── Why this file has no doubles ──────────────────────────────────────────
//
// The multiplier lands on the mana ledger, which both devices compute
// independently and must agree on exactly (see
// DeterministicResolution.certifiedManaCost / spellCostBreakdown, whose
// operation order is already coupled for this reason).
// A one-ULP disagreement becomes a one-mana disagreement becomes a state-hash
// desync becomes a forfeit.
//
// Two things follow, and neither is optional:
//
//   1. The per-word step is a BAKED INTEGER TABLE, not a computed power.
//      `pow`/`exp` with fractional exponents are not guaranteed bit-identical
//      across platforms and libm versions, and this step is length-normalised
//      (below), so it would otherwise be a fractional power evaluated on two
//      different phones.
//   2. The product is exact BigInt arithmetic, rounded ONCE at the end.
//
// ── The cost model ────────────────────────────────────────────────────────
//
//   n    = 1 (the opener) + one per element word    — total scored units
//   step = 1 − 0.737^(1/n)                          — see _kStepPpm
//   cost = base × (1−step)^correct × (1+step)^(wrong_elements + 3×wrong_opener)
//
// Flat and ORDER-INDEPENDENT: `M M X M M X` and `M M M M X X` score
// identically (§5, accepted trade — accuracy, not fluency).
//
// The opener is scored at ASYMMETRIC weight, 1× correct / 3× wrong (§8.5).
// An unscored opener would be a telegraph whose entire value accrues to the
// opponent, so rational play would degrade it — mumbled or clipped — until it
// was worthless. Scoring is the only enforcement available, since nothing can
// verify that a player spoke rather than tapped. Asymmetry is what buys a
// strong deterrent without spending the discount ceiling on it.
//
// ── Why the step is normalised to length ──────────────────────────────────
//
// §8.5 ratified a flat step = 0.03 against a 3–9 element vocabulary. But
// FormulaTracker.step commits at most one activation per generation, so a
// tier-48 spell can reach 48 element words — and at a flat 0.03 a perfect
// recital hits §3's binding constraint (an ungated skill check must NEVER beat
// the gated Water/Efficiency loadout at −33%) by ~13 element words, reaching
// −77% at 48. Normalising the step to n holds a perfect recital at the
// ratified −26.3% for every length.
//
// This GENERALISES the ratified numbers rather than overturning them: at 9
// element words the table gives 30056 ppm against the ratified 0.03, and a
// total blank of +42.67% against §8.5's +42.6%.
//
// Consequence, flagged for playtest: per-word stakes now vary with length. A
// 3-element spell puts ~7.3% on each of 4 units (all-or-nothing); a
// 48-element spell puts ~0.62% on each (a grind). Same ceiling either way.
// This also means the opener deterrent is strongest on SHORT spells, which is
// where §8.5 wanted it — short incantations are the cheapest to fake.

import 'dart:typed_data';

import 'vocal_slot.dart';

/// What the caster's device heard, as slots — never words.
///
/// A null entry means "no utterance": the capture window produced nothing
/// recognisable at that position. It scores exactly as a wrong word does.
/// Reporting it is never an exploit, since it can only ever cost the caster
/// more mana than a correct guess and never less than a wrong one.
///
/// Per §8.6 there is deliberately NO ambiguous state. When two candidates are
/// close, the best guess is transmitted anyway and the peer checks it. An
/// explicit "low confidence" flag would be self-reported (the B-1/B-8 shape)
/// and would buy something strictly better than it prices: a caster could keep
/// four crisp words for their own accuracy and merely *declare* ambiguity on
/// the casts where hiding a summon matters. Best-guess transmission makes
/// ambiguity price itself at exactly the rate the confusion occurs — collapse
/// your two openers and you pay ≈ +6.3% mana on every cast, forever.
class IncantationRecall {
  const IncantationRecall({required this.opener, required this.elements});

  /// The opener slot the caster's device decided it heard, or null for no
  /// utterance. Always an opener slot when non-null.
  final VocalSlot? opener;

  /// One entry per element word heard, in spoken order. May be shorter or
  /// longer than the expected sequence; see [tallyAgainst].
  final List<VocalSlot?> elements;

  /// Nothing was captured at all — sorcerer mode off, microphone denied, or
  /// a cast that never opened a capture window. Scores as a total blank.
  static const IncantationRecall silent =
      IncantationRecall(opener: null, elements: []);

  // ── Scoring ───────────────────────────────────────────────────────────────

  /// Compares what was said against what the certified trajectory says should
  /// have been said.
  ///
  /// [expectedIsSummon] must come from `SpellAsset.isSummon`, and
  /// [expectedElements] from the CERTIFIED formula list — never from
  /// caster-supplied wire values. Both are already consensus-visible, which
  /// is what makes this verifiable rather than self-reported.
  ///
  /// Length disagreement is resolved in favour of the expectation: positions
  /// the caster did not speak count as wrong, and anything spoken past the
  /// expected length is ignored. So a lie about how many words were spoken
  /// changes nothing — which is why the wire's count byte can stay untrusted
  /// framing rather than becoming a new forfeit condition.
  RecallTally tallyAgainst({
    required bool expectedIsSummon,
    required List<VocalSlot> expectedElements,
  }) {
    final expectedOpener = VocalSlot.openerFor(isSummon: expectedIsSummon);
    final openerCorrect = opener == expectedOpener;

    var correct = openerCorrect ? 1 : 0;
    var weightedWrong = openerCorrect ? 0 : openerWrongWeight;

    for (var i = 0; i < expectedElements.length; i++) {
      final spoken = i < elements.length ? elements[i] : null;
      if (spoken == expectedElements[i]) {
        correct++;
      } else {
        weightedWrong++;
      }
    }

    return RecallTally(
      correct: correct,
      weightedWrong: weightedWrong,
      units: 1 + expectedElements.length,
    );
  }

  /// Wrong-opener penalty weight (§8.5). Correct is always weight 1.
  static const int openerWrongWeight = 3;

  // ── Wire ──────────────────────────────────────────────────────────────────
  //
  // Rides inside the existing SpellCastAction payload, replacing VocalScore's
  // 3-byte suffix. No new BattleMsgType — this is per-turn action data, not a
  // new exchange.
  //
  //   byte 0      opener: 0 = general, 1 = summon, 2 = no utterance
  //   byte 1      spokenCount (0..255) — FRAMING ONLY, untrusted
  //   byte 2..N   one per spoken element: 0..3 = slot, 0xFF = no utterance
  //
  // One byte per word rather than a packed 3-bit stream: the same payload
  // already carries a multi-kilobyte ZK proof, so the ~50 bytes this costs
  // buy nothing worth losing debuggability over.

  static const int _openerGeneralCode = 0;
  static const int _openerSummonCode = 1;
  static const int _absentCode = 2;
  static const int _elementAbsentCode = 0xFF;

  /// Upper bound on transmitted element words. A tier-48 spell reaches 48;
  /// this caps a hostile or corrupt payload from allocating unboundedly.
  static const int maxElements = 48;

  Uint8List toWireBytes() {
    final capped = elements.length > maxElements
        ? elements.sublist(0, maxElements)
        : elements;
    final out = Uint8List(2 + capped.length);
    out[0] = switch (opener) {
      VocalSlot.openerGeneral => _openerGeneralCode,
      VocalSlot.openerSummon => _openerSummonCode,
      _ => _absentCode,
    };
    out[1] = capped.length;
    for (var i = 0; i < capped.length; i++) {
      final slot = capped[i];
      out[2 + i] =
          (slot != null && slot.isElement) ? slot.index : _elementAbsentCode;
    }
    return out;
  }

  /// Decodes from [bytes] at [offset]. Returns the recall and how many bytes
  /// it consumed, so the caller can continue parsing the payload.
  ///
  /// Tolerates a truncated or overlong payload rather than throwing: a
  /// malformed recall degrades to "no utterance" at the affected positions,
  /// which scores as wrong. There is nothing here worth forfeiting a match
  /// over — the values are the caster's own claim about their own recital,
  /// and every malformed reading costs them, not the peer.
  static ({IncantationRecall recall, int bytesRead}) fromWireBytes(
    Uint8List bytes,
    int offset,
  ) {
    if (offset + 2 > bytes.length) {
      return (recall: silent, bytesRead: bytes.length - offset);
    }
    final opener = switch (bytes[offset]) {
      _openerGeneralCode => VocalSlot.openerGeneral,
      _openerSummonCode => VocalSlot.openerSummon,
      _ => null,
    };
    final declared = bytes[offset + 1];
    final available = bytes.length - (offset + 2);
    final count =
        [declared, available, maxElements].reduce((a, b) => a < b ? a : b);
    final elements = <VocalSlot?>[
      for (var i = 0; i < count; i++)
        if (bytes[offset + 2 + i] < VocalSlot.elements.length)
          VocalSlot.elements[bytes[offset + 2 + i]]
        else
          null,
    ];
    return (
      recall: IncantationRecall(opener: opener, elements: elements),
      bytesRead: 2 + count,
    );
  }

  @override
  String toString() => 'IncantationRecall(opener: ${opener?.name}, '
      'elements: [${elements.map((e) => e?.name ?? '-').join(',')}])';
}

/// The outcome of comparing a recital against its expected sequence.
class RecallTally {
  const RecallTally({
    required this.correct,
    required this.weightedWrong,
    required this.units,
  });

  /// Units recalled correctly (opener counts 1).
  final int correct;

  /// Penalty weight of the misses: one per wrong element, plus
  /// [IncantationRecall.openerWrongWeight] if the opener was wrong.
  final int weightedWrong;

  /// Total scored units, `1 + elementCount`. The step is normalised to this.
  final int units;

  /// A perfect recital of every unit.
  bool get isPerfect => weightedWrong == 0;

  /// Applies the recall multiplier to [cost], exactly and in integers.
  ///
  /// Rounds UP once at the end, matching every other step in TurnLoop's mana
  /// chain. Both devices run this on the same tally and so land on the same
  /// integer; that is the whole point of the file.
  int applyTo(int cost) {
    if (cost <= 0) return cost;
    final step = BigInt.from(stepPpmFor(units));
    final scale = BigInt.from(_ppmScale);

    final numerator = (scale - step).pow(correct) * (scale + step).pow(weightedWrong);
    final denominator = scale.pow(correct + weightedWrong);

    final scaled = BigInt.from(cost) * numerator;
    // Ceiling division: (a + b - 1) ~/ b, exact for positive b.
    return ((scaled + denominator - BigInt.one) ~/ denominator).toInt();
  }

  @override
  String toString() =>
      'RecallTally(correct: $correct, weightedWrong: $weightedWrong, '
      'units: $units)';
}

// ── The step table ──────────────────────────────────────────────────────────

/// Fixed-point scale for [_kStepPpm]: parts per million.
const int _ppmScale = 1000000;

/// Perfect-recital multiplier, in ppm — §8.5's ratified −26.3% ceiling.
///
/// The one number the table is built to hit at every length. It sits under
/// §3's −33% gate with 6.7 points of headroom, which is the constraint the
/// whole cost model exists to respect.
const int kPerfectMultiplierPpm = 737000;

/// Per-unit step, in ppm, indexed by unit count `n` (`1 + elementCount`).
///
/// GENERATED, not hand-written: `step_ppm[n] = round((1 − 0.737^(1/n)) × 1e6)`.
/// Baked as source because evaluating that fractional power at runtime is not
/// bit-reproducible across devices, and this value feeds the mana ledger. See
/// the file header, and incantation_recall_test.dart, which re-derives every
/// entry and re-checks the −33% gate at every length.
///
/// Index 0 is unused (a cast always has at least the opener).
const List<int> _kStepPpm = [
  0, 263000, 141513, 96720, 73454, 59208, 49589, 42659,
  37428, 33339, 30056, 27361, 25110, 23201, 21562, 20139,
  18892, 17791, 16811, 15933, 15143, 14427, 13775, 13181,
  12635, 12132, 11669, 11239, 10840, 10468, 10121, 9796,
  9491, 9205, 8935, 8681, 8441, 8214, 7999, 7794,
  7600, 7415, 7240, 7072, 6912, 6759, 6612, 6472,
  6337, 6209,
];

/// The step for a recital of [units] scored units, clamped to the table.
///
/// Beyond the table (which covers the tier-48 maximum of 1 + 48) the last
/// entry is reused: a longer recital than the largest legal spell cannot
/// occur, and reusing the flattest step is the conservative direction.
int stepPpmFor(int units) {
  if (units <= 1) return _kStepPpm[1];
  return units < _kStepPpm.length ? _kStepPpm[units] : _kStepPpm.last;
}
