// SPDX-License-Identifier: GPL-3.0-or-later
//
// peer_summon_replication_test.dart — a peer's summon must spawn on BOTH
// devices.
//
// ## Regression test for M4.16 (docs/M4_findings.md)
//
// `_encodeAction` used to omit `SpellAsset.isSummon` and `summonPersonality`,
// and `_decodeAction` rebuilt the peer's SpellAsset with those fields at their
// defaults. A summon cast therefore arrived at the opponent's device as an
// ordinary incantation: the caster spawned a creature, the verifier resolved
// formula effects instead, and `_exchangeStateHash` forfeited the match on the
// turn the summon was cast.
//
// Measured before the fix: caster device 1 minion, verifier device 0.
// **Summons were unusable in any real two-device duel.**
//
// Nothing caught it because every existing summon test
// (summon_cast_test.dart) runs in solo mode, where there is no second device
// to disagree — the peer decode path never executes. Found by the replay
// corpus (docs/REPLAY_HARNESS.md) on its first attempt at a summon script.

import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:rune_duel/battle/engine/turn_loop.dart';
import 'package:rune_duel/engine/border_zone.dart';
import 'package:rune_duel/engine/hex_grid.dart';

import 'certified_cast_fixture.dart';
import 'turn_session_pair.dart';

void main() {
  test(
    'a peer summon spawns the creature on the verifier device too',
    () async {
      final casterState = makeDuelState();
      final verifierState = makeDuelState();
      final pair = TurnSessionPair();
      final caster = TurnLoop(
        state: casterState,
        session: pair.sessionA,
        localPlayerId: 'player_a',
        verifyProof: alwaysOk,
        vkBytes: Uint8List(0),
      );
      final verifier = TurnLoop(
        state: verifierState,
        session: pair.sessionB,
        localPlayerId: 'player_b',
        verifyProof: alwaysOk,
        vkBytes: Uint8List(0),
      );

      // Three earths: a plain creature. A fourth element would silently grant
      // an ability (EEEE = Big, 3-tile footprint) and make this a test about
      // footprints.
      final summon = spellFromElements(
        elements: List.filled(3, BorderZone.earth),
        variant: 50,
        name: 'Stone Sentinel',
        isSummon: true,
      );
      caster.localChapterCommitments = [summon.commitmentHex];

      await Future.wait([
        caster.runTurn(TurnInput(
          action:
              SpellCastAction(spell: summon, targetHex: const HexCoord(1, 1)),
        )),
        verifier.runTurn(TurnInput(action: PassAction())),
      ]);

      expect(casterState.minions, hasLength(1),
          reason: 'sanity: the caster spawns its own creature');
      expect(verifierState.minions, hasLength(1),
          reason: 'the opponent must see the same creature — a summon that '
              'exists on only one device desyncs the match immediately');
    },
  );
}
