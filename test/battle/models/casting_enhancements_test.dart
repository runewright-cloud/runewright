// SPDX-License-Identifier: GPL-3.0-or-later
//
// casting_enhancements_test.dart — unit tests for
// CastingEnhancements.fromSorcererQuality: the vocal-quality → mana/fizzle/
// enhancement curve.
//
// The determinism test is the load-bearing one: it confirms the curve
// produces an identical result for a raw (pre-transmission) VocalScore and
// the same score after a wire round trip, which is what keeps the casting
// device and the peer device in lockstep agreement (see the determinism
// note on VocalScore.pronunciationU8/volumeU8 and on fromSorcererQuality).

import 'package:test/test.dart';
import 'package:rune_duel/battle/models/casting_enhancements.dart';
import 'package:rune_duel/sorcerer/vocal_score.dart';

void main() {
  group('fromSorcererQuality', () {
    test('q >= qMin: full enhancement, no mana penalty', () {
      const score = VocalScore(pronunciation: 0.95, volume: 0.95);
      final result = CastingEnhancements.fromSorcererQuality(
        vocalScore: score,
        hasPotentLoadout: true,
        hasVelocityLoadout: false,
        hasEfficiencyLoadout: false,
      );
      expect(result.fizzle, isFalse);
      expect(result.enhancementEnabled, isTrue);
      expect(result.isPotent, isTrue);
      expect(result.isVelocity, isFalse);
      expect(result.manaCostMultiplier, 1.0);
    });

    test('q < qFizzle: fizzles, enhancement off, mana multiplier at the ramp ceiling', () {
      const score = VocalScore(pronunciation: 0.05, volume: 0.05);
      final result = CastingEnhancements.fromSorcererQuality(
        vocalScore: score,
        hasPotentLoadout: true,
        hasVelocityLoadout: true,
        hasEfficiencyLoadout: true,
      );
      expect(result.fizzle, isTrue);
      expect(result.enhancementEnabled, isFalse);
      expect(result.isPotent, isFalse);
      expect(result.isVelocity, isFalse);
      expect(result.manaCostMultiplier, 1.50);
    });

    test('qFizzle <= q < qMin: ramps between 1.01 and 1.50, accelerating near qFizzle', () {
      // q just under qMin: penalty should be small (near 1.01).
      const nearMin = VocalScore(pronunciation: 0.54, volume: 0.54);
      final nearMinResult = CastingEnhancements.fromSorcererQuality(
        vocalScore: nearMin,
        hasPotentLoadout: true,
        hasVelocityLoadout: true,
        hasEfficiencyLoadout: true,
      );
      expect(nearMinResult.fizzle, isFalse);
      expect(nearMinResult.enhancementEnabled, isFalse);
      expect(nearMinResult.manaCostMultiplier, greaterThan(1.01));
      expect(nearMinResult.manaCostMultiplier, lessThan(1.10));

      // q just above qFizzle: penalty should be near the 1.50 ceiling.
      const nearFizzle = VocalScore(pronunciation: 0.21, volume: 0.21);
      final nearFizzleResult = CastingEnhancements.fromSorcererQuality(
        vocalScore: nearFizzle,
        hasPotentLoadout: true,
        hasVelocityLoadout: true,
        hasEfficiencyLoadout: true,
      );
      expect(nearFizzleResult.fizzle, isFalse);
      expect(nearFizzleResult.manaCostMultiplier, greaterThan(1.30));
      expect(nearFizzleResult.manaCostMultiplier, lessThanOrEqualTo(1.50));

      // Ease-in: the mid-bracket multiplier must be below the straight-line
      // interpolation between the two endpoints (penalty accelerates late).
      const mid = VocalScore(pronunciation: 0.375, volume: 0.375); // ~midpoint of [0.20, 0.55)
      final midResult = CastingEnhancements.fromSorcererQuality(
        vocalScore: mid,
        hasPotentLoadout: false,
        hasVelocityLoadout: false,
        hasEfficiencyLoadout: false,
      );
      const linearMidpoint = (1.01 + 1.50) / 2;
      expect(midResult.manaCostMultiplier, lessThan(linearMidpoint));
    });

    test('determinism: raw double and its wire round trip agree exactly', () {
      const raw = VocalScore(pronunciation: 0.3742, volume: 0.6051);
      final wireDecoded = VocalScore.fromWireBytes(raw.toWireBytes(), 0);

      final rawResult = CastingEnhancements.fromSorcererQuality(
        vocalScore: raw,
        hasPotentLoadout: true,
        hasVelocityLoadout: true,
        hasEfficiencyLoadout: true,
      );
      final decodedResult = CastingEnhancements.fromSorcererQuality(
        vocalScore: wireDecoded,
        hasPotentLoadout: true,
        hasVelocityLoadout: true,
        hasEfficiencyLoadout: true,
      );

      expect(decodedResult.fizzle, rawResult.fizzle);
      expect(decodedResult.enhancementEnabled, rawResult.enhancementEnabled);
      expect(decodedResult.isPotent, rawResult.isPotent);
      expect(decodedResult.isVelocity, rawResult.isVelocity);
      expect(decodedResult.manaCostMultiplier, rawResult.manaCostMultiplier);
    });

    test('hasPotentLoadout/hasVelocityLoadout false: enhancement gate stays inert', () {
      const score = VocalScore(pronunciation: 0.95, volume: 0.95);
      final result = CastingEnhancements.fromSorcererQuality(
        vocalScore: score,
        hasPotentLoadout: false,
        hasVelocityLoadout: false,
        hasEfficiencyLoadout: false,
      );
      expect(result.enhancementEnabled, isTrue);
      expect(result.isPotent, isFalse);
      expect(result.isVelocity, isFalse);
    });

    test('isEfficiency follows the same enable/disable gate as isPotent', () {
      const good = VocalScore(pronunciation: 0.95, volume: 0.95);
      final enabled = CastingEnhancements.fromSorcererQuality(
        vocalScore: good,
        hasPotentLoadout: false,
        hasVelocityLoadout: false,
        hasEfficiencyLoadout: true,
      );
      expect(enabled.isEfficiency, isTrue);

      const bad = VocalScore(pronunciation: 0.05, volume: 0.05);
      final fizzled = CastingEnhancements.fromSorcererQuality(
        vocalScore: bad,
        hasPotentLoadout: false,
        hasVelocityLoadout: false,
        hasEfficiencyLoadout: true,
      );
      expect(fizzled.isEfficiency, isFalse);
    });
  });
}
