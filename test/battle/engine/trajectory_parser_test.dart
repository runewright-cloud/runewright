// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:rune_duel/battle/engine/trajectory_parser.dart';
import 'package:rune_duel/battle/engine/proof_intake.dart';
import 'package:rune_duel/engine/border_zone.dart';

// ── Test helpers ──────────────────────────────────────────────────────────────

/// Build a minimal VerifiedSpellOutputs for trajectory_parser tests.
/// proofBytes is a placeholder; only t, tierMax, dominanceTrajectory,
/// and supremeDominanceFlags are read by TrajectoryParser.
VerifiedSpellOutputs _outputs({
  required int t,
  required List<int> trajectory, // length = tierMax (padded with 0s)
  required List<int> supremeFlags, // length = tierMax (padded with 0s)
}) {
  final tierMax = trajectory.length;
  assert(tierMax == 12 || tierMax == 24 || tierMax == 48);
  assert(supremeFlags.length == tierMax);
  return VerifiedSpellOutputs(
    proofBytes: Uint8List(0),
    t: t,
    ownerPubkeyHex: '0x${'00' * 32}',
    rulesetVersion: 3,
    commitmentHex: '0x${'00' * 32}',
    tierMax: tierMax,
    borderActivations: [0, 0, 0, 0],
    dominanceTrajectory: trajectory,
    supremeDominanceFlags: supremeFlags,
    segmentCount: 0,
    dotCount: 0,
  );
}

List<int> _pad(List<int> v, int total) =>
    [...v, ...List.filled(total - v.length, 0)];

void main() {
  // Element indices: 0=neutral, 1=fire, 2=air, 3=water, 4=earth.

  group('TrajectoryParser — no activations', () {
    test('all neutral → empty formulas and residuals', () {
      final out = _outputs(
        t: 6,
        trajectory: _pad([], 12),
        supremeFlags: _pad([], 12),
      );
      final result = TrajectoryParser.parse(out);
      expect(result.formulas, isEmpty);
      expect(result.residuals, isEmpty);
    });

    test('T=0 is not a valid input per circuit; T=1 all neutral → empty', () {
      final out = _outputs(
        t: 1,
        trajectory: _pad([0], 12),
        supremeFlags: _pad([0], 12),
      );
      final result = TrajectoryParser.parse(out);
      expect(result.formulas, isEmpty);
      expect(result.residuals, isEmpty);
    });
  });

  group('TrajectoryParser — supreme chain', () {
    // T=3, all fire, all supreme:
    //   gen0: leadChange (fire vs null) → add fire
    //   gen1: no lead change, supreme → add fire
    //   gen2: no lead change, supreme → add fire
    //   → committed=[fire,fire,fire] → one complete formula
    test('T=3 all-fire all-supreme → one [fire,fire,fire] formula, no residuals', () {
      final out = _outputs(
        t: 3,
        trajectory: _pad([1, 1, 1], 12),
        supremeFlags: _pad([1, 1, 1], 12),
      );
      final result = TrajectoryParser.parse(out);
      expect(result.formulas.length, equals(1));
      expect(result.formulas[0], equals(
        const ParsedFormula(
          affinity: BorderZone.fire,
          effectType1: BorderZone.fire,
          effectType2: BorderZone.fire,
        ),
      ));
      expect(result.residuals, isEmpty);
    });
  });

  group('TrajectoryParser — alternating lead changes', () {
    // T=4, fire/air/fire/air alternating, no supreme:
    //   gen0 (_gen=1): leadChange null→fire → add fire
    //   gen1 (_gen=2): leadChange fire→air  → add air
    //   gen2 (_gen=3): leadChange air→fire  → add fire  ← completes triplet!
    //   gen3 (_gen=4): leadChange fire→air  → add air   ← residual
    test('T=4 alternating fire/air → [fire,air,fire] formula, [air] residual', () {
      final out = _outputs(
        t: 4,
        trajectory: _pad([1, 2, 1, 2], 12),
        supremeFlags: _pad([0, 0, 0, 0], 12),
      );
      final result = TrajectoryParser.parse(out);
      expect(result.formulas.length, equals(1));
      expect(result.formulas[0], equals(
        const ParsedFormula(
          affinity: BorderZone.fire,
          effectType1: BorderZone.air,
          effectType2: BorderZone.fire,
        ),
      ));
      expect(result.residuals, equals([BorderZone.air]));
    });
  });

  group('TrajectoryParser — pulse step', () {
    // T=9, all fire, no supreme:
    //   _gen=1: leadChange → fire. [fire]
    //   _gen=2: no change, no pulse → nothing
    //   _gen=3: no change, no pulse → nothing
    //   _gen=4: pulse! → fire. [fire,fire]
    //   _gen=5..7: nothing
    //   _gen=8: pulse! → fire. [fire,fire,fire] ← formula!
    //   _gen=9: nothing
    //   → one formula [fire,fire,fire], no residuals
    test('T=9 all-fire no-supreme → one [fire,fire,fire] formula via pulses', () {
      final out = _outputs(
        t: 9,
        trajectory: _pad([1, 1, 1, 1, 1, 1, 1, 1, 1], 12),
        supremeFlags: _pad([0, 0, 0, 0, 0, 0, 0, 0, 0], 12),
      );
      final result = TrajectoryParser.parse(out);
      expect(result.formulas.length, equals(1));
      expect(result.formulas[0], equals(
        const ParsedFormula(
          affinity: BorderZone.fire,
          effectType1: BorderZone.fire,
          effectType2: BorderZone.fire,
        ),
      ));
      expect(result.residuals, isEmpty);
    });
  });

  group('TrajectoryParser — masked generations', () {
    // Entries at gen >= T should be 0 (neutral) in a real proof.
    // Parser only reads [0..T-1]; padding with non-zero values beyond T
    // must not affect output.
    test('non-zero padding beyond T does not affect result', () {
      // T=3, all fire+supreme → one formula (as above).
      // Beyond T: fill with garbage (element 4 = earth).
      final trajectory = [...List.filled(3, 1), ...List.filled(9, 4)];
      final supremeFlags = [...List.filled(3, 1), ...List.filled(9, 1)];
      final out = _outputs(t: 3, trajectory: trajectory, supremeFlags: supremeFlags);
      final result = TrajectoryParser.parse(out);
      // Should match the T=3 all-fire-supreme result exactly.
      expect(result.formulas.length, equals(1));
      expect(result.formulas[0].affinity, equals(BorderZone.fire));
      expect(result.residuals, isEmpty);
    });
  });

  group('TrajectoryParser — all four elements', () {
    // T=6, lead-change sequence fire→water→earth produces [fire,water,earth]
    // then air leadChange → residual [air].
    test('T=4 fire/water/earth/air → [fire,water,earth] + [air] residual', () {
      final out = _outputs(
        t: 4,
        trajectory: _pad([1, 3, 4, 2], 12), // fire, water, earth, air
        supremeFlags: _pad([0, 0, 0, 0], 12),
      );
      final result = TrajectoryParser.parse(out);
      expect(result.formulas.length, equals(1));
      expect(result.formulas[0], equals(
        const ParsedFormula(
          affinity: BorderZone.fire,
          effectType1: BorderZone.water,
          effectType2: BorderZone.earth,
        ),
      ));
      expect(result.residuals, equals([BorderZone.air]));
    });
  });

  group('TrajectoryParser.certifiedPerGenerationDominantSequence', () {
    test('keeps one entry per non-neutral generation, repeats included -- '
        'unlike the compressed certifiedElementSequence', () {
      // Four straight fire generations: the formula view commits fire twice
      // (lead change at gen 1, cadence pulse at gen 4); the per-generation
      // view keeps all four. Armor reads the latter.
      final out = _outputs(
        t: 4,
        trajectory: _pad([1, 1, 1, 1], 12),
        supremeFlags: _pad([], 12),
      );
      expect(
        TrajectoryParser.certifiedPerGenerationDominantSequence(out),
        List.filled(4, BorderZone.fire),
      );
      expect(TrajectoryParser.certifiedElementSequence(out),
          [BorderZone.fire, BorderZone.fire]);
    });

    test('neutral generations contribute nothing', () {
      final out = _outputs(
        t: 5,
        trajectory: _pad([1, 0, 0, 2, 0], 12),
        supremeFlags: _pad([], 12),
      );
      expect(TrajectoryParser.certifiedPerGenerationDominantSequence(out),
          [BorderZone.fire, BorderZone.air]);
    });

    test('only generations 0..t-1 are read', () {
      final out = _outputs(
        t: 2,
        trajectory: _pad([4, 4, 1, 1, 1], 12),
        supremeFlags: _pad([], 12),
      );
      expect(TrajectoryParser.certifiedPerGenerationDominantSequence(out),
          [BorderZone.earth, BorderZone.earth]);
    });
  });

  group('TrajectoryParser.certifiedElementSequence — design doc "Summons"', () {
    test('all neutral → empty sequence', () {
      final out = _outputs(
        t: 6,
        trajectory: _pad([], 12),
        supremeFlags: _pad([], 12),
      );
      expect(TrajectoryParser.certifiedElementSequence(out), isEmpty);
    });

    test('returns the FULL flat committed sequence, including the residual '
        '-- unlike parse(), which drops it into a separate list', () {
      final out = _outputs(
        t: 4,
        trajectory: _pad([1, 2, 1, 2], 12), // fire, air, fire, air
        supremeFlags: _pad([0, 0, 0, 0], 12),
      );
      final sequence = TrajectoryParser.certifiedElementSequence(out);
      expect(sequence, equals([
        BorderZone.fire, BorderZone.air, BorderZone.fire, BorderZone.air,
      ]));

      // Cross-check against parse(): sequence == formulas flattened ++ residuals.
      final parsed = TrajectoryParser.parse(out);
      final flattened = [
        for (final f in parsed.formulas) ...[f.affinity, f.effectType1, f.effectType2],
        ...parsed.residuals,
      ];
      expect(sequence, equals(flattened));
    });

    test('four distinct elements with a residual', () {
      final out = _outputs(
        t: 4,
        trajectory: _pad([1, 3, 4, 2], 12), // fire, water, earth, air
        supremeFlags: _pad([0, 0, 0, 0], 12),
      );
      expect(TrajectoryParser.certifiedElementSequence(out), equals([
        BorderZone.fire, BorderZone.water, BorderZone.earth, BorderZone.air,
      ]));
    });

    test('only the first outputs.t generations are read (masked tail ignored)', () {
      // Same trajectory as above but T=2: only fire, water should commit.
      final out = _outputs(
        t: 2,
        trajectory: _pad([1, 3, 4, 2], 12),
        supremeFlags: _pad([0, 0, 0, 0], 12),
      );
      expect(TrajectoryParser.certifiedElementSequence(out), equals([
        BorderZone.fire, BorderZone.water,
      ]));
    });
  });
}
