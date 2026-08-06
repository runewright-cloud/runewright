// SPDX-License-Identifier: GPL-3.0-or-later
//
// counter_charm_test.dart — the trajectory charm's pure rules
// (docs/COUNTER_CHARM_KINSHIP_PLAN.md §2.2, §2.3, §3.2).
//
// These run in the library UI (authoring a charm) and inside the deterministic
// turn resolution (firing one), on both devices, so the properties that matter
// most here are the boundaries: the 3-element trigger threshold, whole-formula
// cancellation, and stopping at the first divergence.

import 'package:test/test.dart';
import 'package:rune_duel/engine/border_zone.dart';
import 'package:rune_duel/spells/counter_charm.dart';

const _fff = [BorderZone.fire, BorderZone.fire, BorderZone.fire];
const _www = [BorderZone.water, BorderZone.water, BorderZone.water];
const _eee = [BorderZone.earth, BorderZone.earth, BorderZone.earth];

void main() {
  group('isValidCharmTrajectory', () {
    test('accepts whole numbers of formulas up to the entry cap', () {
      expect(isValidCharmTrajectory(_fff), isTrue);
      expect(isValidCharmTrajectory(const [..._fff, ..._www]), isTrue);
      expect(
        isValidCharmTrajectory(const [..._fff, ..._www, ..._eee, ..._fff]),
        isTrue,
      );
    });

    test('rejects empty, partial, and over-cap trajectories', () {
      expect(isValidCharmTrajectory(const []), isFalse);
      expect(
        isValidCharmTrajectory(const [BorderZone.fire, BorderZone.fire]),
        isFalse,
      );
      expect(
        isValidCharmTrajectory(const [..._fff, BorderZone.water]),
        isFalse,
      );
      expect(
        isValidCharmTrajectory(
          const [..._fff, ..._www, ..._eee, ..._fff, ..._www],
        ),
        isFalse,
      );
    });
  });

  group('counterCharmManaCost — triangular in formulas (§3.2)', () {
    test('matches the plan\'s table for k = 10', () {
      expect(kCounterCharmCostPerFormula, 10);
      expect(counterCharmManaCost(_fff), 10);
      expect(counterCharmManaCost(const [..._fff, ..._www]), 30);
      expect(counterCharmManaCost(const [..._fff, ..._www, ..._eee]), 60);
      expect(
        counterCharmManaCost(const [..._fff, ..._www, ..._eee, ..._fff]),
        100,
      );
    });

    test('is superlinear — which is what stops long charms from being '
        'strictly correct', () {
      final one = counterCharmManaCost(_fff);
      final two = counterCharmManaCost(const [..._fff, ..._www]);
      final three = counterCharmManaCost(const [..._fff, ..._www, ..._eee]);
      expect(two - one, greaterThan(one));
      expect(three - two, greaterThan(two - one));
    });
  });

  group('counterCharmFormulaMatch', () {
    test('three agreeing elements is exactly one formula — the trigger '
        'threshold (§2.2)', () {
      expect(counterCharmFormulaMatch(_fff, _fff), 1);
    });

    test('fewer than three agreeing elements does not trigger', () {
      expect(
        counterCharmFormulaMatch(
          _fff,
          const [BorderZone.fire, BorderZone.fire, BorderZone.water],
        ),
        0,
      );
      expect(counterCharmFormulaMatch(_fff, const [BorderZone.fire]), 0);
      expect(counterCharmFormulaMatch(_fff, const []), 0);
    });

    test('continues in lockstep and stops at the first divergence (§2.3)', () {
      const charm = [..._fff, ..._www, ..._eee];
      // Agrees for two formulas, then diverges on the seventh element.
      const spell = [..._fff, ..._www, BorderZone.fire, BorderZone.fire,
          BorderZone.fire];
      expect(counterCharmFormulaMatch(charm, spell), 2);
    });

    test('a partly-agreeing formula cancels nothing extra — whole formulas '
        'only', () {
      const charm = [..._fff, ..._www];
      // Five elements agree; the sixth does not.
      const spell = [
        ..._fff,
        BorderZone.water,
        BorderZone.water,
        BorderZone.earth,
      ];
      expect(counterCharmFormulaMatch(charm, spell), 1);
    });

    test('a charm longer than the spell cancels only what the spell has', () {
      const charm = [..._fff, ..._www, ..._eee];
      expect(counterCharmFormulaMatch(charm, _fff), 1);
    });

    test('a spell longer than the charm is capped by the charm', () {
      expect(
        counterCharmFormulaMatch(_fff, const [..._fff, ..._fff, ..._fff]),
        1,
      );
    });

    test('divergence in the very first element cancels nothing', () {
      expect(counterCharmFormulaMatch(_fff, _www), 0);
    });
  });

  group('names round-trip', () {
    test('toNames/fromNames is the identity on a valid trajectory', () {
      const t = [..._fff, ..._www];
      expect(charmTrajectoryFromNames(charmTrajectoryToNames(t)), t);
    });

    test('unknown names are dropped rather than throwing', () {
      expect(
        charmTrajectoryFromNames(const ['fire', 'neutral', 'air']),
        const [BorderZone.fire, BorderZone.air],
      );
    });

    test('borderZoneFromName is case-insensitive and rejects neutral', () {
      expect(borderZoneFromName('FIRE'), BorderZone.fire);
      expect(borderZoneFromName('Earth'), BorderZone.earth);
      expect(borderZoneFromName('neutral'), isNull);
      expect(borderZoneFromName(''), isNull);
    });
  });

  group('charmTrajectoryLabel', () {
    test('groups by formula', () {
      expect(charmTrajectoryLabel(_fff), 'Fire·Fire·Fire');
      expect(
        charmTrajectoryLabel(const [..._fff, ..._www]),
        'Fire·Fire·Fire / Water·Water·Water',
      );
    });
  });
}
