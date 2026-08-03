// SPDX-License-Identifier: GPL-3.0-or-later
//
// divination_link.dart — DivinationLink: caster→target binding for Divination
// (Air-Water) effects that grant one player standing knowledge of another's
// hidden information.
//
// Mirrors reflection_link.dart's shape. Both flavors are wired to an actual
// reveal mechanism: Air (Airy Scrying Pool — "see target's committed spell
// target tile", MESH_ARCHITECTURE.md §13b, TurnLoop.beginTurn) and Water
// (Watery Scrying Pool — "see target's current hand",
// TurnLoop._exchangeSpellRevealOpenings, SPELL_DRAW_WIRING_PLAN.md §8).
// Link creation for both lives in effect_applicator.dart's _applyDivination.

import 'dart:typed_data';

/// Which reveal mechanism a [DivinationLink] drives.
///
///   targetTile — Air flavor: [casterId] learns [targetId]'s committed spell
///                target tile each turn (MESH_ARCHITECTURE.md §13b).
///   spellList  — Water flavor: [casterId] learns [targetId]'s current HAND
///                each turn (not their whole chapter — SPELL_DRAW_WIRING_
///                PLAN.md §8), each card individually verified against
///                [targetId]'s already-exchanged `peerBookRoot` (see
///                TurnLoop._exchangeSpellRevealOpenings).
enum DivinationFlavor { targetTile, spellList }

class DivinationLink {
  DivinationLink({
    required this.id,
    required this.casterId,
    required this.targetId,
    required this.remainingTurns,
    required this.flavor,
  });

  final String id;

  /// The scryer — the player who receives the reveal.
  final String casterId;

  /// The player whose committed spell target is revealed to [casterId].
  final String targetId;

  int remainingTurns;

  final DivinationFlavor flavor;

  // ── Canonical serialisation ───────────────────────────────────────────────

  void writeToBytes(BytesBuilder buf) {
    _writeUtf8(buf, id);
    _writeUtf8(buf, casterId);
    _writeUtf8(buf, targetId);
    buf.addByte(remainingTurns & 0xFF);
    buf.addByte(flavor.index);
  }

  static void _writeUtf8(BytesBuilder buf, String s) {
    final bytes = s.codeUnits.map((c) => c & 0xFF).toList();
    buf.addByte(bytes.length);
    buf.add(bytes);
  }
}
