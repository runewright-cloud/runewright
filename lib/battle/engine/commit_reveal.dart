// SPDX-License-Identifier: GPL-3.0-or-later
//
// commit_reveal.dart — CommitRevealEntropy primitive. REAL, unit-tested.
//
// Fairness spine for all in-battle randomness: spell draws, bookmark
// retargeting, burn targeting, summon-collision resolution.
//
// Protocol (BATTLE_PROTOCOL.md §3):
//   1. Each player generates a 32-byte crypto-secure nonce.
//   2. Both send commit = SHA-256(nonce) simultaneously.
//   3. Both reveal nonces simultaneously.
//   4. Each side verifies SHA-256(peer_nonce) == peer_commit.
//   5. joint_entropy = our_nonce XOR peer_nonce.
//
// A peer who reveals a nonce that doesn't match their commit is treated as
// withholding; the detecting side sends forfeit("withheld_reveal").
// Constant-time equality is used in the verification step to avoid timing
// oracles on the commit comparison.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

class CommitRevealEntropy {
  // ── Commit phase ────────────────────────────────────────────────────────────

  /// Returns SHA-256(nonce) — the 32-byte commitment to send to the peer.
  static Future<Uint8List> commit(Uint8List nonce) async {
    final hash = await Sha256().hash(nonce);
    return Uint8List.fromList(hash.bytes);
  }

  // ── Reveal phase ────────────────────────────────────────────────────────────

  /// Verifies [theirNonce] against [theirCommit], then XORs with [ourNonce]
  /// to produce joint entropy.
  ///
  /// Returns null if the reveal is invalid (withheld or forged nonce) — the
  /// caller should send forfeit("withheld_reveal") and end the match.
  static Future<Uint8List?> revealAndCombine({
    required Uint8List ourNonce,
    required Uint8List theirNonce,
    required Uint8List theirCommit,
  }) async {
    final expected = await commit(theirNonce);
    if (!_constantTimeEqual(expected, theirCommit)) return null;
    return xorBytes(ourNonce, theirNonce);
  }

  // ── Utilities ───────────────────────────────────────────────────────────────

  /// XOR of two equal-length byte arrays. The combine step of the protocol.
  static Uint8List xorBytes(Uint8List a, Uint8List b) {
    assert(a.length == b.length, 'xorBytes: length mismatch ${a.length} vs ${b.length}');
    final out = Uint8List(a.length);
    for (var i = 0; i < a.length; i++) {
      out[i] = a[i] ^ b[i];
    }
    return out;
  }

  /// Generates a cryptographically secure 32-byte nonce.
  static Uint8List generateNonce() {
    final rng = math.Random.secure();
    return Uint8List.fromList(List.generate(32, (_) => rng.nextInt(256)));
  }

  // ── Internal ─────────────────────────────────────────────────────────────────

  /// Constant-time equality check to avoid timing side-channels on commit
  /// comparison.
  static bool _constantTimeEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }
}
