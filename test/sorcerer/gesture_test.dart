// SPDX-License-Identifier: GPL-3.0-or-later
//
// gesture_test.dart — Gesture enum reconcile (SORC.0): melee added,
// neutral/melee both map to no enhancement zone, elemental zones unchanged.

import 'package:test/test.dart';
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

  test('kSomaticCaptureEnabled stays false pending a real-device pass', () {
    expect(kSomaticCaptureEnabled, isFalse);
  });
}
