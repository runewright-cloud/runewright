// SPDX-License-Identifier: GPL-3.0-or-later
//
// proof_outputs.dart — the proof public-output ABI: the typed outputs and the
// pure parser that reads them out of raw proof bytes.
//
// Split out of proof_intake.dart (M4.22) for one reason: proof_intake reaches
// `ProofVerifier` and `initSrsCached`, and therefore Flutter, and therefore
// `dart:ui`. Everything in THIS file is `dart:typed_data` and arithmetic, so a
// plain `dart run` build script can use it — which is what lets
// `scripts/export_basic_spells.dart` validate an asset's authored metadata
// against its own proof before shipping it (see spell_asset_integrity.dart).
//
// There is still exactly ONE parser. `proof_intake.dart` re-exports this file,
// so every existing `import 'proof_intake.dart'` keeps working unchanged and
// [ProofIntake.parseOwn] / [ProofIntake.verifyAndParse] both delegate here.
// Do not add a second reader of these bytes — the ABI offsets below are the
// single place that knows the layout.
//
// Wire format (confirmed M3.4, proof_wire.dart, CIRCUIT_IO.md §8):
//   [4 BE bytes: field count N][N × 32-byte fields][proof bytes]
//
// ABI field order (parameters first, then return tuple):
//   [0]       T                    active generation count
//   [1]       owner_pubkey         Poseidon2(key_hi, key_lo)
//   [2]       ruleset_version      currently 3 (RULESET_VERSION 3+)
//   [3]       commitment           Poseidon2(packed_grid) — opaque, never recompute
//   [4..7]    border_activations   [fire=0, air=1, water=2, earth=3]
//   [8..8+M-1]         dominance_trajectory[M]     M = tier_max
//   [8+M..8+2M-1]      supreme_dominance_flags[M]
//   [8+2M]             segment_count  (RULESET_VERSION 3+)
//   [8+2M+1]           dot_count      (RULESET_VERSION 3+)
//
//   Total N = 10 + 2*tier_max.  tier_max is sourced from MatchConfig.tier
//   (established during the match handshake), NOT inferred from array length.
//   This decouples intake from future circuit layout changes (e.g. packing
//   supreme_dominance_flags into a bitmask would change N without changing tier).

import 'dart:typed_data';

// ── Typed public outputs ──────────────────────────────────────────────────────

class VerifiedSpellOutputs {
  const VerifiedSpellOutputs({
    required this.proofBytes,
    required this.t,
    required this.ownerPubkeyHex,
    required this.rulesetVersion,
    required this.commitmentHex,
    required this.tierMax,
    required this.borderActivations,
    required this.dominanceTrajectory,
    required this.supremeDominanceFlags,
    required this.segmentCount,
    required this.dotCount,
  });

  /// The raw proof bytes that produced these outputs (kept for re-verification
  /// or forwarding; treat as opaque).
  final Uint8List proofBytes;

  /// Active generation count. 1 ≤ t ≤ tierMax.
  final int t;

  /// `owner_pubkey` as a "0x"-prefixed hex Field string (CIRCUIT_IO.md §5).
  final String ownerPubkeyHex;

  /// Ruleset epoch; currently 3 (CIRCUIT_IO.md §6).
  final int rulesetVersion;

  /// Grid commitment hex (Poseidon2 over packed grid). Opaque on the Dart
  /// side — never recompute (CLAUDE.md hard invariant 1).
  final String commitmentHex;

  /// Circuit tier (12 / 24 / 48), sourced from MatchConfig.tier.
  final int tierMax;

  /// Per-element raw border activation totals over generations 0..t-1.
  /// Indexed [fire=0, air=1, water=2, earth=3] (CIRCUIT_IO.md §1).
  final List<int> borderActivations;

  /// Dominant element index per generation, length = tierMax.
  /// 0 = neutral, 1 = fire, 2 = air, 3 = water, 4 = earth.
  /// Entries for gen ≥ t are 0 (masked, CIRCUIT_IO.md §7).
  final List<int> dominanceTrajectory;

  /// Supreme-dominance flags, 0 or 1, per generation, length = tierMax.
  /// Entries for gen ≥ t are 0 (masked).
  final List<int> supremeDominanceFlags;

  /// T=0 geometry — pure functions of grid_state (RULESET_VERSION 3+).
  /// segmentCount: maximal runs of ≥2 contiguous inscribable active cells
  ///   per hex axis, summed across 3 axes.
  /// dotCount: inscribable active cells with zero inscribable active neighbours.
  /// Used to verify the spell's mana cost in battle (5×seg + dot is the base).
  final int segmentCount;
  final int dotCount;
}

// ── Exception ─────────────────────────────────────────────────────────────────

class ProofIntakeException implements Exception {
  ProofIntakeException(this.reason);
  final String reason;
  @override
  String toString() => 'ProofIntakeException: $reason';
}

/// Parse the public outputs of a proof already known to be trustworthy.
///
/// [tier] is used directly as `tier_max`; it is never inferred from the field
/// count, so this stays correct if the circuit layout changes. Getting it wrong
/// reads the trajectory arrays at the wrong offsets — which is why callers
/// resolve it from T rather than from a wire-declared field.
///
/// Throws [ProofIntakeException] on a malformed proof. Verification is the
/// CALLER's job: [ProofIntake.verifyAndParse] does it for a peer's bytes,
/// [ProofIntake.parseOwn] deliberately does not for our own.
VerifiedSpellOutputs parseProofOutputs(Uint8List proofBytes, int tier) {
  if (proofBytes.length < 4) {
    throw ProofIntakeException('proof too short to contain field count');
  }
  final count = ByteData.sublistView(proofBytes, 0, 4).getUint32(0, Endian.big);

  // Validate field count against the declared tier; do not infer tier from count.
  // RULESET_VERSION 3 adds segment_count + dot_count: N = 10 + 2*tier.
  final expectedCount = 10 + 2 * tier;
  if (count != expectedCount) {
    throw ProofIntakeException(
      'proof field count $count does not match tier $tier (expected $expectedCount)',
    );
  }
  final tierMax = tier;

  if (proofBytes.length < 4 + count * 32) {
    throw ProofIntakeException('proof bytes too short for $count fields');
  }

  final t = _fieldInt(proofBytes, 0);
  final ownerPubkeyHex = _fieldHex(proofBytes, 1);
  final rulesetVersion = _fieldInt(proofBytes, 2);
  final commitmentHex = _fieldHex(proofBytes, 3);
  final borderActivations = List.generate(4, (i) => _fieldInt(proofBytes, 4 + i));
  final dominanceTrajectory = List.generate(tierMax, (i) => _fieldInt(proofBytes, 8 + i));
  final supremeDominanceFlags = List.generate(tierMax, (i) => _fieldInt(proofBytes, 8 + tierMax + i));
  final segmentCount = _fieldInt(proofBytes, 8 + 2 * tierMax);
  final dotCount = _fieldInt(proofBytes, 8 + 2 * tierMax + 1);

  if (t < 1 || t > tierMax) {
    throw ProofIntakeException('T=$t out of range for tier_max=$tierMax');
  }

  return VerifiedSpellOutputs(
    proofBytes: proofBytes,
    t: t,
    ownerPubkeyHex: ownerPubkeyHex,
    rulesetVersion: rulesetVersion,
    commitmentHex: commitmentHex,
    tierMax: tierMax,
    borderActivations: borderActivations,
    dominanceTrajectory: dominanceTrajectory,
    supremeDominanceFlags: supremeDominanceFlags,
    segmentCount: segmentCount,
    dotCount: dotCount,
  );
}

/// Read the 32-byte field at [index] as a small integer (low 8 bytes, BE).
///
/// Safe for values < 2^53 (T, rulesetVersion, border counts, trajectory
/// entries, flags). For commitment and owner_pubkey use [_fieldHex].
int _fieldInt(Uint8List proof, int index) {
  final base = 4 + index * 32;
  var v = 0;
  // The field is big-endian; take the last 8 bytes for small integers.
  for (var i = base + 24; i < base + 32; i++) {
    v = (v << 8) | proof[i];
  }
  return v;
}

/// Read the 32-byte field at [index] as a "0x"-prefixed lowercase hex string.
String _fieldHex(Uint8List proof, int index) {
  final base = 4 + index * 32;
  final sb = StringBuffer('0x');
  for (var i = base; i < base + 32; i++) {
    sb.write(proof[i].toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}
