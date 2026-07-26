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

import 'package:cryptography/cryptography.dart';
import 'package:rune_duel/engine/hex_grid.dart';
import 'package:rune_duel/spells/spell_asset.dart';

class PendingDelayedSpell {
  PendingDelayedSpell({
    required this.id,
    required this.ownerId,
    required this.spell,
    required this.commitment,
    required this.castTurn,
    required this.origin,
    this.isPotent = false,
    this.isVelocity = false,
    this.isRodOfSpreading = false,
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

  /// The caster's board position at the moment of casting (public — only the
  /// target tile and delay are secret, per the commitment above). Used to
  /// render the pulsing "pending cast" orb, and as the true launch origin
  /// when the spell later fires, since the caster may have moved since.
  final HexCoord origin;

  final bool isPotent;
  final bool isVelocity;

  /// Whether the caster asked to spend a Rod of Spreading when this delayed
  /// spell fires (see SpellCastAction.isRodOfSpreading). Realised only if the
  /// caster still owns an unused rod at fire time.
  final bool isRodOfSpreading;

  /// Last turn the spell may fire. After this turn ends, spell is forfeited.
  int get maxTurn => castTurn + 3;

  static String idFromCommitment(Uint8List c) =>
      c.take(16).map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  /// Encodes [h] as 4 bytes: q then r, each signed big-endian 16-bit.
  /// Byte-identical to TurnLoop's private wire coord encoding — kept here too
  /// (rather than only in TurnLoop) so the mystery commitment preimage has a
  /// single canonical implementation shared by the caster's UI (which builds
  /// the commitment before the cast is ever sent) and TurnLoop's verification
  /// (which rebuilds it from the revealed target/delay/nonce).
  static Uint8List encodeCoord(HexCoord h) => Uint8List(4)
    ..[0] = (h.q >> 8) & 0xFF
    ..[1] = h.q & 0xFF
    ..[2] = (h.r >> 8) & 0xFF
    ..[3] = h.r & 0xFF;

  static HexCoord decodeCoord(Uint8List data, int offset) {
    int readInt16(int at) {
      final u = (data[at] << 8) | data[at + 1];
      return u >= 0x8000 ? u - 0x10000 : u;
    }

    return HexCoord(readInt16(offset), readInt16(offset + 2));
  }

  /// The mystery commitment preimage: encodeCoord(target) ‖ delay_byte ‖ nonce.
  static Uint8List commitmentPreimage({
    required HexCoord target,
    required int delay,
    required Uint8List nonce,
  }) =>
      Uint8List.fromList([...encodeCoord(target), delay & 0xFF, ...nonce]);

  /// SHA-256 of [commitmentPreimage] — the value hidden inside a Mystery cast
  /// until it's revealed. See the file header's wire contract.
  static Future<Uint8List> commitmentHash({
    required HexCoord target,
    required int delay,
    required Uint8List nonce,
  }) async {
    final hash = await Sha256().hash(
        commitmentPreimage(target: target, delay: delay, nonce: nonce));
    return Uint8List.fromList(hash.bytes);
  }
}
