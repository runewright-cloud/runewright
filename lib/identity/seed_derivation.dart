// SPDX-License-Identifier: GPL-3.0-or-later
//
// seed_derivation.dart — deterministic Ed25519 seed derivation from a
// player's 24 d20 rolls (the "Rite of Four-and-Twenty" creation/restore
// path, docs/step1_identity_onboarding_brief.md).
//
// Correctness-critical: this must be deterministic and canonical. The sigil
// paper backup records the 24 roll values, not the derived seed bytes --
// recovery re-enters the same 24 values and must regenerate the byte-
// identical key. So:
//   - Canonical encoding: 24 bytes, one per roll, in entry (= spiral
//     sequence-node) order. No bit-packing -- this never crosses the
//     circuit boundary, so there's no size pressure, and a byte-per-roll
//     encoding is trivial to audit against the human-recorded sigil.
//   - Fixed domain-separation tag, committed in source. No salt: a random
//     salt would mean the 24 rolls alone couldn't rebuild the key, which
//     defeats the paper backup entirely.
//   - seed = SHA-512(domainTag ++ encodedRolls)[0:32].
//
// Entropy: 24 independent d20 rolls is log2(20^24) ≈ 103.7 bits -- well
// short of the auto path's full 256-bit CSPRNG seed, but comfortable for
// this game (state it, don't over-warn; see the onboarding brief).

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// How many d20 rolls the ritual path collects.
const int kRollCount = 24;

/// Fixed domain-separation tag for the rolls -> seed derivation. Changing
/// this is a breaking change: every previously-generated ritual key would
/// derive a different seed from the same recorded rolls.
const String kSeedDerivationDomainTag = 'Runewright Rite of Four-and-Twenty Seed v1';

class InvalidRollsException implements Exception {
  InvalidRollsException(this.message);
  final String message;
  @override
  String toString() => 'InvalidRollsException: $message';
}

/// Validates that [rolls] is exactly [kRollCount] values, each a legal d20
/// result (1-20).
void validateRolls(List<int> rolls) {
  if (rolls.length != kRollCount) {
    throw InvalidRollsException('expected $kRollCount rolls, got ${rolls.length}');
  }
  for (var i = 0; i < rolls.length; i++) {
    final v = rolls[i];
    if (v < 1 || v > 20) {
      throw InvalidRollsException('roll[$i] = $v is out of d20 range (1-20)');
    }
  }
}

/// The canonical byte encoding of [rolls]: one byte per roll, in entry
/// order, raw value (1-20). This is the exact byte sequence that gets
/// domain-tagged and hashed -- a fixed representation so the same 24
/// recorded values always re-derive the same seed.
Uint8List encodeRolls(List<int> rolls) {
  validateRolls(rolls);
  return Uint8List.fromList(rolls);
}

/// Derives the 32-byte Ed25519 seed for a given set of 24 d20 rolls:
/// `SHA-512(domainTag ++ encodeRolls(rolls))[0:32]`.
///
/// Deterministic and salt-free by design -- see file header. Calling this
/// twice with the same [rolls] always yields byte-identical output, which
/// is what makes the sigil/paper backup work as a recovery mechanism.
Future<Uint8List> deriveSeedFromRolls(List<int> rolls) async {
  final encoded = encodeRolls(rolls);
  final input = Uint8List.fromList([
    ...utf8.encode(kSeedDerivationDomainTag),
    ...encoded,
  ]);
  final digest = await Sha512().hash(input);
  return Uint8List.fromList(digest.bytes.sublist(0, 32));
}
