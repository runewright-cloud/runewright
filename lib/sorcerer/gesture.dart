// SPDX-License-Identifier: GPL-3.0-or-later
//
// gesture.dart — Gesture: the somatic-cast counterpart to VocalWord/
// VocalScore. The capture pipeline now exists (gesture_capture.dart,
// gesture_classifier.dart, lib/practice/gesture_enrollment.dart,
// practice_screen.dart's Gesture tab) — see docs/SOMATIC_GESTURE_PLAN.md.
// [kSomaticCaptureEnabled] stays false until that pipeline has cleared a
// real-device confusion-matrix pass (SORC.5, plan §9/§11); until then this
// file is still the stable seam battle_screen.dart's cast-time enhancement
// picker builds against, mirroring how VocalWord/VocalScore/
// fromSorcererQuality were seamed in before VocalScorer existed.
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

/// Stub gate: real somatic-gesture capture (sensor + classifier) exists but
/// has not cleared a real-device confusion-matrix pass. Always false. Flip
/// only once GestureClassifier's harness (test/sorcerer/) passes against a
/// real captured corpus — see VocalScore's 0xFF somatic-byte sentinel
/// (vocal_score.dart, turn_loop.dart) this seam eventually feeds.
const bool kSomaticCaptureEnabled = false;
