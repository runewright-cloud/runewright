// SPDX-License-Identifier: GPL-3.0-or-later
//
// key_packing.dart — Ed25519 pubkey -> key_hi/key_lo Field split.
//
// CIRCUIT_IO.md CIRCUIT_IO 5: a 256-bit Ed25519 public key doesn't fit in one
// BN254 field, so it's split into two 16-byte halves and bound as
// `owner_pubkey = Poseidon2(key_hi, key_lo)`.
//
// Convention (closes the CIRCUIT_IO.md CIRCUIT_IO 5 `[CONFIRM vs
// stepper/client]` flag): `key_hi` = first 16 bytes of the 32-byte public
// key, `key_lo` = last 16 bytes; each half's raw bytes are interpreted as a
// little-endian integer to produce the Field value. This is confirmed to be
// a *pure client-side convention* with zero circuit-side byte-order
// assumption -- `circuits/ca_v2_4_tier12/src/main.nr`'s only constraint on
// key_hi/key_lo is `owner_pubkey == poseidon2_hash2(key_hi, key_lo)` over
// whatever two field values it's handed (see plan amendment 2). A future
// platform with a different native Ed25519 byte order needs only match this
// function, never the circuit or the VK.

import 'dart:typed_data';

/// Splits a 32-byte Ed25519 public key into `(keyHiHex, keyLoHex)`,
/// "0x"-prefixed hex Field strings ready for the prover/identity FFI calls.
({String keyHiHex, String keyLoHex}) splitPubkeyToFieldHex(
  List<int> publicKeyBytes,
) {
  if (publicKeyBytes.length != 32) {
    throw ArgumentError(
      'Ed25519 public key must be 32 bytes, got ${publicKeyBytes.length}',
    );
  }
  final hiBytes = publicKeyBytes.sublist(0, 16);
  final loBytes = publicKeyBytes.sublist(16, 32);
  return (
    keyHiHex: _leBytesToFieldHex(hiBytes),
    keyLoHex: _leBytesToFieldHex(loBytes),
  );
}

/// Interprets [bytes] as a little-endian unsigned integer and returns it as
/// a "0x"-prefixed big-endian hex string (the Field encoding `from_hex`
/// expects on the Rust/circuit side).
String _leBytesToFieldHex(List<int> bytes) {
  var value = BigInt.zero;
  for (var i = bytes.length - 1; i >= 0; i--) {
    value = (value << 8) | BigInt.from(bytes[i] & 0xff);
  }
  return '0x${value.toRadixString(16)}';
}

/// Inverse of [_leBytesToFieldHex], for tests: decodes a hex Field string
/// back into [byteLength] little-endian bytes.
Uint8List fieldHexToLeBytes(String hex, int byteLength) {
  var value = BigInt.parse(hex.startsWith('0x') ? hex.substring(2) : hex, radix: 16);
  final out = Uint8List(byteLength);
  final mask = BigInt.from(0xff);
  for (var i = 0; i < byteLength; i++) {
    out[i] = (value & mask).toInt();
    value = value >> 8;
  }
  return out;
}

// ── Canonical ordering of two identities ──────────────────────────────────────
//
// Any point where two players' deterministic effects must be SERIALIZED needs
// an order both devices compute identically, with no notion of which side is
// local, host, or initiator. The owner_pubkey is the only identity both
// devices provably share (it comes out of `exchangeIdentityAuth`), so it is
// what the order is derived from.
//
// It has to be compared as BYTES, not as the hex string it is carried in.
// [_leBytesToFieldHex] emits `toRadixString(16)` with no zero padding, so the
// same key can legitimately appear as "0x2" on one path and "0x02" on another,
// and a shorter string can hold a larger number ("0x2" > "0x10" as text, but
// 2 < 16 as a value). Decoding to a fixed-width big-endian form makes
// lexicographic byte order and unsigned numeric order the same thing — which
// is also what duel_battle_setup.dart's BigInt spawn ordering already means,
// so this introduces no second, conflicting notion of "lower player".

/// Width of the canonical big-endian form two identities are compared in.
/// 32 bytes holds any BN254 field element, which is what an owner_pubkey is.
const int kCanonicalPubkeyByteWidth = 32;

/// Canonical big-endian bytes of an owner_pubkey hex: "0x"-prefix optional,
/// case-insensitive, leading zeros irrelevant, always [width] bytes long.
///
/// A value that cannot be read as hex at all — the empty string
/// (`AuthenticatedPeer.none`) or a solo/test sentinel — canonicalizes to all
/// zeroes rather than throwing. Ordering runs inside a live turn, where a
/// throw would drop the match; callers that care about identity validity
/// check it at authentication time, which is where that belongs.
Uint8List canonicalPubkeyBytes(
  String ownerPubkeyHex, {
  int width = kCanonicalPubkeyByteWidth,
}) =>
    _bigIntToBeBytes(_parsePubkeyHex(ownerPubkeyHex), width);

/// Compares two owner_pubkey hexes in ascending canonical byte order.
/// Returns <0 if [a] sorts first, >0 if [b] does, 0 if they are the same key.
///
/// Both are decoded to a common width first, so the comparison is a true
/// lexicographic byte comparison and never depends on how either side chose
/// to spell the key.
int compareCanonicalPubkeyHex(String a, String b) {
  final va = _parsePubkeyHex(a);
  final vb = _parsePubkeyHex(b);
  final width = [
    kCanonicalPubkeyByteWidth,
    _byteWidthOf(va),
    _byteWidthOf(vb),
  ].reduce((x, y) => x > y ? x : y);
  final ba = _bigIntToBeBytes(va, width);
  final bb = _bigIntToBeBytes(vb, width);
  for (var i = 0; i < width; i++) {
    if (ba[i] != bb[i]) return ba[i] < bb[i] ? -1 : 1;
  }
  return 0;
}

BigInt _parsePubkeyHex(String hex) {
  var s = hex.trim();
  if (s.startsWith('0x') || s.startsWith('0X')) s = s.substring(2);
  if (s.isEmpty) return BigInt.zero;
  return BigInt.tryParse(s, radix: 16) ?? BigInt.zero;
}

int _byteWidthOf(BigInt value) => (value.bitLength + 7) ~/ 8;

Uint8List _bigIntToBeBytes(BigInt value, int width) {
  final out = Uint8List(width);
  var v = value;
  final mask = BigInt.from(0xff);
  for (var i = width - 1; i >= 0 && v > BigInt.zero; i--) {
    out[i] = (v & mask).toInt();
    v = v >> 8;
  }
  return out;
}
