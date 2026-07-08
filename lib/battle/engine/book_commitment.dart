// SPDX-License-Identifier: GPL-3.0-or-later
//
// book_commitment.dart — BookCommitment: Merkle-root over a Chapter.
//
// Each player commits to their Chapter's spell set at session start by sending
// a Merkle root over their spells' commitmentHex values (BATTLE_PROTOCOL.md §5).
// Individual spell membership can then be proven without revealing the full chapter.
//
// Hash function: SHA-256(left ‖ right) for interior nodes (32 bytes each side).
// Leaves: 32-byte big-endian field values decoded from commitmentHex strings.
// Leaf order: sorted lexicographically by commitmentHex string before building the tree.
// Odd-length levels: right-pad with a 32-byte zero node.
//
// Option 2 batch hash: SHA-256(leaf₁ ‖ leaf₂ ‖ … ‖ leafₙ) over the sorted leaf
// bytes, committed at session start alongside the Merkle root and verified against
// the full sorted commitmentHex list at post-match reveal.

import 'dart:typed_data';

import 'package:crypto/crypto.dart';

// ── Membership proof ──────────────────────────────────────────────────────────

/// A Merkle path proving that [leafHex] is in the tree rooted at [root].
class MembershipProof {
  const MembershipProof({
    required this.root,
    required this.leafHex,
    required this.siblings,
    required this.directions,
  }) : assert(siblings.length == directions.length);

  /// The Merkle root this proof is against (hex string).
  final String root;

  /// The spell's commitmentHex (the leaf being proven).
  final String leafHex;

  /// Merkle sibling hashes along the path from leaf to root.
  final List<String> siblings;

  /// true = sibling is on the right (we hash current ‖ sibling).
  /// false = sibling is on the left (we hash sibling ‖ current).
  final List<bool> directions;

  /// Recompute the path from [leafHex] and verify it reaches [root].
  bool verify() {
    var current = BookCommitment._leafBytes(leafHex);
    for (var i = 0; i < siblings.length; i++) {
      final sibling = BookCommitment._leafBytes(siblings[i]);
      final pair = Uint8List(64);
      if (directions[i]) {
        pair.setRange(0, 32, current);
        pair.setRange(32, 64, sibling);
      } else {
        pair.setRange(0, 32, sibling);
        pair.setRange(32, 64, current);
      }
      current = Uint8List.fromList(sha256.convert(pair).bytes);
    }
    return BookCommitment._encodeHex(current) == root;
  }
}

// ── BookCommitment ────────────────────────────────────────────────────────────

class BookCommitment {
  static const _zeroRoot =
      '0x0000000000000000000000000000000000000000000000000000000000000000';
  static final _zeroNode = Uint8List(32);

  // ── Internal helpers ────────────────────────────────────────────────────────

  static Uint8List _leafBytes(String hex) {
    final s = hex.startsWith('0x') ? hex.substring(2) : hex;
    final out = Uint8List(32);
    for (var i = 0; i < 32 && i * 2 + 1 < s.length; i++) {
      out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }

  static String _encodeHex(Uint8List bytes) =>
      '0x${bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';

  static Uint8List _hashPair(Uint8List left, Uint8List right) {
    final pair = Uint8List(64)
      ..setRange(0, 32, left)
      ..setRange(32, 64, right);
    return Uint8List.fromList(sha256.convert(pair).bytes);
  }

  // ── Public API ──────────────────────────────────────────────────────────────

  /// Compute the Merkle root over [commitmentHexes].
  ///
  /// Leaves are sorted lexicographically before building the tree. Caller
  /// does not need to pre-sort. Returns [_zeroRoot] for an empty list.
  static String computeRoot(List<String> commitmentHexes) {
    if (commitmentHexes.isEmpty) return _zeroRoot;
    final sorted = List<String>.from(commitmentHexes)..sort();
    var level = sorted.map(_leafBytes).toList();
    while (level.length > 1) {
      final next = <Uint8List>[];
      for (var i = 0; i < level.length; i += 2) {
        final right = i + 1 < level.length ? level[i + 1] : _zeroNode;
        next.add(_hashPair(level[i], right));
      }
      level = next;
    }
    return _encodeHex(level.first);
  }

  /// SHA-256 over the sorted concatenated leaf bytes — the Option 2 batch hash.
  ///
  /// Both players exchange this alongside the Merkle root at session start.
  /// At post-match reveal, the receiver recomputes this over the revealed list
  /// and checks it matches. Guarantees the reveal cannot be retroactively
  /// altered to hide duplicate entries.
  static Uint8List hashLeaves(List<String> commitmentHexes) {
    final sorted = List<String>.from(commitmentHexes)..sort();
    final buf = BytesBuilder();
    for (final hex in sorted) {
      buf.add(_leafBytes(hex));
    }
    return Uint8List.fromList(sha256.convert(buf.toBytes()).bytes);
  }

  /// Prove that [leafHex] is a member of the Merkle tree over [commitmentHexes].
  ///
  /// Returns null if [leafHex] is not present in [commitmentHexes].
  static MembershipProof? proveMembership(
    List<String> commitmentHexes,
    String leafHex,
  ) {
    final sorted = List<String>.from(commitmentHexes)..sort();
    var idx = sorted.indexOf(leafHex);
    if (idx < 0) return null;

    var level = sorted.map(_leafBytes).toList();
    final siblings = <String>[];
    final directions = <bool>[];

    while (level.length > 1) {
      final siblingIdx = idx.isEven ? idx + 1 : idx - 1;
      final siblingNode =
          siblingIdx < level.length ? level[siblingIdx] : _zeroNode;
      siblings.add(_encodeHex(siblingNode));
      // isEven → we are the left child; sibling is on the right.
      directions.add(idx.isEven);

      final next = <Uint8List>[];
      for (var i = 0; i < level.length; i += 2) {
        final right = i + 1 < level.length ? level[i + 1] : _zeroNode;
        next.add(_hashPair(level[i], right));
      }
      level = next;
      idx ~/= 2;
    }

    return MembershipProof(
      root: _encodeHex(level.first),
      leafHex: leafHex,
      siblings: siblings,
      directions: directions,
    );
  }

  /// Encode a root for sending over the wire (32 raw bytes, big-endian).
  static Uint8List rootToBytes(String rootHex) {
    final hex = rootHex.startsWith('0x') ? rootHex.substring(2) : rootHex;
    final bytes = Uint8List(32);
    for (var i = 0; i < 32 && i * 2 + 1 < hex.length; i++) {
      bytes[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return bytes;
  }
}
