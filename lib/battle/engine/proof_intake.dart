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

import 'proof_outputs.dart';

import 'package:rune_duel/protocol/match_session.dart' show ProofVerifier;
import 'package:rune_duel/ffi/prover.dart' show initSrsCached;

// The typed outputs, the exception and the pure parser live in
// proof_outputs.dart so a Flutter-free `dart run` build script can reach
// them (M4.22). Re-exported here so every existing importer of this file is
// unaffected and there is still one obvious home for "proof bytes in,
// typed outputs out".
export 'proof_outputs.dart';

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
    return parseProofOutputs(proofBytes, tier);
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
      parseProofOutputs(proofBytes, tier);
}
