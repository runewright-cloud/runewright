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
