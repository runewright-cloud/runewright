// SPDX-License-Identifier: GPL-3.0-or-later
//
// dominance_test.dart — unit tests for ca_run.dart's advanceDominance:
// A1 (supreme-gated dispatch), A2 (tie-aware decay), A3 (tie reporting).
//
// These construct HexGrids with hand-set zoneActivations/stepCount and
// call advanceDominance directly, rather than growing a real seed through
// CAStep.step -- the decay/dominance/supreme math is what's under test
// here, not CA growth geometry (that's covered by stepper_test.dart and
// ink_step_test.dart), so going straight to the pressure table keeps each
// scenario exact and free of "did I grow the right shape" risk. The radius
// passed to HexGrid is arbitrary -- these tests never touch .cells.

import 'package:test/test.dart';
import 'package:rune_duel/engine/border_zone.dart';
import 'package:rune_duel/engine/ca_rules.dart';
import 'package:rune_duel/engine/ca_run.dart';
import 'package:rune_duel/engine/hex_grid.dart';

void main() {
  group('A2: decay equivalence and tie split', () {
    test('no tie: the unique leader decays by the full D (k=1 ⇒ dec=D) -- matches pre-A2 behavior', () {
      final grid = HexGrid(4);
      grid.stepCount = 5; // D = 5~/2 = 2
      grid.zoneActivations[BorderZone.fire] = 10;
      grid.zoneActivations[BorderZone.water] = 3;

      // Old behavior for this exact scenario: _decayActiveZone only
      // touched activeZoneFor(currentRule); with fire as the unique
      // leader (and thus the only plausible currentRule for this
      // pressure table), it decayed by the full D=2: 10 -> 8. New
      // behavior: decay every zone at maxP (here uniquely fire) by
      // ceil(D/k) = ceil(2/1) = 2 -- identical for k=1.
      final result = advanceDominance(CARules.fire, grid);

      expect(grid.zoneActivations[BorderZone.fire], equals(8));
      expect(grid.zoneActivations[BorderZone.water], equals(3), reason: 'non-leader untouched');
      expect(result.dominant, equals(CARules.fire));
    });

    test('maxP == 0: no decay', () {
      final grid = HexGrid(4);
      grid.stepCount = 9;
      grid.zoneActivations[BorderZone.fire] = 0;

      advanceDominance(CARules.neutral, grid);

      expect(grid.zoneActivations[BorderZone.fire], equals(0));
    });

    test('2-way tie: both zones at max pressure decay by ceil(D/2)', () {
      final grid = HexGrid(4);
      grid.stepCount = 9; // D = 9~/2 = 4
      grid.zoneActivations[BorderZone.fire] = 10;
      grid.zoneActivations[BorderZone.water] = 10;
      grid.zoneActivations[BorderZone.earth] = 3;

      final result = advanceDominance(CARules.neutral, grid);

      // dec = ceil(4/2) = 2
      expect(grid.zoneActivations[BorderZone.fire], equals(8));
      expect(grid.zoneActivations[BorderZone.water], equals(8));
      expect(grid.zoneActivations[BorderZone.earth], equals(3), reason: 'not at max, untouched');
      expect(result.dominant, equals(CARules.neutral), reason: 'A3: a tie reports no dominant');
      expect(result.isSupreme, isFalse);
      expect(result.rule, equals(CARules.neutral), reason: 'A1: not supreme -> neutral dispatch');
    });

    test('3-way tie: each tied zone decays by ceil(D/3), exercising the ceiling rounding', () {
      final grid = HexGrid(4);
      grid.stepCount = 11; // D = 11~/2 = 5
      grid.zoneActivations[BorderZone.fire] = 10;
      grid.zoneActivations[BorderZone.air] = 10;
      grid.zoneActivations[BorderZone.water] = 10;

      final result = advanceDominance(CARules.neutral, grid);

      // dec = ceil(5/3) = 2 (5/3 = 1.67 -> 2), NOT floor(5/3) = 1 --
      // pins the ceiling behavior specifically.
      expect(grid.zoneActivations[BorderZone.fire], equals(8));
      expect(grid.zoneActivations[BorderZone.air], equals(8));
      expect(grid.zoneActivations[BorderZone.water], equals(8));
      expect(result.dominant, equals(CARules.neutral));
      expect(result.isSupreme, isFalse);
    });
  });

  group('A1: supreme-gated dispatch', () {
    test('supreme: dispatch returns the elemental rule, matching isSupreme', () {
      final grid = HexGrid(4);
      grid.stepCount = 1; // D = 0, no decay yet
      grid.zoneActivations[BorderZone.fire] = 5; // sole zone with any pressure

      final result = advanceDominance(CARules.neutral, grid);

      expect(result.dominant, equals(CARules.fire));
      expect(result.isSupreme, isTrue, reason: '5*2=10 > total(5)');
      expect(result.rule, equals(CARules.fire), reason: 'supreme -> dispatch the elemental rule');
    });

    test('leading but never supreme: trajectory reports the leader, dispatch stays neutral', () {
      final grid = HexGrid(4);
      grid.stepCount = 1; // D = 0
      grid.zoneActivations[BorderZone.fire] = 5;
      grid.zoneActivations[BorderZone.water] = 4;
      grid.zoneActivations[BorderZone.air] = 2;
      // total = 11, pDom = 5, 5*2=10 <= 11 -> not supreme. Needs >= 3
      // zones holding pressure: with exactly 2, any unique leader is
      // always supreme (2A > A+B reduces to A > B), so this scenario is
      // only constructible with a third zone diluting the total.

      final result = advanceDominance(CARules.neutral, grid);

      expect(result.dominant, equals(CARules.fire), reason: 'fire is the unique leader');
      expect(result.isSupreme, isFalse);
      expect(result.rule, equals(CARules.neutral),
          reason: 'A1: dispatch is gated to neutral even though fire is the reported dominant');
    });
  });

  group('A3: tie reporting', () {
    test('a tie is never supreme (mathematical invariant, not just this implementation)', () {
      // Any k>=2 zones tied at maxP means maxP <= total/2 (k*maxP <= total
      // when k>=2 zones each hold maxP), so isSupreme(rule, grid) must be
      // false for a tied rule even if checked directly, independent of
      // whatever _nextRule reports for the tie.
      final grid = HexGrid(4);
      grid.zoneActivations[BorderZone.fire] = 7;
      grid.zoneActivations[BorderZone.water] = 7;

      expect(isSupreme(CARules.fire, grid), isFalse);
      expect(isSupreme(CARules.water, grid), isFalse);
    });

    test('all-zero pressure: dominant is neutral, not supreme', () {
      final grid = HexGrid(4);
      grid.stepCount = 5;

      final result = advanceDominance(CARules.neutral, grid);

      expect(result.dominant, equals(CARules.neutral));
      expect(result.isSupreme, isFalse);
      expect(result.rule, equals(CARules.neutral));
    });
  });

  group('pressure survives neutral generations (no reset-on-neutral)', () {
    test('repeated neutral (non-supreme, tied) generations keep pressure rather than resetting it', () {
      final grid = HexGrid(4);
      grid.zoneActivations[BorderZone.fire] = 4;
      grid.zoneActivations[BorderZone.water] = 4; // tied -> dominant=neutral, dispatch=neutral
      grid.stepCount = 1; // D = 0

      final r1 = advanceDominance(CARules.neutral, grid);
      expect(r1.rule, equals(CARules.neutral));
      expect(grid.zoneActivations[BorderZone.fire], greaterThan(0));

      // More border activity arrives (CAStep.step's border branch keeps
      // incrementing zoneActivations every generation regardless of which
      // rule is dispatched -- untouched by this task) while dispatch
      // keeps gating to neutral.
      grid.zoneActivations[BorderZone.fire] = grid.zoneActivations[BorderZone.fire]! + 3;
      grid.zoneActivations[BorderZone.water] = grid.zoneActivations[BorderZone.water]! + 3;
      grid.stepCount = 2; // D = 1

      final r2 = advanceDominance(CARules.neutral, grid);

      expect(r2.rule, equals(CARules.neutral), reason: 'still tied at 7-7 before decay, 6-6 after');
      // The critical regression guard: pressure is not reset to zero by
      // having stayed neutral -- it's still present (decayed some, but
      // clearly higher than where it started, not wiped).
      expect(grid.zoneActivations[BorderZone.fire], greaterThan(4));
      expect(grid.zoneActivations[BorderZone.water], greaterThan(4));
    });
  });
}
