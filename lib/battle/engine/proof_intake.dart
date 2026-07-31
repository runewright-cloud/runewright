// SPDX-License-Identifier: GPL-3.0-or-later
//
// proof_intake.dart — ProofIntake: verify + parse proof public outputs. REAL.
//
// Wraps the existing verifier (lib/ffi/prover.dart verifyProof) and parses
// the typed public outputs from the raw proof bytes. The verifier is injected
// (same ProofVerifier typedef as MatchSession) so this module is testable
// without a real proving backend.
//
// CRS REQUIREMENT (CLAUDE.md bug-avoidance #4): initCrs MUST be called before
// the first verifyAndParse call, even on a pure-verify path. The global CRS
// is not initialised by anything else on that path.
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

import 'package:rune_duel/protocol/match_session.dart' show ProofVerifier;
import 'package:rune_duel/ffi/prover.dart' show initSrsCached;

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

// ── ProofIntake ───────────────────────────────────────────────────────────────

class ProofIntake {
  // ── CRS initialisation (must precede first verify call) ─────────────────

  /// Initialise the SRS/CRS from an on-disk cache. Must be called once before
  /// [verifyAndParse], even on a pure-verify path (CLAUDE.md bug-avoidance #4).
  ///
  /// [circuitBytecode] is the base-64 bytecode string for the tier being
  /// verified (extracted from the bundled circuit JSON via extractBytecode).
  /// [srsCachePath] is the device-local cache file path (path_provider).
  static Future<void> initCrs(
    String circuitBytecode, {
    required String srsCachePath,
  }) =>
      initSrsCached(circuitBytecode, cachePath: srsCachePath);

  // ── Verify + parse ───────────────────────────────────────────────────────

  /// Verify [proofBytes] against [vkBytes] and parse the public outputs.
  ///
  /// [tier] must be the tier agreed in [MatchConfig.tier] (12 / 24 / 48).
  /// It is used directly as tier_max rather than being inferred from the
  /// field count, so this method remains correct if the circuit layout changes.
  ///
  /// Throws [ProofIntakeException] if:
  ///   - The proof fails verification.
  ///   - The field count does not match [tier].
  ///   - Any field is malformed.
  ///
  /// The [verifyProof] function is injected (default: the FFI verifier in
  /// lib/ffi/prover.dart) to keep this module testable without a proving backend.
  static Future<VerifiedSpellOutputs> verifyAndParse(
    Uint8List proofBytes,
    Uint8List vkBytes,
    ProofVerifier verifyProof,
    int tier,
  ) async {
    assert(tier == 12 || tier == 24 || tier == 48, 'tier must be 12, 24, or 48');
    final ok = await verifyProof(vkBytes, proofBytes);
    if (!ok) throw ProofIntakeException('verify_ultra_honk rejected the proof');
    return _parse(proofBytes, tier);
  }

  /// Parse the public outputs of a proof **this device authored**, skipping
  /// verification.
  ///
  /// ONLY valid for locally-created proofs. A peer's proof must always go
  /// through [verifyAndParse] — skipping verification on untrusted bytes would
  /// let a peer hand us arbitrary "public outputs" with no proof behind them.
  ///
  /// Exists so the local and peer wild-magic paths share one derivation:
  /// `VerifiedSpellOutputs → WildMagic.triggersFor` on both sides, producing
  /// identical triggers from identical proof bytes (WILD_MAGIC_PLAN.md §4.6).
  /// Without it the local side would have to re-derive the seed hash from the
  /// wire `SpellAsset`, which is a second derivation path and therefore a
  /// desync waiting to happen.
  ///
  /// Throws [ProofIntakeException] on a malformed proof, exactly like
  /// [verifyAndParse].
  static VerifiedSpellOutputs parseOwn(Uint8List proofBytes, int tier) =>
      _parse(proofBytes, tier);

  // ── Internal parser ──────────────────────────────────────────────────────

  static VerifiedSpellOutputs _parse(Uint8List proofBytes, int tier) {
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
  static int _fieldInt(Uint8List proof, int index) {
    final base = 4 + index * 32;
    var v = 0;
    // The field is big-endian; take the last 8 bytes for small integers.
    for (var i = base + 24; i < base + 32; i++) {
      v = (v << 8) | proof[i];
    }
    return v;
  }

  /// Read the 32-byte field at [index] as a "0x"-prefixed lowercase hex string.
  static String _fieldHex(Uint8List proof, int index) {
    final base = 4 + index * 32;
    final sb = StringBuffer('0x');
    for (var i = base; i < base + 32; i++) {
      sb.write(proof[i].toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }
}
