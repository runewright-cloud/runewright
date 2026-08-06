// SPDX-License-Identifier: GPL-3.0-or-later
//
// gesture_test.dart — Gesture enum reconcile (SORC.0): melee added,
// neutral/melee both map to no enhancement zone, elemental zones unchanged.

import 'package:test/test.dart';
import 'package:rune_duel/battle/models/match_config.dart';
import 'package:rune_duel/sorcerer/gesture.dart';

void main() {
  test('elemental gestures map to their enhancement zone', () {
    expect(Gesture.fire.enhancementZone, 'fire');
    expect(Gesture.air.enhancementZone, 'air');
    expect(Gesture.water.enhancementZone, 'water');
    expect(Gesture.earth.enhancementZone, 'earth');
  });

  test('neutral and melee both map to no enhancement zone', () {
    expect(Gesture.neutral.enhancementZone, isNull);
    expect(Gesture.melee.enhancementZone, isNull);
  });

  test('melee is present in the enum (SORC.0 reconcile)', () {
    expect(Gesture.values, contains(Gesture.melee));
  });

  // The compile-time `kSomaticCaptureEnabled` gate this used to assert on is
  // gone: somatic capture is switched on per match by the negotiated
  // MatchConfig flag (docs/SPELL_COMPONENTS_PLAN.md §4.2), so "is it on?" is
  // a question about a match, not about the binary. Off by default is the
  // property still worth pinning.
  test('somatic components are off unless a match asks for them', () {
    expect(const MatchConfig().somaticComponents, isFalse);
    expect(const MatchConfig().componentsEnabled, isFalse);
    expect(
      const MatchConfig(somaticComponents: true).componentsEnabled,
      isTrue,
    );
  });
}
