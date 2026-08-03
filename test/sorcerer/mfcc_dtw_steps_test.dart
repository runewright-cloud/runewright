// SPDX-License-Identifier: GPL-3.0-or-later
//
// mfcc_dtw_steps_test.dart — unit tests for DtwMatcher.distanceWithSteps
// (lib/sorcerer/mfcc.dart), added for Practice Mode's
// StreamingPhonemeScorer. The property under test is exactly the one the
// checkpoint floor depends on: cost/steps (length-normalized local match
// quality) stays close whether the same content is delivered at reference
// speed or stretched out, whereas raw accumulated cost does not.

import 'package:test/test.dart';
import 'package:rune_duel/sorcerer/mfcc.dart';

List<List<double>> _stretch(List<List<double>> frames, int factor) => [
      for (final f in frames)
        for (int i = 0; i < factor; i++) f,
    ];

void main() {
  final reference = [
    [1.0, 2.0, 3.0],
    [1.5, 2.5, 3.5],
    [2.0, 3.0, 4.0],
    [2.5, 3.5, 4.5],
  ];

  test('exact match at reference speed: near-zero cost, diagonal-length path', () {
    final result = DtwMatcher.distanceWithSteps(reference, reference);
    expect(result.cost, closeTo(0.0, 1e-9));
    // The optimal (min-cost) path for identical sequences is the pure
    // diagonal (cost 0 at every step); any off-diagonal detour would incur
    // nonzero cost since the reference itself varies frame to frame. So the
    // winning path length is n, not the n+m-1 an edge-hugging path would take.
    expect(result.steps, reference.length);
  });

  test('length-normalized quality stays close whether stretched 1x or 3x', () {
    final fast = reference; // "spoken" at reference rate
    final slow = _stretch(reference, 3); // same content, 3x slower delivery

    final fastResult = DtwMatcher.distanceWithSteps(fast, reference);
    final slowResult = DtwMatcher.distanceWithSteps(slow, reference);

    final fastNormalized = fastResult.cost / fastResult.steps;
    final slowNormalized = slowResult.cost / slowResult.steps;

    expect(fastNormalized, closeTo(0.0, 1e-9));
    expect(slowNormalized, closeTo(0.0, 1e-9));
    expect((fastNormalized - slowNormalized).abs(), lessThan(1e-6));
  });

  test('raw accumulated cost is NOT rate-invariant on a noisy match '
      '(this is exactly why the checkpoint floor uses cost/steps, not cost)', () {
    final noisy = [
      for (final f in reference) [f[0] + 0.3, f[1] + 0.3, f[2] + 0.3],
    ];
    final noisySlow = _stretch(noisy, 3);

    final fastResult = DtwMatcher.distanceWithSteps(noisy, reference);
    final slowResult = DtwMatcher.distanceWithSteps(noisySlow, reference);

    // Same per-frame mismatch, delivered 3x slower -> raw cost roughly
    // triples (more steps, each still paying the same local distance),
    // while the normalized quality (cost/steps) stays close.
    expect(slowResult.cost, greaterThan(fastResult.cost * 2));

    final fastNormalized = fastResult.cost / fastResult.steps;
    final slowNormalized = slowResult.cost / slowResult.steps;
    // Some residual gap is expected on a toy 4-frame reference (boundary
    // effects from DTW's corner-anchored seeding are a bigger proportion of
    // a very short path); it shrinks for the tens-of-frames-long references
    // real words actually produce. The property under test is that this gap
    // is small relative to the ~3x raw-cost blowup above, not exactly zero.
    expect((fastNormalized - slowNormalized).abs(), lessThan(0.15));
  });

  test('a genuinely different sequence normalizes to a much higher quality value', () {
    final wrong = [
      [50.0, 50.0, 50.0],
      [51.0, 51.0, 51.0],
      [52.0, 52.0, 52.0],
      [53.0, 53.0, 53.0],
    ];
    final good = DtwMatcher.distanceWithSteps(reference, reference);
    final bad = DtwMatcher.distanceWithSteps(wrong, reference);
    expect(bad.cost / bad.steps, greaterThan(good.cost / good.steps + 10));
  });

  test('empty query or reference returns infinite cost', () {
    final result = DtwMatcher.distanceWithSteps(const [], reference);
    expect(result.cost.isFinite, isFalse);
  });
}
