// SPDX-License-Identifier: GPL-3.0-or-later
//
// reflection_link.dart — ReflectionLink and ReflectionTrigger.
//
// Reflections (Water-Water) links a caster to a target for the remainder of
// the match. At cast time 2 (or 3 when potent) triggers are randomly chosen
// from the pool of 4. The link is removed when either participant dies.
//
// Trigger semantics:
//   damageReflect — whenever the CASTER takes damage, the TARGET takes equal
//                   damage (not chain-reflectable; uses direct absorbDamage).
//   summonMirror  — whenever the TARGET summons a minion, the CASTER receives
//                   an identical minion under their control.
//   manaMirror    — whenever the TARGET gains mana, the CASTER gains equal mana.
//   statusMirror  — whenever the TARGET self-casts a status buff (i.e. caster
//                   and recipient of the status are the same), the CASTER also
//                   receives that status effect.

import 'dart:typed_data';

enum ReflectionTrigger {
  damageReflect,
  summonMirror,
  manaMirror,
  statusMirror,
}

class ReflectionLink {
  ReflectionLink({
    required this.id,
    required this.casterId,
    required this.targetId,
    required this.activeTriggers,
    required this.remainingTurns,
  });

  final String id;
  final String casterId;
  final String targetId;
  final Set<ReflectionTrigger> activeTriggers;
  int remainingTurns;

  // ── Canonical serialisation ───────────────────────────────────────────────

  void writeToBytes(BytesBuilder buf) {
    _writeUtf8(buf, id);
    _writeUtf8(buf, casterId);
    _writeUtf8(buf, targetId);
    // Encode trigger set as a bitmask (stable ordering by enum index).
    var mask = 0;
    for (final t in activeTriggers) {
      mask |= (1 << t.index);
    }
    buf.addByte(mask);
    buf.addByte(remainingTurns & 0xFF);
  }

  static void _writeUtf8(BytesBuilder buf, String s) {
    final bytes = s.codeUnits.map((c) => c & 0xFF).toList();
    buf.addByte(bytes.length);
    buf.add(bytes);
  }
}
