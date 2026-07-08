// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:rune_duel/battle/engine/proof_intake.dart';

// ── Test helpers ──────────────────────────────────────────────────────────────

Future<bool> _alwaysOk(Uint8List _, Uint8List _) async => true;
Future<bool> _alwaysReject(Uint8List _, Uint8List _) async => false;

/// Build synthetic proof bytes in the canonical wire format:
///   [4 BE bytes: field count N][N × 32-byte fields][1 byte padding]
///
/// Field layout matches CIRCUIT_IO.md §8:
///   [0] T (set to [t])
///   [1] owner_pubkey (zero)
///   [2] ruleset_version (= 2)
///   [3] commitment (zero)
///   [4..7] border_activations (zero)
///   [8..8+tier-1] dominance_trajectory (zero)
///   [8+tier..8+2*tier-1] supreme_dominance_flags (zero)
Uint8List _syntheticProof(int tier, {int t = 1}) {
  final count = 8 + 2 * tier;
  // header (4) + fields (count*32) + 1 byte proof body
  final bytes = Uint8List(4 + count * 32 + 1);
  final data = ByteData.sublistView(bytes);

  // Field count header.
  data.setUint32(0, count, Endian.big);

  // Field 0: T — written into the last 4 bytes of the 32-byte field.
  data.setUint32(4 + 0 * 32 + 28, t, Endian.big);

  // Field 2: ruleset_version = 2.
  data.setUint32(4 + 2 * 32 + 28, 2, Endian.big);

  // All other fields (commitment, border counts, trajectory, flags): zero.
  return bytes;
}

/// Build a synthetic proof whose field count does NOT match the given tier.
Uint8List _proofWithWrongCount(int tier) {
  // Use a different tier's count.
  final wrongTier = tier == 12 ? 24 : 12;
  return _syntheticProof(wrongTier, t: 1);
}

void main() {
  group('ProofIntake.verifyAndParse — tier parameter', () {
    // ── Correct tier produces correct tierMax ─────────────────────────────

    test('tier 12 → tierMax = 12', () async {
      final proof = _syntheticProof(12, t: 1);
      final out = await ProofIntake.verifyAndParse(proof, Uint8List(0), _alwaysOk, 12);
      expect(out.tierMax, equals(12));
      expect(out.t, equals(1));
      expect(out.rulesetVersion, equals(2));
      expect(out.dominanceTrajectory.length, equals(12));
      expect(out.supremeDominanceFlags.length, equals(12));
    });

    test('tier 24 → tierMax = 24', () async {
      final proof = _syntheticProof(24, t: 3);
      final out = await ProofIntake.verifyAndParse(proof, Uint8List(0), _alwaysOk, 24);
      expect(out.tierMax, equals(24));
      expect(out.t, equals(3));
      expect(out.dominanceTrajectory.length, equals(24));
      expect(out.supremeDominanceFlags.length, equals(24));
    });

    test('tier 48 → tierMax = 48', () async {
      final proof = _syntheticProof(48, t: 7);
      final out = await ProofIntake.verifyAndParse(proof, Uint8List(0), _alwaysOk, 48);
      expect(out.tierMax, equals(48));
      expect(out.t, equals(7));
      expect(out.dominanceTrajectory.length, equals(48));
      expect(out.supremeDominanceFlags.length, equals(48));
    });

    // ── T = tier_max is the maximum valid T ───────────────────────────────

    test('T = tierMax is valid (boundary)', () async {
      final proof = _syntheticProof(12, t: 12);
      final out = await ProofIntake.verifyAndParse(proof, Uint8List(0), _alwaysOk, 12);
      expect(out.t, equals(12));
    });

    // ── Verifier rejection surfaces as ProofIntakeException ───────────────

    test('rejected proof throws ProofIntakeException', () async {
      final proof = _syntheticProof(24, t: 1);
      expect(
        () => ProofIntake.verifyAndParse(proof, Uint8List(0), _alwaysReject, 24),
        throwsA(isA<ProofIntakeException>()),
      );
    });

    // ── Field count mismatch surfaces as typed error, not crash ───────────

    test('wrong field count for declared tier throws ProofIntakeException', () async {
      final proof = _proofWithWrongCount(24); // count for tier=12, declared tier=24
      expect(
        () => ProofIntake.verifyAndParse(proof, Uint8List(0), _alwaysOk, 24),
        throwsA(isA<ProofIntakeException>()),
      );
    });

    test('wrong field count message names the mismatch', () async {
      final proof = _proofWithWrongCount(48); // count for tier=12
      try {
        await ProofIntake.verifyAndParse(proof, Uint8List(0), _alwaysOk, 48);
        fail('expected ProofIntakeException');
      } on ProofIntakeException catch (e) {
        expect(e.reason, contains('48'));   // declared tier mentioned
        expect(e.reason, contains('104')); // expected count for tier 48
      }
    });

    // ── T out of range surfaces as typed error ─────────────────────────────

    test('T = 0 throws ProofIntakeException (circuit invariant: T ≥ 1)', () async {
      final proof = _syntheticProof(24, t: 0);
      expect(
        () => ProofIntake.verifyAndParse(proof, Uint8List(0), _alwaysOk, 24),
        throwsA(isA<ProofIntakeException>()),
      );
    });

    test('T > tierMax throws ProofIntakeException', () async {
      // Synthetic proof for tier 12 with T = 13 (out of range).
      final proof = _syntheticProof(12, t: 13);
      expect(
        () => ProofIntake.verifyAndParse(proof, Uint8List(0), _alwaysOk, 12),
        throwsA(isA<ProofIntakeException>()),
      );
    });
  });
}
