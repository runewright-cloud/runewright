// SPDX-License-Identifier: GPL-3.0-or-later
//
// illusion.dart — WizardIllusionSet: the Water-flavor Illusions (Water-Air)
// decoy mechanic.
//
// On cast, the caster gets 3 (or however many survive) decoy tiles placed
// around their own position. Whenever they'd otherwise be hit by a spell or
// attack (see EffectApplicator._resolveIllusionRedirect / TurnLoop's haymaker
// path), roll 1/remaining: on a hit the real wizard takes it; otherwise one
// decoy is destroyed and the wizard is moved to that decoy's tile instead.
//
// Fire/Earth/Air Illusions flavors (minion clone, terrain clone, minion→1hp)
// don't need persistent state and are applied directly by EffectApplicator.

import 'dart:convert' show utf8;
import 'dart:typed_data';

import 'package:rune_duel/engine/hex_grid.dart';

class WizardIllusionSet {
  WizardIllusionSet({
    required this.ownerId,
    required this.decoyPositions,
  });

  final String ownerId;

  /// Remaining decoy tiles. One is removed each time a redirect resolves;
  /// the set is dropped from BattleState.wizardIllusions once empty.
  final List<HexCoord> decoyPositions;

  void writeToBytes(BytesBuilder buf) {
    _writeUtf8(buf, ownerId);
    buf.addByte(decoyPositions.length & 0xFF);
    for (final pos in decoyPositions) {
      buf.addByte(pos.q & 0xFF);
      buf.addByte(pos.r & 0xFF);
    }
  }

  static void _writeUtf8(BytesBuilder buf, String s) {
    final bytes = utf8.encode(s);
    buf.addByte(bytes.length);
    buf.add(bytes);
  }
}
