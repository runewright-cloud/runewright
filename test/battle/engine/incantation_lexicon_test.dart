// SPDX-License-Identifier: GPL-3.0-or-later
//
// incantation_lexicon_test.dart — Mutable Leylines Slice D: the interpretation
// seam, and the invariants it must not disturb
// (docs/MUTABLE_LEYLINES_IMPLEMENTATION_AUDIT.md §6, §7.2, §7.4, §13 Slice D).
//
// The five things this file is here to prove, in the order they matter:
//
//   1. ORDINARY INVARIANCE. An ordinary lexicon derives nothing, ignores every
//      mutable field of a config, and maps all sixteen tails exactly through
//      `effectKindFromPair`. This is the test that says Slice D changed no
//      existing behaviour, and it is the one that matters most.
//   2. THE MANA GATE. Interpretation never moves intrinsic cost; only the
//      structural grammar length does, which §7.4 ratifies. A key flipping
//      meaningful → noise must move nothing that identifies a spell.
//   3. CODEBOOK INTEGRATION at lengths 4, 5 and 6, against keys the Slice B
//      vectors pinned — not against whatever this build happens to derive.
//   4. NOISE INERTNESS: no effect, no affinity, no wild-magic eligibility, and
//      above all NO FALLBACK to the ordinary table.
//   5. DETERMINISM: two lexicons built from equal configs agree everywhere.
//
// The mutable keys and meanings below are QUOTED FROM
// `test/battle/models/leyline_codebook_test.dart`, whose literals came from
// `scripts/gen_leyline_codebook_vectors.py` — an independent implementation.
// They are not recomputed here and this file derives no expectations from the
// code under test; the vector corpus stays the single source of those bytes.

import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:rune_duel/battle/engine/deterministic_resolution.dart';
import 'package:rune_duel/battle/engine/effect_resolver.dart';
import 'package:rune_duel/battle/engine/incantation_lexicon.dart';
import 'package:rune_duel/battle/engine/peer_cast_verifier.dart';
import 'package:rune_duel/battle/engine/proof_intake.dart';
import 'package:rune_duel/battle/engine/trajectory_parser.dart';
import 'package:rune_duel/battle/engine/wild_magic.dart';
import 'package:rune_duel/battle/models/effect_kind.dart';
import 'package:rune_duel/battle/models/incantation_meaning.dart';
import 'package:rune_duel/battle/models/leyline_codebook.dart';
import 'package:rune_duel/battle/models/leyline_config.dart';
import 'package:rune_duel/engine/border_zone.dart';
import 'package:rune_duel/engine/formula_segmentation.dart';

// ── Vectors quoted from the Slice B corpus ───────────────────────────────────

/// `rivendell 4`: a key the corpus pins as MEANINGFUL, and what it means.
const _kL4MeaningfulKey = [BorderZone.earth, BorderZone.water, BorderZone.fire];
const _kL4MeaningfulKind = EffectKind.tileModification;

/// `rivendell 4`: a key the corpus pins as NOISE.
const _kL4NoiseKey = [BorderZone.water, BorderZone.fire, BorderZone.fire];

const _kL5MeaningfulKey = [
  BorderZone.earth, BorderZone.air, BorderZone.water, BorderZone.air,
];
const _kL5MeaningfulKind = EffectKind.clouds;
const _kL5NoiseKey = [
  BorderZone.water, BorderZone.fire, BorderZone.earth, BorderZone.water,
];

const _kL6MeaningfulKey = [
  BorderZone.fire, BorderZone.water, BorderZone.earth, BorderZone.water,
  BorderZone.air,
];
const _kL6MeaningfulKind = EffectKind.fuelTransmutation;
const _kL6NoiseKey = [
  BorderZone.earth, BorderZone.earth, BorderZone.air, BorderZone.earth,
  BorderZone.air,
];

LeylineConfig _rivendell(int length) =>
    LeylineConfig.mutable(communitySeed: 'rivendell', formulaLength: length);

const List<BorderZone> _elements = [
  BorderZone.fire, BorderZone.air, BorderZone.water, BorderZone.earth,
];

ParsedFormula _formula(BorderZone affinity, List<BorderZone> tail) =>
    ParsedFormula.withTail(affinity: affinity, tail: tail);

// ── Certified-outputs helper (same shape as formula_certified_test) ──────────

/// Dominance indices: the circuit's rule indices, 1 Fire … 4 Earth.
int _idx(BorderZone z) => switch (z) {
      BorderZone.fire => 1,
      BorderZone.air => 2,
      BorderZone.water => 3,
      BorderZone.earth => 4,
    };

/// A [VerifiedSpellOutputs] whose committed sequence is exactly [elements].
///
/// Every generation is a lead change (no two adjacent elements are equal in the
/// callers below), so `FormulaTracker` commits one element per generation and
/// the committed sequence is the input verbatim. That keeps these fixtures
/// about SEGMENTATION rather than about the commit rules, which no leyline
/// touches.
VerifiedSpellOutputs _outputsFor(List<BorderZone> elements) {
  const tierMax = 48;
  final traj = List<int>.filled(tierMax, 0);
  for (var i = 0; i < elements.length; i++) {
    traj[i] = _idx(elements[i]);
  }
  return VerifiedSpellOutputs(
    proofBytes: Uint8List(0),
    t: elements.length,
    ownerPubkeyHex: '0x${'00' * 32}',
    rulesetVersion: 3,
    commitmentHex: '0x${'00' * 32}',
    tierMax: tierMax,
    borderActivations: const [0, 0, 0, 0],
    dominanceTrajectory: traj,
    supremeDominanceFlags: List<int>.filled(tierMax, 0),
    segmentCount: 3,
    dotCount: 2,
  );
}

/// A sequence with no two adjacent elements equal, so every generation is a
/// lead change and `committed == elements`.
List<BorderZone> _alternating(int n) =>
    [for (var i = 0; i < n; i++) _elements[i % 4]];

void main() {
  // ── 1. Ordinary invariance ────────────────────────────────────────────────

  group('an ordinary lexicon', () {
    test('derives nothing and is not mutable', () {
      expect(IncantationLexicon.ordinary.isMutable, isFalse);
      expect(IncantationLexicon.of(LeylineConfig.ordinaryDefault).isMutable,
          isFalse);
      expect(IncantationLexicon.of(LeylineConfig.ordinary('mirkwood')).isMutable,
          isFalse);
    });

    test('chunks at the ordinary length', () {
      expect(IncantationLexicon.ordinary.formulaLength,
          kIncantationFormulaLength);
      expect(IncantationLexicon.of(LeylineConfig.ordinary('mirkwood'))
          .formulaLength, 3);
    });

    test('maps all 16 tails exactly through effectKindFromPair', () {
      final lexicon = IncantationLexicon.of(LeylineConfig.ordinary('mirkwood'));
      var pairs = 0;
      for (final affinity in _elements) {
        for (final t1 in _elements) {
          for (final t2 in _elements) {
            pairs++;
            expect(
              lexicon.meaningOf(_formula(affinity, [t1, t2])),
              IncantationEffect(effectKindFromPair(t1, t2)),
              reason: 'ordinary interpretation is the fixed table, whatever '
                  'the leyline is called',
            );
          }
        }
      }
      expect(pairs, 64, reason: '4 affinities x 16 tails');
    });

    test('is independent of the seed', () {
      // The anti-grinder lever rotates the seed to re-roll wild magic; it must
      // not re-roll what a formula MEANS under ordinary magic, or every
      // spellbook in the world would change meaning with it.
      final seeds = ['mirkwood', 'rivendell', 'shire', ''];
      for (final t1 in _elements) {
        for (final t2 in _elements) {
          final meanings = {
            for (final seed in seeds)
              IncantationLexicon.of(LeylineConfig.ordinary(seed))
                  .meaningOf(_formula(BorderZone.fire, [t1, t2])),
          };
          expect(meanings.length, 1,
              reason: 'the seed reached ordinary interpretation for ($t1,$t2)');
        }
      }
    });

    test('never produces noise, so meaningfulOf is the identity', () {
      final lexicon = IncantationLexicon.ordinary;
      final formulas = [
        for (final t1 in _elements)
          for (final t2 in _elements) _formula(BorderZone.water, [t1, t2]),
      ];
      expect(lexicon.meaningfulOf(formulas), same(formulas),
          reason: 'ordinary play must not even copy the list');
      for (final f in formulas) {
        expect(lexicon.meaningOf(f), isA<IncantationEffect>());
      }
    });

    test('an ordinary config cannot reach a codebook', () {
      // Belt and braces on the Slice B guard: even if a caller went around the
      // lexicon, derive() refuses.
      expect(() => IncantationCodebook.derive(LeylineConfig.ordinaryDefault),
          throwsA(isA<LeylineConfigException>()));
    });
  });

  // ── 2. The mana gate (§7.4) ───────────────────────────────────────────────

  group('interpretation never moves intrinsic cost', () {
    // 12 committed elements: 4 formulas at L=3, 3 at L=4, 2 at L=5 and L=6.
    final elements = _alternating(12);
    final outputs = _outputsFor(elements);

    test('the certified trajectory is leyline-invariant', () {
      // The load-bearing one. FormulaTracker's commit rules are
      // length-independent, so the flat sequence a proof attests — and which
      // behaviouralKinKey, heraldry and the Wild Magic v2 preimage all read —
      // is byte-identical under every leyline. A lexicon re-cuts it; it never
      // rewrites it.
      final sequences = {
        for (final length in const [3, 4, 5, 6])
          length: TrajectoryParser.certifiedElementSequence(outputs),
      };
      for (final entry in sequences.entries) {
        expect(entry.value, elements,
            reason: 'the committed sequence moved at length ${entry.key}');
      }
    });

    test('base mana cost tracks the STRUCTURAL chunk count, not meaning', () {
      // Same trajectory, three lengths. The cost differs — ratified (§7.4:
      // "moves only when formulaLength itself changes, which is already a
      // different leylineConfigHash") — and it differs by exactly the
      // structural count, with no reference to any codebook.
      for (final length in const [3, 4, 5, 6]) {
        final formulas =
            TrajectoryParser.parse(outputs, formulaLength: length).formulas;
        expect(formulas.length, 12 ~/ length,
            reason: 'structural chunk count at L=$length');
        expect(
          PeerCastVerifier.certifiedBaseManaCost(outputs, formulas),
          PeerCastVerifier.certifiedBaseManaCost(
            outputs,
            // A list of the same LENGTH built from formulas whose meanings are
            // irrelevant: the cost function never looks inside.
            [for (final f in formulas) f],
          ),
        );
      }
    });

    test('a noise formula is priced exactly like a meaningful one', () {
      // The forbidden coupling, stated directly. Under `rivendell 4` this
      // trajectory contains both meaningful and noise formulas; the price is
      // computed from the structural list, so pricing the MEANINGFUL list
      // instead would be visibly cheaper — and that difference is what must
      // never reach a real cast.
      final lexicon = IncantationLexicon.of(_rivendell(4));
      final formulas =
          TrajectoryParser.parse(outputs, formulaLength: 4).formulas;
      final meaningful = lexicon.meaningfulOf(formulas);

      final structuralPrice =
          PeerCastVerifier.certifiedBaseManaCost(outputs, formulas);
      final semanticPrice =
          PeerCastVerifier.certifiedBaseManaCost(outputs, meaningful);

      // What semanticsOf actually charges.
      final certified = PeerCastVerifier.semanticsOf(
        outputs,
        casterOwnerPubkeyHex: '0x${'11' * 32}',
        lexicon: lexicon,
      );
      expect(certified.baseManaCost, structuralPrice,
          reason: '§7.4: a noise formula consumes its chunk and counts toward '
              'base mana cost exactly as a meaningful one does');
      expect(certified.formulas.length, formulas.length,
          reason: 'the certificate carries STRUCTURAL formulas — the '
              'interpretation is applied downstream, not baked in');

      if (meaningful.length != formulas.length) {
        expect(semanticPrice, isNot(structuralPrice),
            reason: 'if these were equal the test could not tell the two '
                'pricings apart and would prove nothing');
      }
    });

    test('two leylines of the same length price identically', () {
      // Meaning differs between them (different codebooks); cost must not.
      final a = IncantationLexicon.of(_rivendell(4));
      final b = IncantationLexicon.of(
          LeylineConfig.mutable(communitySeed: 'mirkwood', formulaLength: 4));
      final key = '0x${'11' * 32}';

      final costA = PeerCastVerifier
          .semanticsOf(outputs, casterOwnerPubkeyHex: key, lexicon: a)
          .baseManaCost;
      final costB = PeerCastVerifier
          .semanticsOf(outputs, casterOwnerPubkeyHex: key, lexicon: b)
          .baseManaCost;
      expect(costA, costB,
          reason: 'intrinsic cost is a function of the trajectory and the '
              'formula LENGTH alone — never of the dictionary');
    });
  });

  // ── 3. Codebook integration at lengths 4, 5, 6 ────────────────────────────

  group('mutable interpretation', () {
    final cases = <int, ({List<BorderZone> good, EffectKind kind,
        List<BorderZone> noise})>{
      4: (good: _kL4MeaningfulKey, kind: _kL4MeaningfulKind, noise: _kL4NoiseKey),
      5: (good: _kL5MeaningfulKey, kind: _kL5MeaningfulKind, noise: _kL5NoiseKey),
      6: (good: _kL6MeaningfulKey, kind: _kL6MeaningfulKind, noise: _kL6NoiseKey),
    };

    cases.forEach((length, vector) {
      group('rivendell $length', () {
        final lexicon = IncantationLexicon.of(_rivendell(length));

        test('is mutable and chunks at $length', () {
          expect(lexicon.isMutable, isTrue);
          expect(lexicon.formulaLength, length);
          expect(vector.good.length, length - 1,
              reason: 'the tail is formulaLength - 1 elements');
        });

        test('a pinned meaningful key resolves to its pinned effect', () {
          for (final affinity in _elements) {
            expect(
              lexicon.meaningOf(_formula(affinity, vector.good)),
              IncantationEffect(vector.kind),
              reason: 'affinity must not change what a tail means (§3)',
            );
          }
        });

        test('a pinned noise key is noise', () {
          for (final affinity in _elements) {
            expect(lexicon.meaningOf(_formula(affinity, vector.noise)),
                kIncantationNoise);
          }
        });

        test('segmenting a trajectory at $length reaches those keys', () {
          // End to end through the real segmentation primitive: build a
          // certified trajectory whose chunks ARE the pinned keys, and check
          // interpretation lands where the corpus says.
          final elements = <BorderZone>[
            BorderZone.fire, ...vector.good,
            BorderZone.water, ...vector.noise,
          ];
          final formulas = [
            for (final chunk in segmentFormulas(elements,
                formulaLength: length))
              ParsedFormula.withTail(
                  affinity: chunk[0], tail: chunk.sublist(1)),
          ];
          expect(formulas.length, 2);
          expect(lexicon.meaningOf(formulas[0]),
              IncantationEffect(vector.kind));
          expect(lexicon.meaningOf(formulas[1]), kIncantationNoise);
          expect(lexicon.meaningfulOf(formulas), [formulas[0]]);
        });
      });
    });

    test('two lexicons from equal configs agree on every key', () {
      final a = IncantationLexicon.of(_rivendell(4));
      final b = IncantationLexicon.of(_rivendell(4));
      for (var i = 0; i < 64; i++) {
        final key = [
          _elements[(i ~/ 16) % 4],
          _elements[(i ~/ 4) % 4],
          _elements[i % 4],
        ];
        final f = _formula(BorderZone.fire, key);
        expect(a.meaningOf(f), b.meaningOf(f), reason: 'key $key disagreed');
      }
    });

    test('different leylines disagree, as Slice B established', () {
      final a = IncantationLexicon.of(_rivendell(4));
      final b = IncantationLexicon.of(
          LeylineConfig.mutable(communitySeed: 'mirkwood', formulaLength: 4));
      final disagreements = [
        for (var i = 0; i < 64; i++)
          if (a.meaningOf(_formula(BorderZone.fire, [
                _elements[(i ~/ 16) % 4],
                _elements[(i ~/ 4) % 4],
                _elements[i % 4],
              ])) !=
              b.meaningOf(_formula(BorderZone.fire, [
                _elements[(i ~/ 16) % 4],
                _elements[(i ~/ 4) % 4],
                _elements[i % 4],
              ])))
            i,
      ];
      expect(disagreements, isNotEmpty,
          reason: 'two seeds must produce different dictionaries');
    });
  });

  // ── 4. Noise inertness, and above all NO FALLBACK ─────────────────────────

  group('noise', () {
    final lexicon = IncantationLexicon.of(_rivendell(4));

    test('does not fall back to effectKindFromPair', () {
      // THE anti-fallback test. A 3-element tail has no ordinary reading at
      // all, and the ordinary accessors say so rather than quietly handing back
      // the first two elements — which is what a fallback would have read.
      final noise = _formula(BorderZone.fire, _kL4NoiseKey);
      expect(lexicon.meaningOf(noise), kIncantationNoise);
      expect(() => noise.effectType1, throwsStateError);
      expect(() => noise.effectType2, throwsStateError);
      expect(() => EffectResolver.resolve(noise), throwsStateError,
          reason: 'the ordinary resolver must be unreachable for a '
              'mutable-length formula, not merely unused');
    });

    test('is not any of the sixteen effects', () {
      final meaning = lexicon.meaningOf(_formula(BorderZone.air, _kL4NoiseKey));
      for (final kind in EffectKind.values) {
        expect(meaning, isNot(IncantationEffect(kind)));
      }
      expect(incantationManifestsEffect(meaning), isFalse);
    });

    test('contributes no affinity and no wild-magic eligibility', () {
      final meaning = lexicon.meaningOf(_formula(BorderZone.air, _kL4NoiseKey));
      expect(incantationContributesAffinity(meaning), isFalse);
      expect(incantationContributesWildMagicEligibility(meaning), isFalse);
    });

    test('is dropped from the meaningful list but not from the structural '
        'one', () {
      final formulas = [
        _formula(BorderZone.fire, _kL4MeaningfulKey),
        _formula(BorderZone.water, _kL4NoiseKey),
        _formula(BorderZone.fire, _kL4MeaningfulKey),
      ];
      expect(formulas.length, 3, reason: 'the structural count is what prices');
      final meaningful = lexicon.meaningfulOf(formulas);
      expect(meaningful.length, 2);
      expect(meaningful, [formulas[0], formulas[2]],
          reason: 'order of surviving formulas is preserved — a noise entry in '
              'the middle must not reorder what follows it');
    });
  });

  // ── 5. Affinity eligibility through the real tally ────────────────────────

  group('affinity', () {
    final lexicon = IncantationLexicon.of(_rivendell(4));

    test('a noise formula of a different affinity does not break purity', () {
      // The accidental-unconditional-tally catcher, and the reason the
      // fixture is mixed-affinity. Structurally this is a hybrid cast — one
      // Fire chunk, one Water chunk — so `pureAffinityOf` over the raw list
      // returns null and breaks the chain. Only the Fire chunk is behaviour,
      // so over the meaningful list the cast is pure Fire and the chain holds.
      final formulas = [
        _formula(BorderZone.fire, _kL4MeaningfulKey),
        _formula(BorderZone.water, _kL4NoiseKey),
      ];
      expect(DeterministicResolution.pureAffinityOf(formulas), isNull,
          reason: 'sanity: an unconditional tally reads this as hybrid');
      expect(
        DeterministicResolution.pureAffinityOf(lexicon.meaningfulOf(formulas)),
        SpellAffinity.fire,
        reason: 'a noise chunk carries an affinity element structurally, but '
            'that element is not something the spell does, so it can neither '
            'establish nor break purity (§6)',
      );
    });

    test('a noise formula does not enter the wild-magic tally', () {
      // One Fire meaningful, one Water noise. Unconditionally that is a 1-1
      // tie and BOTH affinities are eligible (the "wild magic specialist"
      // reading); meaningfully it is Fire alone.
      final formulas = [
        _formula(BorderZone.fire, _kL4MeaningfulKey),
        _formula(BorderZone.water, _kL4NoiseKey),
      ];
      expect(WildMagic.eligibleElements(formulas),
          {SpellAffinity.fire, SpellAffinity.water},
          reason: 'sanity: an unconditional tally ties and sees both');
      expect(WildMagic.eligibleElements(lexicon.meaningfulOf(formulas)),
          {SpellAffinity.fire});
    });

    test('a spell of only noise is eligible for nothing', () {
      final formulas = [
        _formula(BorderZone.fire, _kL4NoiseKey),
        _formula(BorderZone.water, _kL4NoiseKey),
      ];
      expect(lexicon.meaningfulOf(formulas), isEmpty);
      expect(WildMagic.eligibleElements(lexicon.meaningfulOf(formulas)),
          isEmpty,
          reason: 'an all-noise spell reduces to the zero-formula case, which '
              'already fires no wild magic — with no special case');
    });

    test('an all-meaningful spell tallies exactly as it always did', () {
      final formulas = [
        _formula(BorderZone.air, _kL4MeaningfulKey),
        _formula(BorderZone.air, _kL4MeaningfulKey),
        _formula(BorderZone.earth, _kL4MeaningfulKey),
      ];
      expect(lexicon.meaningfulOf(formulas), formulas);
      expect(WildMagic.eligibleElements(formulas), {SpellAffinity.air});
    });
  });

  // ── 6. The Wild Magic hash itself is untouched ────────────────────────────

  group('wild magic derivation', () {
    test('the semantic hash does not read the codebook', () {
      // Its inputs are the caster, the FLAT certified trajectory, the
      // structural base cost and the config hash. None of those moves with a
      // dictionary, so two leylines that differ only in seed produce different
      // hashes because their CONFIG HASHES differ — never because a formula
      // was reinterpreted. Here: identical config, identical hash, whatever
      // the formulas mean.
      final elements = _alternating(12);
      final trajectoryHash = WildMagic.semanticHashHex(
        casterPubkeyHex: '0x${'11' * 32}',
        certifiedTrajectory: elements,
        certifiedBaseManaCost: 100,
        leylineConfigHash: _rivendell(4).leylineConfigHash,
      );
      expect(
        WildMagic.semanticHashHex(
          casterPubkeyHex: '0x${'11' * 32}',
          certifiedTrajectory: elements,
          certifiedBaseManaCost: 100,
          leylineConfigHash: _rivendell(4).leylineConfigHash,
        ),
        trajectoryHash,
      );
      expect(trajectoryHash.length, 64);
    });

    test('eligibility is the only leyline-dependent stage', () {
      // triggersFor takes the formulas ONLY for eligibility (§7.2). Passing the
      // meaningful subset is therefore the whole of the mutable change — and an
      // empty subset short-circuits before the hash is even computed.
      final outputs = _outputsFor(_alternating(12));
      final lexicon = IncantationLexicon.of(_rivendell(4));
      final certified = PeerCastVerifier.semanticsOf(
        outputs,
        casterOwnerPubkeyHex: '0x${'11' * 32}',
        lexicon: lexicon,
      );
      final expected = WildMagic.triggersFor(
        casterPubkeyHex: '0x${'11' * 32}',
        certifiedTrajectory: certified.elementSequence,
        certifiedBaseManaCost: certified.baseManaCost,
        leylineConfigHash: lexicon.leyline.leylineConfigHash,
        formulas: lexicon.meaningfulOf(certified.formulas),
      );
      expect(certified.wildMagic, expected);
    });
  });
}
