// SPDX-License-Identifier: GPL-3.0-or-later
//
// gesture.dart — Gesture: the somatic-cast counterpart to VocalSlot/
// VocalScore. The capture pipeline now exists (gesture_capture.dart,
// gesture_classifier.dart, lib/practice/gesture_enrollment.dart,
// practice_screen.dart's Gesture tab) — see docs/SOMATIC_GESTURE_PLAN.md.
// As of docs/SPELL_COMPONENTS_PLAN.md the pipeline is wired into the live
// cast seam: battle_screen.dart captures IMU for the whole CAST hold and this
// enum's [enhancementZone] is what selects the enhancement, replacing the tap
// picker whenever `MatchConfig.somaticComponents` is on.
//
// [melee] is captured into the enrollment/calibration corpus now (it's one
// of the five gestures a player performs) but is not an enhancement — its
// in-game wiring belongs to the real-time-movement milestone, not here.

/// A somatic gesture performed while casting. Maps to the elemental
/// enhancement zone it would select, or [neutral] for no enhancement.
enum Gesture {
  fire,
  air,
  water,
  earth,
  neutral,
  melee;

  /// The enhancement zone tag ('fire'/'air'/'water'/'earth') this gesture
  /// selects, or null for [neutral]/[melee] (cast with no enhancement;
  /// melee is an action, not an enhancement).
  String? get enhancementZone => switch (this) {
        Gesture.fire => 'fire',
        Gesture.air => 'air',
        Gesture.water => 'water',
        Gesture.earth => 'earth',
        Gesture.neutral => null,
        Gesture.melee => null,
      };
}

// `kSomaticCaptureEnabled` used to live here as a compile-time gate. It is
// GONE, not flipped: somatic capture is now switched on per match by
// `MatchConfig.somaticComponents` — chosen in the lobby, agreed by both sides,
// and therefore askable at the point of use rather than baked into the binary
// (docs/SPELL_COMPONENTS_PLAN.md §4.2).
//
// The hardware gate the constant held is not gone either, only moved out of
// the type system: SOMATIC_GESTURE_PLAN.md §11 step 6's real-device pass over
// the live cast seam is still outstanding, and is recorded as such in
// SPELL_COMPONENTS_PLAN.md §7.
