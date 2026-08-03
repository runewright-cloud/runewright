// SPDX-License-Identifier: GPL-3.0-or-later
//
// proof_wire.dart — reads the confirmed proof wire format.
//
// GOLDEN_VECTORS.md CIRCUIT_IO 7 / CIRCUIT_IO.md CIRCUIT_IO 8 (empirically confirmed in M3.4):
//   [4 bytes BE num_public_inputs][public inputs, 32B each][proof, 32B fields]
// Public inputs are ABI-declaration order: pub *parameters* first
// (T, owner_pubkey, ruleset_version), then the pub return tuple (commitment,
// border_activations[4], dominance_trajectory[tier_max],
// supreme_dominance_flags[tier_max]). Index 1 is owner_pubkey regardless of
// tier, since the tier only changes the length of the trailing arrays.

import 'dart:typed_data';

const _kFieldBytes = 32;
const _kOwnerPubkeyIndex = 1;

int _publicInputCount(Uint8List proofBytes) {
  final view = ByteData.sublistView(proofBytes, 0, 4);
  return view.getUint32(0, Endian.big);
}

/// The raw `[public inputs, 32B each]` slice -- everything this match
/// protocol's ownership challenge binds into the signed digest (see
/// `match_session.dart`'s `buildChallengeDigest`).
Uint8List publicInputsSlice(Uint8List proofBytes) {
  final count = _publicInputCount(proofBytes);
  return Uint8List.sublistView(proofBytes, 4, 4 + count * _kFieldBytes);
}

/// `owner_pubkey` as a "0x"-prefixed hex Field string, read directly out of
/// a proof's public inputs (ABI index 1) -- no parsing of the rest needed.
String ownerPubkeyHexFromProof(Uint8List proofBytes) {
  final count = _publicInputCount(proofBytes);
  if (count <= _kOwnerPubkeyIndex) {
    throw ArgumentError('proof has only $count public inputs, expected > $_kOwnerPubkeyIndex');
  }
  final start = 4 + _kOwnerPubkeyIndex * _kFieldBytes;
  final fieldBytes = Uint8List.sublistView(proofBytes, start, start + _kFieldBytes);
  final hex = fieldBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '0x$hex';
}
