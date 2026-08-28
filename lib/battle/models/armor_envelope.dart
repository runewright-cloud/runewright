// SPDX-License-Identifier: GPL-3.0-or-later
//
// armor_envelope.dart — the armorLoadout (0x1F) setup frame's payload: what
// one player publicly declares they are wearing.
//
// ## The whole design is what is NOT in here
//
// An armor's properties are derived from its proof, on both devices, through
// `CertifiedArmor.fromOutputs`. So this envelope carries the proof and nothing
// a peer could assert about it. Deliberately absent, and never to be added:
// `isArmor`, the authored formula, mana cost, supreme tags, element counts,
// stat bonuses, keywords, slot cost, and T-as-semantics. Every one of those is
// recomputed from the verified public outputs; a field here would be a second,
// unbound source for a fact the proof already settles — the exact shape of the
// M4.22 desync.
//
// [tier] is the one exception and it is ROUTING metadata, not semantics: the
// verifier must pick a VK and a public-input layout BEFORE the proof's own T
// can be read (the field count is `10 + 2*tier_max`, so the trajectory arrays
// sit at tier-dependent offsets). A lie here cannot buy anything: the receiver
// accepts only canonical inscription tiers, and after parsing re-derives the
// tier from the certified T and requires it to match what was declared. See
// armor_certification.dart.
//
// Wire form — UTF-8 JSON, one object, `armor: null` for "wearing none":
//
//   {"armor": null}
//   {"armor": {"tier": 12, "proofB64": "<base64 proof bytes>"}}
//
// The frame is sent on EVERY duel, armor or not. A conditional frame would let
// two peers sit in different handshake states, each waiting for the other.

import 'dart:convert';
import 'dart:typed_data';

/// One player's declared armor: [proofBytes] plus the [tier] needed to route
/// verification, or `null` (the absent envelope) for "no armor equipped".
class ArmorEnvelope {
  const ArmorEnvelope({required this.tier, required this.proofBytes});

  /// Declared circuit tier (12 / 24 / 48). Routing only — see the file header.
  final int tier;

  /// The raw proof, opaque here: this class never parses it.
  final Uint8List proofBytes;

  Map<String, dynamic> toJson() => {
        'tier': tier,
        'proofB64': base64Encode(proofBytes),
      };

  static ArmorEnvelope fromJson(Map<String, dynamic> json) => ArmorEnvelope(
        tier: json['tier'] as int,
        proofBytes: base64Decode(json['proofB64'] as String),
      );

  /// Encodes [armor] (or its absence) as the frame payload.
  static Uint8List encode(ArmorEnvelope? armor) => Uint8List.fromList(
        utf8.encode(jsonEncode({'armor': armor?.toJson()})),
      );

  /// Inverse of [encode]. Throws [FormatException] on anything malformed —
  /// setup treats that as a failed handshake, never as "no armor".
  static ArmorEnvelope? decode(Uint8List payload) {
    final decoded = jsonDecode(utf8.decode(payload));
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('armorLoadout payload is not a JSON object');
    }
    final armor = decoded['armor'];
    if (armor == null) return null;
    if (armor is! Map<String, dynamic>) {
      throw const FormatException('armorLoadout "armor" is neither null nor an object');
    }
    if (armor['tier'] is! int || armor['proofB64'] is! String) {
      throw const FormatException('armorLoadout envelope is missing tier/proofB64');
    }
    return ArmorEnvelope.fromJson(armor);
  }
}
