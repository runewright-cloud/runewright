// SPDX-License-Identifier: GPL-3.0-or-later
//
// vocal_score.dart — VocalScore value type and VocalWord vocabulary enum.
//
// VocalScore is the output of VocalScorer.endCapture() and encodes both the
// pronunciation confidence (0.0–1.0) and the volume level relative to the
// ambient noise floor (0.0–1.0).
//
// Wire encoding: each field is quantised to u8 via toWireBytes() before
// transmission. Full double precision does NOT survive the wire round trip;
// see the precision comment on toWireBytes().

import 'dart:typed_data';

// ── Vocabulary ────────────────────────────────────────────────────────────────

/// The five incantation words recognised in Sorcerer mode.
enum VocalWord {
  ignis,  // fire
  aer,    // air
  aqua,   // water
  terra,  // earth
  finis;  // terminator (dismissal / chain break)

  /// Maps a spell's primary affinity zone name (SpellAsset.formula[0]; one
  /// of 'fire'/'air'/'water'/'earth', see spell_asset.dart) to the
  /// incantation word the caster must speak. Returns null for an unrecognised
  /// or empty zone name.
  static VocalWord? fromAffinityZone(String zone) => switch (zone.toLowerCase()) {
        'fire' => VocalWord.ignis,
        'air' => VocalWord.aer,
        'water' => VocalWord.aqua,
        'earth' => VocalWord.terra,
        _ => null,
      };
}

// ── Score type ────────────────────────────────────────────────────────────────

/// Per-cast vocal quality score produced by a VocalScorer.
///
/// Both fields are in [0.0, 1.0]. Values outside this range are clamped at
/// the wire boundary and must not be produced by scorer implementations.
class VocalScore {
  const VocalScore({required this.pronunciation, required this.volume});

  /// Pronunciation confidence: how closely the spoken word matched the target.
  final double pronunciation;

  /// Volume level relative to the calibrated ambient noise floor.
  final double volume;

  // ── Decoded-u8 accessors ──────────────────────────────────────────────────
  //
  // CastingEnhancements.fromSorcererQuality() (the shared mana/fizzle/
  // enhancement curve) MUST read these, never [pronunciation]/[volume]
  // directly. [_quantizeU8] is the exact formula [toWireBytes] uses, so a
  // raw (pre-transmission) score and a wire-decoded score that represent the
  // "same" value always snap to the identical u8 here — which is what makes
  // the curve produce the same fizzle/enhancement/mana outcome on the
  // casting device (reading the raw double, before it's ever encoded) and
  // the peer device (reading the decoded double, after the wire round trip).

  /// Quantises [value] to the wire-precision u8 grid [0x00–0xFE].
  static int _quantizeU8(double value) => (value * 254).round().clamp(0, 254);

  /// [pronunciation] snapped to the u8 grid it will occupy on the wire.
  int get pronunciationU8 => _quantizeU8(pronunciation);

  /// [volume] snapped to the u8 grid it will occupy on the wire.
  int get volumeU8 => _quantizeU8(volume);

  // ── Scalar conversion ─────────────────────────────────────────────────────

  /// Converts the two-component score to a single [0.0, 1.0] quality scalar
  /// for CastingEnhancements.fromSorcererQuality(vocalScore: ...).
  ///
  // TODO(sorcerer): implement the (pronunciation, volume) → scalar mapping.
  // Placeholder: pronunciation alone is the scalar until the formula is
  // finalised at playtest (casting_enhancements.dart already has the seam).
  double toScalar() => pronunciation;

  // ── Volume helper ─────────────────────────────────────────────────────────

  /// Converts a raw RMS amplitude to a volume score in [0.0, 1.0].
  ///
  /// [rms]          RMS from MfccExtractor.computeRms() (0.0–1.0 scale).
  /// [ambientFloor] Noise-floor RMS from AmbientCalibrator.measure().
  /// [k]            Full-volume threshold: rms ≥ k×floor → 1.0.
  ///
  // TODO(sorcerer): tune k for the expected play environment.
  static double volumeFromRms(double rms, double ambientFloor,
      {double k = 3.0}) {
    if (ambientFloor <= 0.0) return 0.0;
    return (rms / (k * ambientFloor)).clamp(0.0, 1.0);
  }

  // ── Wire serialisation ────────────────────────────────────────────────────

  /// Number of bytes occupied in the sorcerer suffix of a spell action payload.
  static const int wireSizeBytes = 3;

  /// Encodes this score to the 3-byte sorcerer suffix appended to a spell action.
  ///
  /// Wire precision: pronunciation and volume are quantised to u8 [0x00–0xFE];
  /// encoding: field_u8 = (value × 254).round().clamp(0, 254);
  /// decoding: value = u8 / 254.0.
  /// ±(1/254) ≈ 0.4% precision loss. Full double precision does NOT survive
  /// the wire round trip.
  ///
  /// Somatic score byte: 0xFF = absent (this pass). 0xFF is permanently
  /// reserved as the absent sentinel — real somatic scores MUST fit [0x00–0xFE]
  /// when implemented in the somatic-gesture pass.
  // TODO(sorcerer): replace somatic 0xFF with somatic_u8 = (somaticScore × 254).round()
  //   in the somatic-gesture pass.
  Uint8List toWireBytes() =>
      Uint8List.fromList([pronunciationU8, volumeU8, 0xFF]);

  /// Decodes a VocalScore from 3 bytes starting at [offset] in [bytes].
  ///
  /// The somatic byte (always 0xFF this pass) is consumed but ignored.
  ///
  /// RECEIVING-SIDE CONSTRAINT: this constructor accepts only the bytes
  /// transmitted by the caster. It does not and cannot recalculate the score
  /// from audio — the peer's microphone is unavailable on this device. See the
  /// broader structural comment in TurnLoop._decodeAction.
  static VocalScore fromWireBytes(Uint8List bytes, int offset) {
    final pronunciationU8 = bytes[offset];
    final volumeU8 = bytes[offset + 1];
    // bytes[offset + 2]: somatic byte, always 0xFF this pass; intentionally ignored.
    return VocalScore(
      pronunciation: pronunciationU8 / 254.0,
      volume: volumeU8 / 254.0,
    );
  }

  @override
  String toString() =>
      'VocalScore(pronunciation: ${pronunciation.toStringAsFixed(3)}, '
      'volume: ${volume.toStringAsFixed(3)})';
}
