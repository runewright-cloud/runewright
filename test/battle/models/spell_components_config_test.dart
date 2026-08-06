// SPDX-License-Identifier: GPL-3.0-or-later
//
// spell_components_config_test.dart — the three negotiated component flags
// (docs/SPELL_COMPONENTS_PLAN.md §1).
//
// MatchConfig agreement is field-by-field and a mismatch aborts the session,
// so a flag that silently fails to participate in [matches] is a mode
// desync waiting to happen: one device opening a microphone and appending a
// recall suffix while the other parses the payload without one.

import 'package:test/test.dart';
import 'package:rune_duel/battle/models/match_config.dart';

void main() {
  group('defaults', () {
    test('every component is off, and casting is simultaneous-free', () {
      const c = MatchConfig();
      expect(c.vocalComponents, isFalse);
      expect(c.somaticComponents, isFalse);
      expect(c.simultaneousCasting, isFalse);
      expect(c.componentsEnabled, isFalse);
    });

    test('sequential casting needs a component to order', () {
      // Not the plain negation of simultaneousCasting: with nothing to
      // perform, ordering would be pure latency.
      expect(const MatchConfig().sequentialCasting, isFalse);
      expect(
        const MatchConfig(vocalComponents: true).sequentialCasting,
        isTrue,
      );
      expect(
        const MatchConfig(somaticComponents: true).sequentialCasting,
        isTrue,
      );
      expect(
        const MatchConfig(vocalComponents: true, simultaneousCasting: true)
            .sequentialCasting,
        isFalse,
      );
    });
  });

  group('agreement', () {
    test('each flag on its own breaks agreement', () {
      const base = MatchConfig();
      expect(base.matches(const MatchConfig(vocalComponents: true)), isFalse);
      expect(base.matches(const MatchConfig(somaticComponents: true)), isFalse);
      expect(
        base.matches(const MatchConfig(simultaneousCasting: true)),
        isFalse,
      );
    });

    test('identical component settings agree', () {
      const a = MatchConfig(
        vocalComponents: true,
        somaticComponents: true,
        simultaneousCasting: true,
      );
      const b = MatchConfig(
        vocalComponents: true,
        somaticComponents: true,
        simultaneousCasting: true,
      );
      expect(a.matches(b), isTrue);
    });
  });

  group('serialisation', () {
    test('round-trips all three', () {
      const c = MatchConfig(
        vocalComponents: true,
        somaticComponents: false,
        simultaneousCasting: true,
      );
      final back = MatchConfig.fromJson(c.toJson());
      expect(back.vocalComponents, isTrue);
      expect(back.somaticComponents, isFalse);
      expect(back.simultaneousCasting, isTrue);
      expect(c.matches(back), isTrue);
    });

    test('a pre-split config loads sorcererMode as vocal components', () {
      // `sorcererMode` meant exactly what vocalComponents means now. Reading
      // it as "no components at all" would quietly drop a stored config's
      // whole point.
      final back = MatchConfig.fromJson(const {'sorcererMode': true});
      expect(back.vocalComponents, isTrue);
      expect(back.somaticComponents, isFalse);
      expect(back.simultaneousCasting, isFalse);
    });

    test('the new key wins over the legacy one', () {
      final back = MatchConfig.fromJson(
        const {'sorcererMode': true, 'vocalComponents': false},
      );
      expect(back.vocalComponents, isFalse);
    });
  });
}
