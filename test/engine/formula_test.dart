// SPDX-License-Identifier: GPL-3.0-or-later
//
// formula_test.dart — unit tests for FormulaTracker's three-rule accrual
// cascade (lib/engine/formula.dart). Drives the tracker with synthetic
// per-generation (zone, supreme) sequences via step() -- no need to
// engineer CA/dominance geometry for the parsing math itself (that's
// covered by dominance_test.dart and the GameScreen-level end-to-end test
// at the bottom of this file).
//
// These tests assert the NEW cascade directly; the old commit-on-run-end
// semantics are not characterized or preserved anywhere (no prior test
// existed for FormulaTracker -- this is the first).

import 'package:test/test.dart';
import 'package:rune_duel/engine/border_zone.dart';
import 'package:rune_duel/engine/formula.dart';

void main() {
  group('rule 1 (lead change) in isolation', () {
    test('one entry per lead change, in order, on non-pulse non-supreme generations', () {
      final t = FormulaTracker();
      t.step(BorderZone.fire);   // gen1: lead change (fire != null)
      t.step(BorderZone.earth);  // gen2: lead change (earth != fire)
      t.step(BorderZone.water);  // gen3: lead change (water != earth)

      expect(t.committed, equals([BorderZone.fire, BorderZone.earth, BorderZone.water]));
    });

    test('no entry while the same zone stays dominant (no lead change, not supreme, not a pulse gen)', () {
      final t = FormulaTracker();
      t.step(BorderZone.fire); // gen1: lead change -> add
      t.step(BorderZone.fire); // gen2: same zone, not pulse -> nothing
      t.step(BorderZone.fire); // gen3: same zone, not pulse -> nothing

      expect(t.committed, equals([BorderZone.fire]));
    });
  });

  group('rule 2 (supreme) in isolation', () {
    test('one entry per supreme generation, even with no lead change', () {
      final t = FormulaTracker();
      t.step(BorderZone.fire);                              // gen1: lead change -> add
      t.step(BorderZone.fire, supremeDominant: true);        // gen2: supreme -> add
      t.step(BorderZone.fire, supremeDominant: true);        // gen3: supreme -> add

      expect(t.committed, equals([BorderZone.fire, BorderZone.fire, BorderZone.fire]));
    });
  });

  group('rule 3 (cadence pulse) in isolation', () {
    test('a stable dominant with no lead change and not supreme only adds on pulse generations', () {
      final t = FormulaTracker();
      t.step(BorderZone.water); // gen1: lead change -> add
      t.step(BorderZone.water); // gen2: nothing
      t.step(BorderZone.water); // gen3: nothing
      t.step(BorderZone.water); // gen4: pulse (4 % 4 == 0) -> add
      t.step(BorderZone.water); // gen5: nothing
      t.step(BorderZone.water); // gen6: nothing
      t.step(BorderZone.water); // gen7: nothing
      t.step(BorderZone.water); // gen8: pulse -> add

      expect(t.committed, equals([BorderZone.water, BorderZone.water, BorderZone.water]));
    });
  });

  group('mutual exclusion: at most one entry per generation', () {
    test('a lead change landing on a pulse generation yields one entry, not two', () {
      final t = FormulaTracker();
      t.step(BorderZone.fire);  // gen1: lead change -> add fire
      t.step(BorderZone.fire);  // gen2: nothing
      t.step(BorderZone.fire);  // gen3: nothing
      t.step(BorderZone.water); // gen4: lead change AND pulse -> add water ONCE

      expect(t.committed, equals([BorderZone.fire, BorderZone.water]));
    });

    test('a supreme generation landing on a pulse generation yields one entry, not two', () {
      final t = FormulaTracker();
      t.step(BorderZone.fire);                              // gen1: lead change -> add
      t.step(BorderZone.fire);                              // gen2: nothing
      t.step(BorderZone.fire);                              // gen3: nothing
      t.step(BorderZone.fire, supremeDominant: true);        // gen4: supreme AND pulse -> add ONCE

      expect(t.committed, equals([BorderZone.fire, BorderZone.fire]));
    });

    test('a lead change straight into supreme on the same generation yields one entry, not two', () {
      final t = FormulaTracker();
      t.step(BorderZone.fire);                                          // gen1: lead change -> add
      t.step(BorderZone.water, supremeDominant: true);                  // gen2: lead change AND supreme -> add ONCE

      expect(t.committed, equals([BorderZone.fire, BorderZone.water]));
    });
  });

  group('ties (neutral/no-dominant generations) add nothing', () {
    test('a tie stretch contributes no entries, including on a pulse gen, and resets lead-change detection', () {
      final t = FormulaTracker();
      t.step(BorderZone.fire); // gen1: lead change -> add fire
      t.step(null);            // gen2: tie -> nothing, lastDominant resets to null
      t.step(null);            // gen3: tie -> nothing
      t.step(null);            // gen4: tie, also a pulse gen, but zone==null -> still nothing
      t.step(BorderZone.fire); // gen5: fire again, but lastDominant is null (from the tie) ->
                                //   counts as a fresh lead change -> add fire a second time

      expect(t.committed, equals([BorderZone.fire, BorderZone.fire]),
          reason: 'fire -> tie -> fire counts as two separate fires, same as the old '
              'fire -> neutral -> fire framing, but via lead-change-after-null rather than run-end commit');
    });

    test('a tie at a would-be pulse generation with supreme also adds nothing (zone must be non-null)', () {
      final t = FormulaTracker();
      t.step(null, supremeDominant: false); // gen1
      t.step(null, supremeDominant: false); // gen2
      t.step(null, supremeDominant: false); // gen3
      t.step(null, supremeDominant: false); // gen4: pulse, but still a tie

      expect(t.committed, isEmpty);
    });
  });

  group('pendingZone: preview of the current dominant when nothing was added this step', () {
    test('null immediately after an addition; the dominant zone when nothing fires', () {
      final t = FormulaTracker();
      t.step(BorderZone.fire);
      expect(t.pendingZone, isNull, reason: 'fire was just added (lead change), nothing pending');

      t.step(BorderZone.fire); // no lead change, not supreme, not pulse -> nothing added
      expect(t.pendingZone, equals(BorderZone.fire), reason: 'fire is leading but nothing fired for it this step');

      t.step(null); // tie
      expect(t.pendingZone, isNull, reason: 'no dominant at all this step');
    });
  });

  group('formulas / residuals grouping', () {
    test('groups commit in 3s; leftover 1-2 entries stay as residuals', () {
      final t = FormulaTracker();
      t.step(BorderZone.fire);
      t.step(BorderZone.water);
      t.step(BorderZone.earth);
      t.step(BorderZone.air);

      expect(t.formulas, equals([[BorderZone.fire, BorderZone.water, BorderZone.earth]]));
      expect(t.residuals, equals([BorderZone.air]));
    });
  });

  group('reset', () {
    test('clears committed/pending/lead-change/generation state', () {
      final t = FormulaTracker();
      t.step(BorderZone.fire);
      t.step(BorderZone.fire); // pending
      t.reset();

      expect(t.committed, isEmpty);
      expect(t.pendingZone, isNull);

      // Generation counter and lead-change tracking reset too: a fresh
      // fire after reset is a lead change (gen1 again), and pulse timing
      // restarts from gen1, not wherever it left off.
      t.step(BorderZone.fire);
      expect(t.committed, equals([BorderZone.fire]));
    });
  });
}
