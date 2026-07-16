// SPDX-License-Identifier: GPL-3.0-or-later
//
// gesture.dart — Gesture: the somatic-cast counterpart to VocalWord/
// VocalScore. No capture pipeline exists yet — see practice_screen.dart's
// "Gesture" tab, still a "coming soon" stub, and VocalScore's reserved-but-
// unused somatic byte (vocal_score.dart, turn_loop.dart).
//
// This file defines only the enum, its mapping to a cast-time enhancement
// zone, and the always-false capture-availability gate, so
// battle_screen.dart's cast-time enhancement picker has a stable seam to
// build the real capture pipeline against later — mirroring how
// VocalWord/VocalScore/fromSorcererQuality were seamed in before VocalScorer
// existed.

/// A somatic gesture performed while casting. Maps to the elemental
/// enhancement zone it would select, or [neutral] for no enhancement.
enum Gesture {
  fire,
  air,
  water,
  earth,
  neutral;

  /// The enhancement zone tag ('fire'/'air'/'water'/'earth') this gesture
  /// selects, or null for [neutral] (cast with no enhancement).
  String? get enhancementZone => switch (this) {
        Gesture.fire => 'fire',
        Gesture.air => 'air',
        Gesture.water => 'water',
        Gesture.earth => 'earth',
        Gesture.neutral => null,
      };
}

/// Stub gate: real somatic-gesture capture (sensor + classifier) is not
/// built this pass. Always false. Flip only once a GestureScorer exists —
/// see VocalScorer for the shape a capture pipeline should take, and
/// VocalScore's 0xFF somatic-byte sentinel (vocal_score.dart, turn_loop.dart)
/// this seam eventually feeds.
const bool kSomaticCaptureEnabled = false;
