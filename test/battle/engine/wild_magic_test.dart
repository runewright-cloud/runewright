// SPDX-License-Identifier: GPL-3.0-or-later
//
// wild_magic_test.dart — the load-bearing tests for the wild-magic derivation
// (docs/WILD_MAGIC_PLAN.md §12).
//
// The seed-hash vectors here are the CROSS-CLIENT CONTRACT. Both devices must
// derive byte-identical hashes or the per-turn state hash diverges and the
// match aborts. A refactor that changes any pinned literal below is a BREAKING
// PROTOCOL CHANGE, not a test that needs updating — if one of these fails,
// the change is wrong until proven otherwise.

import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:rune_duel/battle/engine/proof_intake.dart';
import 'package:rune_duel/battle/engine/trajectory_parser.dart';
import 'package:rune_duel/battle/engine/wild_magic.dart';
import 'package:rune_duel/battle/models/effect_kind.dart' show SpellAffinity;
import 'package:rune_duel/battle/models/wild_magic_effect.dart';
import 'package:rune_duel/engine/border_zone.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

String _hex(List<int> bytes) =>
    '0x${bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';

final String _zeroCommitment = _hex(List.filled(32, 0));
final String _patternCommitment = _hex(List.generate(32, (i) => i + 1));

VerifiedSpellOutputs _outputs({
  required String commitmentHex,
  required int t,
  int tierMax = 12,
  List<int>? borderActivations,
  List<int>? trajectory,
  List<int>? supremeFlags,
  int segmentCount = 0,
  int dotCount = 0,
}) =>
    VerifiedSpellOutputs(
      proofBytes: Uint8List(0),
      t: t,
      ownerPubkeyHex: _zeroCommitment,
      rulesetVersion: 3,
      commitmentHex: commitmentHex,
      tierMax: tierMax,
      borderActivations: borderActivations ?? const [0, 0, 0, 0],
      dominanceTrajectory: trajectory ?? List.filled(tierMax, 0),
      supremeDominanceFlags: supremeFlags ?? List.filled(tierMax, 0),
      segmentCount: segmentCount,
      dotCount: dotCount,
    );

ParsedFormula _formula(BorderZone affinity) => ParsedFormula(
      affinity: affinity,
      effectType1: BorderZone.fire,
      effectType2: BorderZone.fire,
    );

/// A 64-char hex string that starts with [prefix] and is padded with a
/// character that can never extend a run or an ascending sequence out of it.
String _hash64(String prefix, {String pad = '7'}) {
  assert(prefix.length <= 64);
  return prefix + pad * (64 - prefix.length);
}

void main() {
  // ── §4.1 — the seed hash, pinned ────────────────────────────────────────

  group('WildMagic.seedHex — fixed vectors (CROSS-CLIENT CONTRACT)', () {
    test('zero commitment, T=1, universal', () {
      expect(
        WildMagic.seedHex(
          _outputs(commitmentHex: _zeroCommitment, t: 1),
          'universal',
        ),
        '83cdb5dc659e9d81f71576b0b98748a3641d2dcc9d2521cf06442a96fe6b31df',
      );
    });

    test('zero commitment, T=2, universal — T alone changes the hash', () {
      expect(
        WildMagic.seedHex(
          _outputs(commitmentHex: _zeroCommitment, t: 2),
          'universal',
        ),
        '4be39be4a71d1cb7ca4bbecaa4847121700968986fa253aed66fe14cb93674ea',
      );
    });

    test('pattern commitment, T=12, rivendell', () {
      expect(
        WildMagic.seedHex(
          _outputs(commitmentHex: _patternCommitment, t: 12),
          'rivendell',
        ),
        'd1436ae7dc016e6e08feb73a1e1a47c8297a9133bfab78fda818f115b86b09f2',
      );
    });

    test('pattern commitment, T=12, universal — seed alone changes the hash', () {
      expect(
        WildMagic.seedHex(
          _outputs(commitmentHex: _patternCommitment, t: 12),
          'universal',
        ),
        '5267314d8b6b69dae28fb33350aa3d91cebf0b41e6672639ff4d41038474360a',
      );
    });

    test('output is 64 lowercase hex chars with no 0x prefix', () {
      final h = WildMagic.seedHex(
        _outputs(commitmentHex: _patternCommitment, t: 7),
        'anything',
      );
      expect(h.length, 64);
      expect(h, matches(RegExp(r'^[0-9a-f]{64}$')));
    });
  });

  // ── §4.1's simplification, guarded ──────────────────────────────────────

  group('WildMagic.seedHex — preimage independence', () {
    // This is the regression test for the [SIMPLIFIED — 2026-07-30] decision:
    // border activations and the dominance trajectory were dropped from the
    // preimage because they are deterministic functions of (grid, T) and add
    // no distinguishing power. It must be structurally impossible for a future
    // edit to quietly start reading them back in.
    test('borderActivations / trajectory / flags / geometry do not affect it', () {
      final plain = _outputs(commitmentHex: _patternCommitment, t: 9);
      final loud = _outputs(
        commitmentHex: _patternCommitment,
        t: 9,
        borderActivations: const [17, 3, 99, 42],
        trajectory: [for (var i = 0; i < 12; i++) (i % 5)],
        supremeFlags: [for (var i = 0; i < 12; i++) i.isEven ? 1 : 0],
        segmentCount: 31,
        dotCount: 7,
      );
      expect(
        WildMagic.seedHex(loud, 'universal'),
        WildMagic.seedHex(plain, 'universal'),
      );
    });

    test('tier-independent: the same spell at tier 24 and 48 hashes alike', () {
      final t24 = _outputs(commitmentHex: _patternCommitment, t: 9, tierMax: 24);
      final t48 = _outputs(commitmentHex: _patternCommitment, t: 9, tierMax: 48);
      expect(
        WildMagic.seedHex(t24, 'universal'),
        WildMagic.seedHex(t48, 'universal'),
      );
    });

    test('deterministic across repeated calls', () {
      final o = _outputs(commitmentHex: _patternCommitment, t: 5);
      final first = WildMagic.seedHex(o, 'rivendell');
      for (var i = 0; i < 100; i++) {
        expect(WildMagic.seedHex(o, 'rivendell'), first);
      }
    });
  });

  // ── Seed normalization ──────────────────────────────────────────────────

  group('WildMagic.normalizeCommunitySeed', () {
    final o = _outputs(commitmentHex: _patternCommitment, t: 4);

    test('case, whitespace and punctuation are stripped', () {
      final canonical = WildMagic.seedHex(o, 'rivendell');
      for (final variant in ['Rivendell!', ' RIVENDELL ', 'ri-ven_dell', 'Rivendell.']) {
        expect(WildMagic.seedHex(o, variant), canonical, reason: variant);
      }
    });

    test('seeds that normalize to empty fall back to universal', () {
      final universal = WildMagic.seedHex(o, 'universal');
      for (final variant in ['', '---', '   ', '日本', '!!!']) {
        expect(WildMagic.seedHex(o, variant), universal, reason: '"$variant"');
      }
    });

    test('a real seed is NOT the universal hash', () {
      expect(
        WildMagic.seedHex(o, 'rivendell'),
        isNot(WildMagic.seedHex(o, 'universal')),
      );
    });

    test('normalizeCommunitySeed itself', () {
      expect(WildMagic.normalizeCommunitySeed('Rivendell!'), 'rivendell');
      expect(WildMagic.normalizeCommunitySeed('  Deep Roads 7 '), 'deeproads7');
      expect(WildMagic.normalizeCommunitySeed('---'), kDefaultCommunitySeed);
    });
  });

  // ── §4.2 — the scan ─────────────────────────────────────────────────────

  group('WildMagic.scan — row 1 / row 2 repeat runs', () {
    test('a run of exactly 3 zeros fires row 1 at bracket 0', () {
      expect(WildMagic.scan(_hash64('a000b')), [
        (WildMagicRow.repeatZero, 0),
      ]);
    });

    test('a run of 2 does not fire', () {
      expect(WildMagic.scan(_hash64('a00b')), isEmpty);
    });

    test('a run of 4 is ONE run of 4, not two overlapping runs of 3', () {
      expect(WildMagic.scan(_hash64('a0000b')), [
        (WildMagicRow.repeatZero, 1),
      ]);
    });

    test('a run at the very start fires', () {
      expect(WildMagic.scan(_hash64('000b')), [(WildMagicRow.repeatZero, 0)]);
    });

    test('a run at the very end fires', () {
      expect(
        WildMagic.scan('${'7' * 61}000'),
        [(WildMagicRow.repeatZero, 0)],
      );
    });

    test('ones fire row 2', () {
      expect(WildMagic.scan(_hash64('a111b')), [(WildMagicRow.repeatOne, 0)]);
    });

    test('overlapping 0001111 fires BOTH rows, with their own brackets', () {
      expect(WildMagic.scan(_hash64('a0001111b')), [
        (WildMagicRow.repeatZero, 0),
        (WildMagicRow.repeatOne, 1),
      ]);
    });

    test('two separate zero runs fire once, taking the LONGER bracket (A3)', () {
      // 000 … 00000 → one trigger, bracket 2 (from the run of 5).
      expect(WildMagic.scan(_hash64('000b7700000b')), [
        (WildMagicRow.repeatZero, 2),
      ]);
    });
  });

  group('WildMagic.scan — row 3 ascending runs', () {
    test('0123 fires at bracket 0', () {
      expect(WildMagic.scan(_hash64('a0123b')), [
        (WildMagicRow.ascendingRun, 0),
      ]);
    });

    test('def012 does NOT fire — the maximal run starts at d, not 0', () {
      // THE case that separates maximal-run semantics from a naive substring
      // search, and the single easiest way to get row 3 wrong.
      expect(WildMagic.scan(_hash64('def012b')), isEmpty);
    });

    test('4567 does not fire — an ascending run must begin at 0', () {
      expect(WildMagic.scan(_hash64('a4567b')), isEmpty);
    });

    test('012 does not fire — below the length-4 minimum', () {
      expect(WildMagic.scan(_hash64('a012b')), isEmpty);
    });

    test('the full wrap 0123456789abcdef0 fires with a long bracket', () {
      final h = _hash64('0123456789abcdef0');
      final scanned = WildMagic.scan(h);
      expect(scanned.length, 1);
      expect(scanned.first.$1, WildMagicRow.ascendingRun);
      expect(scanned.first.$2, 17 - 4); // run of 17, minimum 4
    });

    test('01234 fires at bracket 1', () {
      expect(WildMagic.scan(_hash64('a01234b')), [
        (WildMagicRow.ascendingRun, 1),
      ]);
    });

    test('all three rows can fire from one hash, in row order', () {
      final scanned = WildMagic.scan(_hash64('000b111b0123'));
      expect(scanned.map((e) => e.$1).toList(), [
        WildMagicRow.repeatZero,
        WildMagicRow.repeatOne,
        WildMagicRow.ascendingRun,
      ]);
    });
  });

  // ── §4.3 — eligibility ──────────────────────────────────────────────────

  group('WildMagic.eligibleElements', () {
    test('a single formula makes its own element eligible', () {
      expect(
        WildMagic.eligibleElements([_formula(BorderZone.fire)]),
        {SpellAffinity.fire},
      );
    });

    test('2 fire + 1 earth → fire only', () {
      expect(
        WildMagic.eligibleElements([
          _formula(BorderZone.fire),
          _formula(BorderZone.earth),
          _formula(BorderZone.fire),
        ]),
        {SpellAffinity.fire},
      );
    });

    test('a tie makes EVERY tied element eligible', () {
      expect(
        WildMagic.eligibleElements([
          _formula(BorderZone.fire),
          _formula(BorderZone.water),
        ]),
        {SpellAffinity.fire, SpellAffinity.water},
      );
    });

    test('a four-way tie makes all four eligible', () {
      expect(
        WildMagic.eligibleElements([
          _formula(BorderZone.air),
          _formula(BorderZone.water),
          _formula(BorderZone.earth),
          _formula(BorderZone.fire),
        ]),
        {
          SpellAffinity.fire,
          SpellAffinity.earth,
          SpellAffinity.water,
          SpellAffinity.air,
        },
      );
    });

    test('zero formulas (a void spell) yields nothing eligible', () {
      expect(WildMagic.eligibleElements(const []), isEmpty);
    });

    test('iteration order is SpellAffinity.values, not formula order', () {
      // Built from formulas in air, water, earth, fire order — the result must
      // still iterate fire, earth, water, air. Unordered iteration here is a
      // lockstep landmine (§4.3).
      final eligible = WildMagic.eligibleElements([
        _formula(BorderZone.air),
        _formula(BorderZone.water),
        _formula(BorderZone.earth),
        _formula(BorderZone.fire),
      ]);
      expect(eligible.toList(), SpellAffinity.values);
    });
  });

  // ── Full derivation ─────────────────────────────────────────────────────

  group('WildMagic.triggersFor', () {
    // 'seed70' was chosen so the pattern commitment at T=12 hashes to
    // 9f57daf884795709e000fff65e6232507472e07edb900cd26f248babae4f9c2e —
    // one run of exactly three '0's, no other trigger. Regenerating this
    // fixture means recomputing the hash; it is not arbitrary.
    final o = _outputs(commitmentHex: _patternCommitment, t: 12);

    test('the fixture hash is what we think it is', () {
      expect(
        WildMagic.seedHex(o, 'seed70'),
        '9f57daf884795709e000fff65e6232507472e07edb900cd26f248babae4f9c2e',
      );
    });

    test('a pure-fire spell fires only the Fire column of the matching row', () {
      final triggers =
          WildMagic.triggersFor(o, [_formula(BorderZone.fire)], 'seed70');
      expect(triggers.length, 1);
      expect(triggers.single.row, WildMagicRow.repeatZero);
      expect(triggers.single.element, SpellAffinity.fire);
      expect(triggers.single.bracketSteps, 0);
      expect(triggers.single.effect, WildMagicEffectKind.burningHot);
    });

    test('a four-way-balanced spell fires ALL FOUR of the row, in enum order', () {
      final triggers = WildMagic.triggersFor(
        o,
        [
          _formula(BorderZone.air),
          _formula(BorderZone.water),
          _formula(BorderZone.earth),
          _formula(BorderZone.fire),
        ],
        'seed70',
      );
      expect(triggers.map((t) => t.effect).toList(), [
        WildMagicEffectKind.burningHot, // fire
        WildMagicEffectKind.mountains, // earth
        WildMagicEffectKind.manaFlood, // water
        WildMagicEffectKind.zephyr, // air
      ]);
    });

    test('a zero-formula (void) spell fires nothing, whatever the hash', () {
      expect(WildMagic.triggersFor(o, const [], 'seed70'), isEmpty);
    });

    test('a hash with no pattern fires nothing', () {
      expect(
        WildMagic.triggersFor(o, [_formula(BorderZone.fire)], 'quiet0'),
        isEmpty,
      );
    });

    test('bracket steps come through: seed1338 gives a run of 4', () {
      expect(
        WildMagic.seedHex(o, 'seed1338'),
        'de70000bc353426eb0c286256c5125a97fb958d43aa06e498398d7bae6914dcb',
      );
      final triggers =
          WildMagic.triggersFor(o, [_formula(BorderZone.fire)], 'seed1338');
      expect(triggers.single.bracketSteps, 1);
    });

    test('the same grid at a different T is an independent roll', () {
      final t11 = _outputs(commitmentHex: _patternCommitment, t: 11);
      expect(
        WildMagic.seedHex(t11, 'seed70'),
        isNot(WildMagic.seedHex(o, 'seed70')),
      );
    });

    test('100 calls return identical results', () {
      final first =
          WildMagic.triggersFor(o, [_formula(BorderZone.fire)], 'seed70');
      for (var i = 0; i < 100; i++) {
        expect(
          WildMagic.triggersFor(o, [_formula(BorderZone.fire)], 'seed70'),
          first,
        );
      }
    });
  });

  // ── The effects table ───────────────────────────────────────────────────

  group('wildMagicEffectFor', () {
    test('every (row, element) pair maps to a distinct effect', () {
      final seen = <WildMagicEffectKind>{};
      for (final row in WildMagicRow.values) {
        for (final element in SpellAffinity.values) {
          expect(seen.add(wildMagicEffectFor(row, element)), isTrue);
        }
      }
      expect(seen.length, WildMagicEffectKind.values.length);
    });

    test('every effect has a label and a description', () {
      for (final e in WildMagicEffectKind.values) {
        expect(kWildMagicEffectLabel[e], isNotNull, reason: e.name);
        expect(kWildMagicEffectDescription[e], isNotNull, reason: e.name);
      }
    });
  });
}
