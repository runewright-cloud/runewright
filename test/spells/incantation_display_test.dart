// SPDX-License-Identifier: GPL-3.0-or-later
//
// incantation_display_test.dart — Mutable Leylines Slice E: the display layer
// says what the engine will do
// (docs/MUTABLE_LEYLINES_IMPLEMENTATION_AUDIT.md §13 Slice E).
//
// The core invariant this file exists to enforce:
//
//     No reachable UI may confidently describe an Incantation using ordinary
//     triplet semantics if battle resolution will use the Mutable lexicon.
//
// The four failure modes it pins, all of which were reachable before Slice E:
//
//   1. `battle says Noise` / `UI says Glacier` — a display taking its meaning
//      from `effectKindFromPair` while resolution takes it from the codebook.
//   2. `battle uses length 5` / `UI groups triplets` — a display segmenting at
//      the hardcoded 3 while resolution cuts at the active grammar.
//   3. `noise affinity appears as eligible` — an unconditional `chunk[0]`
//      count, which is what `spell_card_painter`'s histogram does and why the
//      eligibility answer had to move somewhere that knows about noise.
//   4. `a structurally void spell looks like a normal effective spell` — the
//      3-elements-under-length-4 case, where the ratified engine behaviour is
//      that NOTHING happens and there is no ordinary fallback.
//
// The mutable keys and meanings below are QUOTED from
// `test/battle/engine/incantation_lexicon_test.dart`, which quotes them from
// `test/battle/models/leyline_codebook_test.dart`, whose literals came from
// `scripts/gen_leyline_codebook_vectors.py`. Nothing here recomputes an
// expectation from the code under test — the vector corpus stays the single
// source of these bytes, and this file's job is to prove the DISPLAY reaches
// the same answer, not to re-derive the answer.

import 'package:test/test.dart';

import 'package:rune_duel/battle/engine/incantation_lexicon.dart';
import 'package:rune_duel/battle/engine/trajectory_parser.dart';
import 'package:rune_duel/battle/models/effect_kind.dart';
import 'package:rune_duel/battle/models/incantation_meaning.dart';
import 'package:rune_duel/battle/models/leyline_config.dart';
import 'package:rune_duel/engine/border_zone.dart';
import 'package:rune_duel/spells/incantation_display.dart';

// ── Vectors quoted from the Slice B corpus ───────────────────────────────────

/// `rivendell 4`: a tail the corpus pins as MEANINGFUL, and what it means.
const _kL4MeaningfulTail = [BorderZone.earth, BorderZone.water, BorderZone.fire];
const _kL4MeaningfulKind = EffectKind.tileModification;

/// `rivendell 4`: a tail the corpus pins as NOISE.
const _kL4NoiseTail = [BorderZone.water, BorderZone.fire, BorderZone.fire];

const _kL5MeaningfulTail = [
  BorderZone.earth, BorderZone.air, BorderZone.water, BorderZone.air,
];
const _kL5MeaningfulKind = EffectKind.clouds;

const _kL6MeaningfulTail = [
  BorderZone.fire, BorderZone.water, BorderZone.earth, BorderZone.water,
  BorderZone.air,
];
const _kL6MeaningfulKind = EffectKind.fuelTransmutation;
const _kL6NoiseTail = [
  BorderZone.earth, BorderZone.earth, BorderZone.air, BorderZone.earth,
  BorderZone.air,
];

LeylineConfig _rivendell(int length) =>
    LeylineConfig.mutable(communitySeed: 'rivendell', formulaLength: length);

/// A stored `SpellAsset.formula` — flat lowercase zone names — from zones.
List<String> _stored(List<BorderZone> zones) => [for (final z in zones) z.name];

/// One complete formula's worth of stored names: an affinity plus a tail.
List<String> _formulaNames(BorderZone affinity, List<BorderZone> tail) =>
    _stored([affinity, ...tail]);

void main() {
  // ── 1. Ordinary invariance ────────────────────────────────────────────────
  //
  // The test that matters most, and the one that says Slice E changed no
  // existing behaviour. Everything else here is about a leyline nobody can
  // reach except through solo practice; this is about every card in the game.

  group('ordinary invariance', () {
    test('agrees with formulaEffects on every ordinary tail', () {
      // Exhaustive over all 16 tails x 4 affinities. `formulaEffects` is the
      // legacy ordinary helper Slice E deliberately did NOT mutate, so it is
      // an independent oracle here: if the new view model ever drifts from it
      // under an ordinary lexicon, every ordinary card in the game has moved.
      const zones = BorderZone.values;
      for (final affinity in zones) {
        for (final t1 in zones) {
          for (final t2 in zones) {
            final stored = _formulaNames(affinity, [t1, t2]);
            final views =
                incantationViewsFor(stored, IncantationLexicon.ordinary);
            final legacy = formulaEffects(stored);
            expect(views.length, legacy.length);
            expect(views.single.affinity, legacy.single.affinity);
            expect(views.single.kind, legacy.single.kind);
            expect(views.single.name, legacy.single.name);
            expect(views.single.description, legacy.single.description);
          }
        }
      }
    });

    test('ordinary interpretation is total — noise is unreachable', () {
      // `ordinaryIncantationMeaning` is `effectKindFromPair`, which is total
      // over the sixteen tails. If a view ever came back as noise under an
      // ordinary lexicon, the ordinary table would have grown a hole.
      const zones = BorderZone.values;
      for (final affinity in zones) {
        for (final t1 in zones) {
          for (final t2 in zones) {
            final views = incantationViewsFor(
              _formulaNames(affinity, [t1, t2]),
              IncantationLexicon.ordinary,
            );
            expect(views.single.manifests, isTrue);
            expect(views.single.meaning, isA<IncantationEffect>());
            expect(views.single.name, isNot(kIncantationNoiseLabel));
          }
        }
      }
    });

    test('ordinary grouping is triplets, residuals dropped', () {
      // 7 elements at length 3 → two complete formulas and a 1-element
      // residual that forms nothing. Unchanged from `formulaEffects`.
      final stored = _stored([
        BorderZone.fire, BorderZone.fire, BorderZone.fire, // Firey Blast
        BorderZone.water, BorderZone.earth, BorderZone.earth,
        BorderZone.air, // residual
      ]);
      final views = incantationViewsFor(stored, IncantationLexicon.ordinary);
      expect(views.length, 2);
      expect(views[0].kind, EffectKind.damage);
      expect(views[0].affinity, SpellAffinity.fire);
      expect(views.map((v) => v.index), [0, 1]);
    });

    test('unrecognised names are dropped before segmenting', () {
      // Matching `DeterministicResolution.parsedFormulas` and the legacy
      // `formulaEffects` — and deliberately NOT matching
      // `spell_card_painter`'s heraldic histogram, which segments raw so an
      // unrecognised entry still occupies a slot. That difference is a
      // preserved Slice A quirk, not a bug to reconcile.
      final views = incantationViewsFor(
        const ['fire', 'sparkle', 'fire', 'fire'],
        IncantationLexicon.ordinary,
      );
      expect(views.length, 1);
      expect(views.single.kind, EffectKind.damage);
    });
  });

  // ── 2. Display semantic agreement ─────────────────────────────────────────

  group('display agrees with IncantationLexicon.meaningOf', () {
    test('a meaningful mutable formula displays its actual EffectKind', () {
      final lexicon = IncantationLexicon.of(_rivendell(4));
      final views = incantationViewsFor(
        _formulaNames(BorderZone.fire, _kL4MeaningfulTail),
        lexicon,
      );
      expect(views.single.kind, _kL4MeaningfulKind);
      expect(views.single.manifests, isTrue);
      // Named through the ordinary label tables — a leyline permutes which
      // tail selects which effect, never what an effect is called.
      expect(
        views.single.name,
        '${kAffinityLabel[SpellAffinity.fire]!} '
        '${kEffectKindLabel[_kL4MeaningfulKind]!}',
      );
    });

    test('a noise formula displays explicitly as noise', () {
      final lexicon = IncantationLexicon.of(_rivendell(4));
      final views = incantationViewsFor(
        _formulaNames(BorderZone.fire, _kL4NoiseTail),
        lexicon,
      );
      // Not blank, not an ordinary label, not a fake EffectKind.
      expect(views.single.manifests, isFalse);
      expect(views.single.kind, isNull);
      expect(views.single.meaning, isA<IncantationNoise>());
      expect(views.single.name, kIncantationNoiseLabel);
      expect(views.single.description, isNotEmpty);
    });

    test('the view never disagrees with the lexicon, at every length', () {
      // The core invariant, stated directly: for each length, walk formulas
      // and assert the DISPLAYED meaning is byte-identical to what the engine
      // seam would answer for the same chunk.
      for (final length in const [4, 5, 6]) {
        final lexicon = IncantationLexicon.of(_rivendell(length));
        for (final affinity in BorderZone.values) {
          for (final lead in BorderZone.values) {
            final tail = [
              lead,
              ...List.filled(length - 2, BorderZone.water),
            ];
            final views =
                incantationViewsFor(_formulaNames(affinity, tail), lexicon);
            expect(views.length, 1, reason: 'length $length');
            final expected = lexicon.meaningOf(
              ParsedFormula.withTail(affinity: affinity, tail: tail),
            );
            expect(views.single.meaning, expected,
                reason: 'length $length, affinity $affinity, lead $lead');
          }
        }
      }
    });

    test('the ordinary table is NOT consulted for a mutable formula', () {
      // The `UI says Glacier` failure mode. Stated over the whole length-4
      // key space rather than one key, because any single key can agree with
      // its ordinary prefix reading by coincidence — the codebook is a
      // permutation of the same sixteen effects, so some keys land back where
      // they started. What CANNOT happen if the display is really consulting
      // the codebook is that every key agrees.
      //
      // Two independent witnesses, either of which alone would be enough:
      // disagreements exist, and noise exists at all (the ordinary table is
      // total, so it can never produce noise).
      final lexicon = IncantationLexicon.of(_rivendell(4));
      var agreed = 0;
      var disagreed = 0;
      var noise = 0;
      for (final t0 in BorderZone.values) {
        for (final t1 in BorderZone.values) {
          for (final t2 in BorderZone.values) {
            final view = incantationViewsFor(
              _formulaNames(BorderZone.fire, [t0, t1, t2]),
              lexicon,
            ).single;
            if (!view.manifests) {
              noise++;
            } else if (view.kind == effectKindFromPair(t0, t1)) {
              agreed++;
            } else {
              disagreed++;
            }
          }
        }
      }
      expect(agreed + disagreed + noise, 64);
      expect(disagreed, greaterThan(0),
          reason: 'every length-4 key resolved to its own ordinary prefix '
              'reading — the display is falling back to effectKindFromPair '
              'instead of consulting the codebook');
      expect(noise, greaterThan(0),
          reason: 'no key read as noise, which the ordinary table cannot '
              'produce — the codebook is not being consulted at all');
    });
  });

  // ── 3. Structural ordering ────────────────────────────────────────────────

  group('structural correspondence', () {
    test('meaningful / noise / meaningful keeps all three positions', () {
      // The brief's ordering case. A display that filtered noise would return
      // two entries and silently renumber the third formula to position 2.
      final lexicon = IncantationLexicon.of(_rivendell(4));
      final stored = [
        ..._formulaNames(BorderZone.fire, _kL4MeaningfulTail),
        ..._formulaNames(BorderZone.water, _kL4NoiseTail),
        ..._formulaNames(BorderZone.earth, _kL4MeaningfulTail),
      ];
      final views = incantationViewsFor(stored, lexicon);

      expect(views.length, 3);
      expect(views.map((v) => v.index), [0, 1, 2]);
      expect(views.map((v) => v.manifests), [true, false, true]);
      expect(views[1].name, kIncantationNoiseLabel);
      expect(views[0].kind, _kL4MeaningfulKind);
      expect(views[2].kind, _kL4MeaningfulKind);
      // And the affinities stay with their own formulas, in order.
      expect(views.map((v) => v.affinity),
          [SpellAffinity.fire, SpellAffinity.water, SpellAffinity.earth]);
    });

    test('labels keep noise in place', () {
      final lexicon = IncantationLexicon.of(_rivendell(4));
      final labels = incantationLabelsFor([
        ..._formulaNames(BorderZone.fire, _kL4MeaningfulTail),
        ..._formulaNames(BorderZone.water, _kL4NoiseTail),
      ], lexicon);
      expect(labels.length, 2);
      expect(labels[1], kIncantationNoiseLabel);
    });
  });

  // ── 4. Affinity eligibility ───────────────────────────────────────────────

  group('affinity eligibility excludes noise', () {
    test('a meaningful formula contributes its affinity, noise does not', () {
      final lexicon = IncantationLexicon.of(_rivendell(4));
      final meaningful = incantationViewsFor(
        _formulaNames(BorderZone.fire, _kL4MeaningfulTail),
        lexicon,
      ).single;
      final noise = incantationViewsFor(
        _formulaNames(BorderZone.fire, _kL4NoiseTail),
        lexicon,
      ).single;

      // Same affinity element on both — the element really is in the
      // trajectory either way. What differs is whether it counts.
      expect(meaningful.affinity, SpellAffinity.fire);
      expect(noise.affinity, SpellAffinity.fire);
      expect(meaningful.manifests, isTrue);
      expect(noise.manifests, isFalse);

      // The eligibility predicate the engine uses agrees with the display's.
      expect(incantationContributesAffinity(meaningful.meaning), isTrue);
      expect(incantationContributesAffinity(noise.meaning), isFalse);
      expect(
        incantationContributesWildMagicEligibility(noise.meaning),
        isFalse,
      );
    });

    test('a mixed spell counts only its meaningful affinities', () {
      // The case that catches unconditional `chunk[0]` counting: three
      // formulas, three distinct affinities, one of them inert. A structural
      // histogram reports 1/1/1; the eligible tally must report 1/0/1.
      final lexicon = IncantationLexicon.of(_rivendell(4));
      final stored = [
        ..._formulaNames(BorderZone.fire, _kL4MeaningfulTail),
        ..._formulaNames(BorderZone.water, _kL4NoiseTail),
        ..._formulaNames(BorderZone.earth, _kL4MeaningfulTail),
      ];
      final views = incantationViewsFor(stored, lexicon);

      final structural = <SpellAffinity, int>{};
      final eligible = <SpellAffinity, int>{};
      for (final v in views) {
        structural[v.affinity] = (structural[v.affinity] ?? 0) + 1;
        if (v.manifests) eligible[v.affinity] = (eligible[v.affinity] ?? 0) + 1;
      }

      expect(structural, {
        SpellAffinity.fire: 1,
        SpellAffinity.water: 1,
        SpellAffinity.earth: 1,
      });
      expect(eligible, {SpellAffinity.fire: 1, SpellAffinity.earth: 1});
      expect(eligible.containsKey(SpellAffinity.water), isFalse,
          reason: 'the noise formula\'s Water affinity is structurally '
              'present but must never read as eligible');
    });
  });

  // ── 5. The structurally void spell ────────────────────────────────────────

  group('structurally void spells', () {
    test('a 3-element spell yields nothing at every mutable length', () {
      final stored = _stored(
        const [BorderZone.fire, BorderZone.water, BorderZone.earth],
      );
      // The same three elements ARE a complete formula ordinarily.
      expect(
        incantationViewsFor(stored, IncantationLexicon.ordinary).length,
        1,
      );
      for (final length in const [4, 5, 6]) {
        final views =
            incantationViewsFor(stored, IncantationLexicon.of(_rivendell(length)));
        expect(views, isEmpty, reason: 'length $length');
      }
    });

    test('void means no effect, no affinity, no fallback', () {
      // All four ratified consequences, from one call. The critical one is the
      // last: there is NO fallback to the ordinary triplet reading, so the
      // spell that would have been a Firey Blast is simply nothing.
      final lexicon = IncantationLexicon.of(_rivendell(5));
      final views = incantationViewsFor(
        _stored(const [BorderZone.fire, BorderZone.fire, BorderZone.fire]),
        lexicon,
      );
      expect(views, isEmpty);
      expect(views.where((v) => v.manifests), isEmpty);
      expect(views.map((v) => v.affinity), isEmpty);
      expect(incantationLabelsFor(
        _stored(const [BorderZone.fire, BorderZone.fire, BorderZone.fire]),
        lexicon,
      ), isEmpty);
    });

    test('a partially void spell keeps its complete prefix', () {
      // 9 elements at length 4 → two complete formulas and a 1-element
      // residual. The residual is discarded, not rounded up into a third.
      final lexicon = IncantationLexicon.of(_rivendell(4));
      final stored = [
        ..._formulaNames(BorderZone.fire, _kL4MeaningfulTail),
        ..._formulaNames(BorderZone.water, _kL4NoiseTail),
        'earth',
      ];
      expect(incantationViewsFor(stored, lexicon).length, 2);
    });
  });

  // ── 6. Formula lengths ────────────────────────────────────────────────────

  group('grouping follows the active grammar', () {
    test('twelve elements group by length, at 3/4/5/6', () {
      // 12 is divisible by 3, 4 and 6 but not 5 — so the length-5 row also
      // pins that the residual is dropped rather than padded.
      final twelve = _stored([
        for (var i = 0; i < 12; i++) BorderZone.values[i % 4],
      ]);
      expect(
        incantationViewsFor(twelve, IncantationLexicon.ordinary).length,
        4,
      );
      expect(
        incantationViewsFor(twelve, IncantationLexicon.of(_rivendell(4))).length,
        3,
      );
      expect(
        incantationViewsFor(twelve, IncantationLexicon.of(_rivendell(5))).length,
        2, // 10 elements inside formulas, 2 discarded
      );
      expect(
        incantationViewsFor(twelve, IncantationLexicon.of(_rivendell(6))).length,
        2,
      );
    });

    test('length 6 reads the corpus vectors', () {
      final lexicon = IncantationLexicon.of(_rivendell(6));
      expect(
        incantationViewsFor(
          _formulaNames(BorderZone.air, _kL6MeaningfulTail),
          lexicon,
        ).single.kind,
        _kL6MeaningfulKind,
      );
      expect(
        incantationViewsFor(
          _formulaNames(BorderZone.air, _kL6NoiseTail),
          lexicon,
        ).single.name,
        kIncantationNoiseLabel,
      );
    });

    test('length 5 reads the corpus vectors', () {
      final lexicon = IncantationLexicon.of(_rivendell(5));
      expect(
        incantationViewsFor(
          _formulaNames(BorderZone.earth, _kL5MeaningfulTail),
          lexicon,
        ).single.kind,
        _kL5MeaningfulKind,
      );
    });

    test('the same stored spell reads differently under different leylines',
        () {
      // The persisted-metadata ruling, from the display side: one stored
      // trajectory, three leylines, three different readings — and the stored
      // list itself is never touched. This is expected behaviour, not drift.
      final stored = [
        ..._formulaNames(BorderZone.fire, _kL4MeaningfulTail),
        ..._formulaNames(BorderZone.water, _kL4NoiseTail),
      ];
      final before = List<String>.from(stored);
      final ordinary = incantationViewsFor(stored, IncantationLexicon.ordinary);
      final mutable =
          incantationViewsFor(stored, IncantationLexicon.of(_rivendell(4)));

      expect(ordinary.length, 2); // 8 elements → two ordinary triplets + 2 res
      expect(mutable.length, 2);
      expect(ordinary.map((v) => v.manifests), everyElement(isTrue));
      expect(mutable[1].manifests, isFalse);
      expect(stored, before, reason: 'display must never mutate the asset');
    });
  });
}
