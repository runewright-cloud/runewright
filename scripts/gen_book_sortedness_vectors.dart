// scripts/gen_book_sortedness_vectors.dart — Dart-oracle vectors for the
// sortedness-circuit spike (docs/SORTEDNESS_CIRCUIT_SPIKE.md).
//
// Two-oracle discipline, same as scripts/gen_vectors.dart: the Merkle root
// comes from BookCommitment.computeRoot (the Dart oracle, which is itself
// what session handshakes use in the field) — never hand-computed here or
// re-derived from the circuit. The circuit must reproduce it.
//
// Writes circuits/book_sortedness_n{32,48,64}/Prover.toml (positive vector:
// N honestly-sorted leaves, real root) plus prints the negative-vector
// witnesses (N1 reorder, N2 duplicate, N3 bad padding) to stdout as TOML
// fragments — SORTEDNESS_CIRCUIT_SPIKE.md §6 says these must fail, so they
// are not committed as the crate's checked-in Prover.toml.
//
// Run with: dart run scripts/gen_book_sortedness_vectors.dart

import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:rune_duel/battle/engine/book_commitment.dart';

/// Deterministic leaf `i` (1-indexed): 32 big-endian bytes encoding `i` in the
/// low 4 bytes, zero elsewhere. Already in ascending order as both an integer
/// and — because all leaves share the same 0x + 64-hex-char width — as the
/// lexicographic string BookCommitment.computeRoot sorts by.
String _leafHex(int i) {
  final bytes = Uint8List(32);
  bytes[28] = (i >> 24) & 0xff;
  bytes[29] = (i >> 16) & 0xff;
  bytes[30] = (i >> 8) & 0xff;
  bytes[31] = i & 0xff;
  return '0x${bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
}

/// Split a `0x`-prefixed 64-hex-char leaf into (hi, lo) 16-byte halves, each
/// rendered as a `0x`-prefixed Field literal for Prover.toml — matches the
/// circuit's `leaves_hi[i].to_be_bytes::<16>() ++ leaves_lo[i].to_be_bytes::<16>()`
/// reconstruction.
(String, String) _hiLo(String leafHex) {
  final hex = leafHex.substring(2);
  return ('0x${hex.substring(0, 32)}', '0x${hex.substring(32, 64)}');
}

String _proverToml(List<String> leaves, String root) {
  final his = <String>[];
  final los = <String>[];
  for (final leaf in leaves) {
    final (hi, lo) = _hiLo(leaf);
    his.add('"$hi"');
    los.add('"$lo"');
  }
  final (rootHi, rootLo) = _hiLo(root);
  final buf = StringBuffer();
  buf.writeln('leaves_hi = [${his.join(', ')}]');
  buf.writeln('leaves_lo = [${los.join(', ')}]');
  buf.writeln('root_hi = "$rootHi"');
  buf.writeln('root_lo = "$rootLo"');
  return buf.toString();
}

void main() {
  // ── SS9 pin: smallest possible vector, one interior node ──────────────────
  final leafA = _leafHex(1);
  final leafB = _leafHex(2);
  final root2 = BookCommitment.computeRoot([leafA, leafB]);
  stdout.writeln('-- SHA-256 pin (N=2, one interior node) --');
  stdout.writeln('leafA = $leafA');
  stdout.writeln('leafB = $leafB');
  stdout.writeln('root  = $root2');
  final (pinHi, pinLo) = _hiLo(root2);
  stdout.writeln('root_hi = $pinHi');
  stdout.writeln('root_lo = $pinLo');
  File('circuits/book_sortedness_pin/Prover.toml')
      .writeAsStringSync(_proverToml([leafA, leafB], root2));
  stdout.writeln('wrote circuits/book_sortedness_pin/Prover.toml');
  stdout.writeln();

  // ── Positive vectors: N = 32, 48, 64 ───────────────────────────────────────
  for (final n in [32, 48, 64]) {
    final leaves = List<String>.generate(n, (i) => _leafHex(i + 1));
    final root = BookCommitment.computeRoot(leaves);
    final path = 'circuits/book_sortedness_n$n/Prover.toml';
    File(path).writeAsStringSync(_proverToml(leaves, root));
    stdout.writeln('wrote $path (root=$root)');
  }
  stdout.writeln();

  // ── Negative vectors (not written as Prover.toml — printed for manual
  // nargo execute --prover-name <file> runs; see §6) ─────────────────────────
  final n32Leaves = List<String>.generate(32, (i) => _leafHex(i + 1));

  // N1 — reordered leaves: swap an adjacent pair, root recomputed over THAT
  // (wrong) order, so the leaves as given are no longer ascending.
  final n1Leaves = List<String>.from(n32Leaves);
  final tmp = n1Leaves[10];
  n1Leaves[10] = n1Leaves[11];
  n1Leaves[11] = tmp;
  // Root over the reordered list, as if a malicious prover fed the circuit
  // this order directly and tried to make it match a self-consistent root —
  // sortedness must still reject it because n1Leaves[10] > n1Leaves[11].
  final n1Root = _hashLeavesInGivenOrder(n1Leaves);
  File('/tmp/book_sortedness_neg_n1.toml').writeAsStringSync(_proverToml(n1Leaves, n1Root));
  stdout.writeln('wrote /tmp/book_sortedness_neg_n1.toml (reordered pair, must fail sortedness)');

  // N2 — duplicate leaf: leaf[5] == leaf[6].
  final n2Leaves = List<String>.from(n32Leaves);
  n2Leaves[6] = n2Leaves[5];
  final n2Root = _hashLeavesInGivenOrder(n2Leaves);
  File('/tmp/book_sortedness_neg_n2.toml').writeAsStringSync(_proverToml(n2Leaves, n2Root));
  stdout.writeln('wrote /tmp/book_sortedness_neg_n2.toml (duplicate leaf, must fail strict <)');

  // N3 — bad padding: real, honestly-sorted 48 leaves (48 -> 24 -> 12 -> 6 ->
  // 3 -> 2 -> 1 hits an odd level at the 3->2 step) but the root is computed
  // with a non-zero pad node instead of the 32-byte zero node at that step.
  // Sortedness holds; only the root-reconstruction check must fail.
  final n48Leaves = List<String>.generate(48, (i) => _leafHex(i + 1));
  final n3Root = _hashLeavesBadPadding(n48Leaves);
  File('/tmp/book_sortedness_neg_n3.toml').writeAsStringSync(_proverToml(n48Leaves, n3Root));
  stdout.writeln(
    'wrote /tmp/book_sortedness_neg_n3.toml (non-zero pad node at the 3->2 '
    'odd level, must fail root reconstruction; run against book_sortedness_n48)',
  );
}

/// Hash a leaf list AS GIVEN (no re-sort) using book_commitment.dart's own
/// pairing/padding rules — used only to build negative-vector roots that are
/// internally self-consistent (so the circuit's root-reconstruction check
/// passes) while the sortedness check is what's expected to fail.
String _hashLeavesInGivenOrder(List<String> leavesInOrder) {
  Uint8List leafBytes(String hex) {
    final s = hex.substring(2);
    final out = Uint8List(32);
    for (var i = 0; i < 32; i++) {
      out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }

  Uint8List hashPair(Uint8List l, Uint8List r) {
    final pair = Uint8List(64)
      ..setRange(0, 32, l)
      ..setRange(32, 64, r);
    return Uint8List.fromList(sha256.convert(pair).bytes);
  }

  String encodeHex(Uint8List bytes) =>
      '0x${bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';

  var level = leavesInOrder.map(leafBytes).toList();
  final zero = Uint8List(32);
  while (level.length > 1) {
    final next = <Uint8List>[];
    for (var i = 0; i < level.length; i += 2) {
      final right = i + 1 < level.length ? level[i + 1] : zero;
      next.add(hashPair(level[i], right));
    }
    level = next;
  }
  return encodeHex(level.first);
}

/// Same tree build as [_hashLeavesInGivenOrder], but every odd-length level's
/// unpaired last node is padded with 0xFF-bytes instead of the 32-byte zero
/// node -- an N3 (bad padding) negative vector: sortedness of [sortedLeaves]
/// holds, but a circuit that correctly hard-codes the zero pad node must
/// reject this root as a reconstruction mismatch.
String _hashLeavesBadPadding(List<String> sortedLeaves) {
  Uint8List leafBytes(String hex) {
    final s = hex.substring(2);
    final out = Uint8List(32);
    for (var i = 0; i < 32; i++) {
      out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }

  Uint8List hashPair(Uint8List l, Uint8List r) {
    final pair = Uint8List(64)
      ..setRange(0, 32, l)
      ..setRange(32, 64, r);
    return Uint8List.fromList(sha256.convert(pair).bytes);
  }

  String encodeHex(Uint8List bytes) =>
      '0x${bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';

  var level = sortedLeaves.map(leafBytes).toList();
  final badPad = Uint8List(32)..fillRange(0, 32, 0xFF);
  while (level.length > 1) {
    final next = <Uint8List>[];
    for (var i = 0; i < level.length; i += 2) {
      final right = i + 1 < level.length ? level[i + 1] : badPad;
      next.add(hashPair(level[i], right));
    }
    level = next;
  }
  return encodeHex(level.first);
}
