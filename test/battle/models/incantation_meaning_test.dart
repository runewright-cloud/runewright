// SPDX-License-Identifier: GPL-3.0-or-later
//
// incantation_meaning_test.dart — the Slice C semantic layer
// (docs/MUTABLE_LEYLINES_IMPLEMENTATION_AUDIT.md §6, §7.3).
//
// What these tests are for, in one line each:
//
//   1. ORDINARY INVARIANCE. `ordinaryIncantationMeaning` is exhaustively
//      `effectKindFromPair` over all sixteen tails, and is TOTAL — ordinary
//      play cannot produce noise. This is the test that says Slice C changed
//      no output, and it is the one that matters most.
//   2. REPRESENTATION. A meaningful formula carries exactly one EffectKind; a
//      noise formula is distinct from every one of the sixteen and from every
//      other reading. No nulls, no sentinel, no contradictory pair of fields.
//   3. STRUCTURE ≠ SEMANTICS. The count of complete structural formulas is
//      independent of how many of them mean anything. This is §7.3 — the
//      invariant that keeps `certifiedBaseManaCost`, the persisted
//      `SpellAsset.manaCost`, `behaviouralKinKey`, kin stacking and heraldic
//      identity leyline-independent.
//   4/5. ELIGIBILITY. Noise contributes no affinity and no Wild Magic
//      eligibility; a meaningful formula contributes both, by ordinary rules.
//
// Nothing here is wired into gameplay. The helpers are landed and tested now,
// while ordinary interpretation is total and noise is unreachable, so that
// Slice D is a wiring change rather than a semantics change.

import 'dart:io';

import 'package:test/test.dart';

import 'package:rune_duel/battle/models/effect_kind.dart';
import 'package:rune_duel/battle/models/incantation_meaning.dart';
import 'package:rune_duel/engine/border_zone.dart';
import 'package:rune_duel/engine/formula_segmentation.dart';

/// The four elements a formula element can be. Neutral is excluded: a neutral
/// or tied generation commits nothing (`FormulaTracker.step` guards all three
/// commit rules with `zone != null`), so it can never appear in a chunk.
const List<BorderZone> _elements = [
  BorderZone.fire,
  BorderZone.air,
  BorderZone.water,
  BorderZone.earth,
];

void main() {
  // ── 1. Ordinary interpretation == effectKindFromPair, exhaustively ────────

  group('ordinary interpretation', () {
    test('agrees with effectKindFromPair on all 16 tail pairs', () {
      var pairs = 0;
      for (final t1 in _elements) {
        for (final t2 in _elements) {
          pairs++;
          expect(
            ordinaryIncantationMeaning(t1, t2),
            IncantationEffect(effectKindFromPair(t1, t2)),
            reason: 'ordinary meaning of ($t1, $t2) must be the canonical '
                'effectKindFromPair result — this wrapper renames that table, '
                'it never replaces it',
          );
        }
      }
      expect(pairs, 16, reason: 'the ordinary tail space is 4^2');
    });

    test('is total: every one of the 16 effects is reachable, and exactly '
        'once', () {
      final seen = <EffectKind>{};
      for (final t1 in _elements) {
        for (final t2 in _elements) {
          expect(seen.add(ordinaryIncantationMeaning(t1, t2).kind), isTrue,
              reason: 'the ordinary table is a bijection over the 16 tails');
        }
      }
      expect(seen, EffectKind.values.toSet());
    });

    test('never produces noise — ordinary play cannot be inert', () {
      for (final t1 in _elements) {
        for (final t2 in _elements) {
          final meaning = ordinaryIncantationMeaning(t1, t2);
          // Statically an IncantationEffect, which is the point of the
          // narrowed return type; asserted dynamically too so the narrowing
          // cannot be widened without this failing.
          expect(meaning, isA<IncantationEffect>());
          expect(meaning, isNot(kIncantationNoise));
          expect(incantationManifestsEffect(meaning), isTrue);
        }
      }
    });

    test('does not depend on the affinity element', () {
      // Only the tail is a parameter (§3: a leyline may change what a tail
      // means, never what an affinity means). Nothing to vary — this test
      // documents the signature, and fails to compile if affinity is ever
      // added as a parameter with no default.
      expect(
        ordinaryIncantationMeaning(BorderZone.fire, BorderZone.fire).kind,
        EffectKind.damage,
      );
    });
  });

  // ── 2. The representation itself ──────────────────────────────────────────

  group('IncantationMeaning', () {
    test('a meaningful formula carries exactly one EffectKind', () {
      for (final kind in EffectKind.values) {
        final meaning = IncantationEffect(kind);
        expect(meaning.kind, kind);
        // Exhaustive switch: the analyzer requires the noise arm, which is the
        // whole reason this is a sealed hierarchy and not a nullable kind.
        final extracted = switch (meaning as IncantationMeaning) {
          IncantationEffect(kind: final k) => k,
          IncantationNoise() => null,
        };
        expect(extracted, kind);
      }
    });

    test('the sixteen effect meanings are mutually distinct', () {
      final all = [for (final k in EffectKind.values) IncantationEffect(k)];
      expect(all.toSet().length, 16);
      for (var i = 0; i < all.length; i++) {
        for (var j = 0; j < all.length; j++) {
          expect(all[i] == all[j], i == j,
              reason: 'IncantationEffect equality is exactly EffectKind '
                  'equality');
        }
      }
    });

    test('noise is distinct from every effect, and equal only to noise', () {
      for (final kind in EffectKind.values) {
        expect(kIncantationNoise == IncantationEffect(kind), isFalse);
        expect(IncantationEffect(kind) == kIncantationNoise, isFalse);
      }
      expect(kIncantationNoise, const IncantationNoise());
      expect(const IncantationNoise() == const IncantationNoise(), isTrue);
      // A const singleton, so equality and identity agree.
      expect(identical(kIncantationNoise, const IncantationNoise()), isTrue);
      final pair = <IncantationMeaning>[
        kIncantationNoise,
        const IncantationNoise(),
      ];
      expect(pair.toSet().length, 1,
          reason: 'noise must collapse in a Set — its hashCode is a constant');
    });

    test('noise carries no EffectKind at all — there is no fake kind to '
        'read', () {
      const IncantationMeaning meaning = kIncantationNoise;
      final extracted = switch (meaning) {
        IncantationEffect(kind: final k) => k,
        IncantationNoise() => null,
      };
      expect(extracted, isNull,
          reason: 'the null lives inside one exhaustive switch, never in the '
              'representation');
    });

    test('a meaning is one reading or the other, never both and never '
        'neither', () {
      final readings = <IncantationMeaning>[
        for (final k in EffectKind.values) IncantationEffect(k),
        kIncantationNoise,
      ];
      for (final meaning in readings) {
        final isEffect = meaning is IncantationEffect;
        final isNoise = meaning is IncantationNoise;
        expect(isEffect ^ isNoise, isTrue,
            reason: 'sealed hierarchy: exactly one variant, so no boolean can '
                'contradict an effect kind');
        expect(incantationManifestsEffect(meaning), isEffect);
      }
    });
  });

  // ── 3. Structural count ⟂ meaningful count (§7.3) ─────────────────────────

  group('structural count is independent of meaning', () {
    // Element streams chosen to cover: an exact multiple of the formula
    // length, a stream with a 1-element residual, one with a 2-element
    // residual, and one too short to form any formula at all.
    final streams = <String, List<BorderZone>>{
      'empty': const [],
      'one short of a formula': const [BorderZone.fire, BorderZone.air],
      'exactly one formula': const [
        BorderZone.fire, BorderZone.fire, BorderZone.fire,
      ],
      'two formulas + 1 residual': const [
        BorderZone.fire, BorderZone.air, BorderZone.water,
        BorderZone.earth, BorderZone.earth, BorderZone.earth,
        BorderZone.water,
      ],
      'three formulas + 2 residual': const [
        BorderZone.air, BorderZone.air, BorderZone.air,
        BorderZone.water, BorderZone.fire, BorderZone.earth,
        BorderZone.earth, BorderZone.air, BorderZone.fire,
        BorderZone.fire, BorderZone.water,
      ],
    };

    streams.forEach((label, elements) {
      test('$label: the structural count is the same whether every formula '
          'means something or nothing', () {
        final chunks =
            segmentFormulas(elements, formulaLength: kIncantationFormulaLength);
        final structural = chunks.length;

        // The structural count comes from segmentation alone and knows nothing
        // about meaning — it is the number pricing reads.
        expect(
          structural,
          completeFormulaCount(
            elements.length,
            formulaLength: kIncantationFormulaLength,
          ),
        );

        // Reading A: every chunk interpreted ordinarily. All meaningful.
        final ordinary = [
          for (final chunk in chunks)
            ordinaryIncantationMeaning(chunk[1], chunk[2]),
        ];
        expect(ordinary.length, structural);
        expect(meaningfulIncantationCount(ordinary), structural);

        // Reading B: a hypothetical leyline under which every chunk is noise.
        // Not reachable from gameplay — constructed by hand, which is the only
        // way noise exists today.
        final allNoise = [for (final _ in chunks) kIncantationNoise];
        expect(allNoise.length, structural,
            reason: 'noise still occupies its structural slot');
        expect(meaningfulIncantationCount(allNoise), 0);

        // Reading C: alternating. The structural count is unmoved.
        final mixed = <IncantationMeaning>[
          for (var i = 0; i < structural; i++)
            if (i.isEven)
              ordinaryIncantationMeaning(chunks[i][1], chunks[i][2])
            else
              kIncantationNoise,
        ];
        expect(mixed.length, structural);
        expect(meaningfulIncantationCount(mixed), (structural + 1) ~/ 2);

        // The invariant, stated directly: the number that prices a cast is
        // the length, and the length is the same in all three readings.
        expect(
          {ordinary.length, allNoise.length, mixed.length},
          {structural},
          reason: '§7.3: leylines change interpretation, not intrinsic '
              'certified cost — certifiedBaseManaCost, the persisted '
              'SpellAsset.manaCost, behaviouralKinKey, kin stacking and '
              'heraldic identity all read this count',
        );
      });
    });

    test("the certified effectCount expression reads the structural count, "
        'not the meaningful one', () {
      // `max(0, formulas.length - 1)` — PeerCastVerifier.certifiedBaseManaCost
      // and DeterministicResolution.wireBaseManaCost both spell it this way,
      // over a List<ParsedFormula> whose length is the structural chunk count.
      // Reproduced here on meanings to show the two counts diverging while the
      // priced one does not.
      const structural = 4;
      final allNoise = List<IncantationMeaning>.filled(
        structural,
        kIncantationNoise,
      );
      expect(allNoise.length - 1, 3, reason: 'the priced effectCount');
      expect(meaningfulIncantationCount(allNoise) - 1, -1,
          reason: 'what pricing would have been had it counted meaning — and '
              'the reason it must not');
    });
  });

  // ── 4/5. Eligibility helpers ──────────────────────────────────────────────

  group('affinity eligibility', () {
    test('a meaningful formula contributes its affinity', () {
      for (final kind in EffectKind.values) {
        expect(incantationContributesAffinity(IncantationEffect(kind)), isTrue);
      }
    });

    test('noise contributes no affinity', () {
      expect(incantationContributesAffinity(kIncantationNoise), isFalse);
    });

    test('every ordinary formula is affinity-eligible', () {
      for (final t1 in _elements) {
        for (final t2 in _elements) {
          expect(
            incantationContributesAffinity(ordinaryIncantationMeaning(t1, t2)),
            isTrue,
            reason: 'ordinary interpretation is total, so pureAffinityOf sees '
                'exactly the formulas it sees today',
          );
        }
      }
    });
  });

  group('wild magic eligibility', () {
    test('a meaningful formula is eligible by ordinary rules', () {
      for (final t1 in _elements) {
        for (final t2 in _elements) {
          expect(
            incantationContributesWildMagicEligibility(
              ordinaryIncantationMeaning(t1, t2),
            ),
            isTrue,
            reason: 'ordinary play has no noise, so WildMagic.eligibleElements '
                'tallies exactly the formulas it tallies today',
          );
        }
      }
      for (final kind in EffectKind.values) {
        expect(
          incantationContributesWildMagicEligibility(IncantationEffect(kind)),
          isTrue,
        );
      }
    });

    test('noise contributes no wild magic eligibility', () {
      expect(
        incantationContributesWildMagicEligibility(kIncantationNoise),
        isFalse,
      );
    });

    test('an all-noise spell would be wild-magic inert, like a zero-formula '
        'one', () {
      // WildMagic.eligibleElements returns {} for an empty formula list and
      // therefore fires nothing. A spell whose every formula is noise reduces
      // to the same case — with no special case, and without moving a single
      // byte of the semantic-hash preimage.
      final allNoise =
          List<IncantationMeaning>.filled(5, kIncantationNoise);
      expect(
        allNoise.where(incantationContributesWildMagicEligibility),
        isEmpty,
      );
      expect(meaningfulIncantationCount(allNoise), 0);
    });
  });

  // ── The three predicates ──────────────────────────────────────────────────

  group('the eligibility predicates', () {
    test('agree with one another on both readings, per §6', () {
      for (final meaning in <IncantationMeaning>[
        for (final k in EffectKind.values) IncantationEffect(k),
        kIncantationNoise,
      ]) {
        final effect = incantationManifestsEffect(meaning);
        expect(incantationContributesAffinity(meaning), effect);
        expect(incantationContributesWildMagicEligibility(meaning), effect);
      }
    });

    test('are named separately because §6 rules them separately', () {
      // If a later ruling splits them — say noise contributes affinity but no
      // effect — exactly one of these three lines changes, and this test is
      // where the reader is told so.
      expect(incantationManifestsEffect(kIncantationNoise), isFalse);
      expect(incantationContributesAffinity(kIncantationNoise), isFalse);
      expect(
        incantationContributesWildMagicEligibility(kIncantationNoise),
        isFalse,
      );
    });
  });

  // ── Interpretation-boundary posture, asserted against the source tree ────
  //
  // Slice C's version of this group asserted an absolute prohibition: nothing
  // in production imported the codebook, derived one, or read `mutableMagic`.
  // Slice D makes all three legitimate — but only in one place. So the guards
  // do not go away, they narrow: the question changes from "does anything do
  // this" to "does anything OUTSIDE the seam do this", which is the property
  // that actually has to hold from here on.
  //
  // The allowlists below are the architecture, written down. Adding a file to
  // one is a real decision — it means a second place in the codebase now knows
  // what a leyline does to a formula — and it should be made deliberately, in
  // review, not by editing a list to make a test pass.

  group('interpretation-boundary posture', () {
    final lib = _libDir();

    test('the source scan is not vacuous', () {
      // A guard test that silently stops guarding is worse than no guard. Two
      // things can rot here: the file walk (wrong directory, no .dart files)
      // and the import pattern (a formatter moves the quote style). Both are
      // checked against known-good inputs rather than assumed.
      final files = _dartFiles(lib).toList();
      expect(files.length, greaterThan(50),
          reason: 'the walk found ${files.length} dart files under '
              '${lib.path} — it is not looking at lib/');
      expect(
        files.map(_rel),
        contains('battle/models/incantation_meaning.dart'),
      );
      for (final sample in const [
        "import 'package:rune_duel/battle/models/leyline_codebook.dart';",
        'import "../models/leyline_codebook.dart";',
        "import 'leyline_codebook.dart' show IncantationCodebook;",
      ]) {
        expect(_kCodebookImport.hasMatch(sample), isTrue,
            reason: 'the import pattern must still match: $sample');
      }
      expect(
        _kCodebookImport.hasMatch("import 'leyline_config.dart';"),
        isFalse,
      );
    });

    test('only the lexicon imports the codebook', () {
      // The dependency boundary Slice C bought and Slice D spends exactly once.
      // Ordinary effect utilities, UI leaves and certification identity code
      // must not be able to SEE `IncantationCodebook`, let alone derive one.
      const allowed = {'battle/engine/incantation_lexicon.dart'};
      final importers = {
        for (final file in _dartFiles(lib))
          if (!file.path.endsWith('leyline_codebook.dart') &&
              _kCodebookImport.hasMatch(file.readAsStringSync()))
            _rel(file),
      };
      expect(importers, allowed);
    });

    test('only the lexicon derives a codebook', () {
      // Derivation is a match/config-boundary operation. Spreading it is how a
      // codebook ends up derived per formula lookup, per card repaint, or —
      // worst — twice from two different configs in one match.
      const allowed = {'battle/engine/incantation_lexicon.dart'};
      final callers = {
        for (final file in _dartFiles(lib))
          if (!file.path.endsWith('leyline_codebook.dart') &&
              _codeOf(file).contains('IncantationCodebook.derive('))
            _rel(file),
      };
      expect(callers, allowed);
    });

    test('only the lexicon branches on LeylineConfig.mutableMagic', () {
      // leyline_config.dart owns the field — its canonicality check, its
      // canonical byte layout, its display name and its JSON codec all read it
      // legitimately. leyline_codebook.dart reads it only to REFUSE an ordinary
      // config. The one BEHAVIOURAL reader is the lexicon's factory; every
      // other consumer asks the lexicon a question instead of asking the config
      // a boolean, which is what keeps "what does a leyline change" answerable
      // by reading one file.
      const owners = {'leyline_config.dart', 'leyline_codebook.dart'};
      const allowed = {'battle/engine/incantation_lexicon.dart'};
      final readers = {
        for (final file in _dartFiles(lib))
          if (!owners.contains(file.uri.pathSegments.last) &&
              _codeOf(file).contains('mutableMagic'))
            _rel(file),
      };
      expect(readers, allowed);
    });

    test('summon and armor code never touches the incantation lexicon', () {
      // Neither domain chunks; both do overlapping substring search over fixed
      // 4-element patterns, and their mapping is an unruled design problem
      // (audit §14 R-8). Slice E, and not before a ruling.
      const summonAndArmor = [
        'battle/models/creature_spec.dart',
        'battle/models/certified_armor.dart',
        'battle/models/armor_envelope.dart',
      ];
      for (final rel in summonAndArmor) {
        final file = File('${lib.path}/$rel');
        expect(file.existsSync(), isTrue, reason: '$rel moved or was renamed — '
            'this guard is now scanning nothing');
        final src = _codeOf(file);
        for (final forbidden in const [
          'IncantationLexicon',
          'IncantationCodebook',
          'mutableMagic',
        ]) {
          expect(src.contains(forbidden), isFalse,
              reason: '$rel must not know about $forbidden');
        }
      }
    });

    test('every in-match trajectory parse passes a formula length', () {
      // `TrajectoryParser.parse` defaults to the ordinary length so the whole
      // existing corpus keeps saying what it means by saying nothing. That
      // default is a hazard for exactly one kind of caller: one that runs
      // inside a match and forgets. There are only two production callers, and
      // this pins which is which.
      const inMatch = 'battle/engine/peer_cast_verifier.dart';
      const outOfMatch = 'spells/spell_asset_integrity.dart';

      final callers = {
        for (final file in _dartFiles(lib))
          if (file.readAsStringSync().contains('TrajectoryParser.parse('))
            _rel(file),
      };
      expect(callers, {inMatch, outOfMatch},
          reason: 'a new TrajectoryParser.parse caller must decide, in review, '
              'whether it is in-match (pass lexicon.formulaLength) or is '
              'about persisted ordinary metadata (take the default)');

      // The in-match one passes a length…
      expect(
        File('${lib.path}/$inMatch')
            .readAsStringSync()
            .contains('formulaLength: lexicon.formulaLength'),
        isTrue,
        reason: 'certification must chunk at the ACTIVE leyline\'s grammar',
      );
      // …and the asset-integrity one deliberately does not: it recomputes the
      // metadata persisted at inscribe time, which is ordinary by definition
      // and must stay leyline-independent (§7.4).
      expect(
        File('${lib.path}/$outOfMatch')
            .readAsStringSync()
            .contains('formulaLength:'),
        isFalse,
        reason: 'persisted spell metadata is leyline-independent — giving this '
            'a leyline would make SpellAsset.manaCost, and through it '
            'behaviouralKinKey and heraldry, depend on where it was cast',
      );
    });
  });
}

/// [file]'s source with `//` comments stripped.
///
/// The scans below look for identifiers, and prose about an identifier is not a
/// use of it — `battle_engine_version.dart`'s history entry names `mutableMagic`
/// in a sentence, and a guard that counted that would push every writer toward
/// documenting the architecture less. Crude on purpose: a `//` inside a string
/// literal is truncated too, which costs nothing here and keeps the helper
/// something you can verify by reading it.
String _codeOf(File file) => file
    .readAsLinesSync()
    .map((line) {
      final i = line.indexOf('//');
      return i < 0 ? line : line.substring(0, i);
    })
    .join('\n');

/// An `import` of the Slice B codebook, in either quote style and by any
/// path. Deliberately not an `export`: `leyline_codebook.dart` re-exports the
/// meaning types, and that line lives in the excluded file itself.
final RegExp _kCodebookImport =
    RegExp(r'''import\s+['"][^'"]*leyline_codebook\.dart''');

/// The package's `lib/` directory, found by walking up from the test runner's
/// working directory to the nearest `pubspec.yaml` — so this works whether the
/// suite is run from the package root or from a subdirectory.
Directory _libDir() {
  var dir = Directory.current;
  while (!File('${dir.path}/pubspec.yaml').existsSync()) {
    final parent = dir.parent;
    if (parent.path == dir.path) {
      fail('could not locate pubspec.yaml above ${Directory.current.path}');
    }
    dir = parent;
  }
  final lib = Directory('${dir.path}/lib');
  if (!lib.existsSync()) fail('no lib/ beside ${dir.path}/pubspec.yaml');
  return lib;
}

Iterable<File> _dartFiles(Directory dir) => dir
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart'));

String _rel(File file) => file.path.split('/lib/').last;
