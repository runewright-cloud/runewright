// SPDX-License-Identifier: GPL-3.0-or-later
//
// divination_link.dart — DivinationLink: caster→target binding for Divination
// (Air-Water) effects that grant one player standing knowledge of another's
// hidden information.
//
// Mirrors reflection_link.dart's shape. Only the Air flavor (Airy Scrying
// Pool — "see target's committed spell target tile") is wired to an actual
// reveal mechanism today (see MESH_ARCHITECTURE.md §13b, TurnLoop.beginTurn).
// Fire/Water flavors still create no link (unchanged stub behaviour) — their
// reveal mechanisms (counter-charm alignment; available spell list, which
// needs SpellDraw wired into BattleState first) are separate follow-up work.

import 'dart:typed_data';

class DivinationLink {
  DivinationLink({
    required this.id,
    required this.casterId,
    required this.targetId,
    required this.remainingTurns,
  });

  final String id;

  /// The scryer — the player who receives the reveal.
  final String casterId;

  /// The player whose committed spell target is revealed to [casterId].
  final String targetId;

  int remainingTurns;

  // ── Canonical serialisation ───────────────────────────────────────────────

  void writeToBytes(BytesBuilder buf) {
    _writeUtf8(buf, id);
    _writeUtf8(buf, casterId);
    _writeUtf8(buf, targetId);
    buf.addByte(remainingTurns & 0xFF);
  }

  static void _writeUtf8(BytesBuilder buf, String s) {
    final bytes = s.codeUnits.map((c) => c & 0xFF).toList();
    buf.addByte(bytes.length);
    buf.add(bytes);
  }
}
