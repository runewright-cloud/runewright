// SPDX-License-Identifier: GPL-3.0-or-later
//
// fixtures.dart — shared test fixtures for the protocol suite, used by both
// the in-memory and real-socket variants (match_session_suite.dart) so the
// exact same test bodies run over both transports.

import 'dart:typed_data';

/// Builds a synthetic tier-12-shaped proof in the confirmed wire format
/// (GOLDEN_VECTORS.md CIRCUIT_IO 7): `[4B BE count][public inputs, 32B each][proof
/// fields]`. ABI order: T, owner_pubkey, ruleset_version, commitment,
/// border_activations[4], dominance_trajectory[12], supreme_flags[12] = 32
/// public inputs. Only `owner_pubkey` (index 1) matters to these tests; the
/// rest are zero-filled, and the trailing "proof fields" are dummy bytes --
/// proof *cryptographic* validity is exercised elsewhere (`verifyProof` is
/// injected as a fake here, by design, so these tests isolate protocol
/// logic from SNARK proving/verification cost).
Uint8List buildFakeProof(String ownerPubkeyHex) {
  const numPublicInputs = 32;
  final out = BytesBuilder();
  final countBytes = ByteData(4)..setUint32(0, numPublicInputs, Endian.big);
  out.add(countBytes.buffer.asUint8List());

  final ownerPubkeyValue = BigInt.parse(
    ownerPubkeyHex.startsWith('0x') ? ownerPubkeyHex.substring(2) : ownerPubkeyHex,
    radix: 16,
  );
  for (var i = 0; i < numPublicInputs; i++) {
    if (i == 1) {
      out.add(_fieldToBeBytes32(ownerPubkeyValue));
    } else {
      out.add(Uint8List(32));
    }
  }
  out.add(Uint8List(64)); // dummy proof fields, never inspected by these tests
  return out.toBytes();
}

Uint8List _fieldToBeBytes32(BigInt value) {
  final out = Uint8List(32);
  var v = value;
  for (var i = 31; i >= 0; i--) {
    out[i] = (v & BigInt.from(0xff)).toInt();
    v = v >> 8;
  }
  return out;
}

Future<bool> alwaysValid(Uint8List vk, Uint8List proof) async => true;
Future<bool> alwaysInvalid(Uint8List vk, Uint8List proof) async => false;
final dummyVk = Uint8List(0);
