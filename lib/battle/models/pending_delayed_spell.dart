// SPDX-License-Identifier: GPL-3.0-or-later
//
// pending_delayed_spell.dart — a mystery-enhanced spell waiting to fire.
//
// Both clients hold the same public fields once the caster's action is revealed.
// Target tile and delay are hidden inside [commitment] until the caster opens
// it on the committed firing turn, or the spell expires at castTurn + 3.
//
// Commitment wire contract:
//   SHA-256(encodeCoord(targetTile) ‖ delay_byte ‖ nonce_16)
//   - encodeCoord: 4 bytes, q then r, each signed big-endian 16-bit
//   - delay_byte:  1 byte, value 0–3 (0 = fire same turn as cast)
//   - nonce:      16 crypto-random bytes

import 'dart:typed_data';

import 'package:rune_duel/spells/spell_asset.dart';

class PendingDelayedSpell {
  PendingDelayedSpell({
    required this.id,
    required this.ownerId,
    required this.spell,
    required this.commitment,
    required this.castTurn,
    this.isPotent = false,
    this.isVelocity = false,
  });

  /// Unique identifier: hex of the first 16 bytes of [commitment].
  final String id;

  /// Player who cast the spell.
  final String ownerId;

  /// Full spell asset — formula, ZK commitment hex, tier — all public.
  final SpellAsset spell;

  /// SHA-256(targetBytes ‖ delay ‖ nonce). 32 bytes.
  final Uint8List commitment;

  /// Turn number on which the spell was cast (public).
  final int castTurn;

  final bool isPotent;
  final bool isVelocity;

  /// Last turn the spell may fire. After this turn ends, spell is forfeited.
  int get maxTurn => castTurn + 3;

  static String idFromCommitment(Uint8List c) =>
      c.take(16).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
