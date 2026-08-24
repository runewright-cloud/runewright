// SPDX-License-Identifier: GPL-3.0-or-later
//
// simultaneous_summon_desync_repro_test.dart — TEMPORARY DIAGNOSTIC, NOT A FIX.
//
// Written during the M4 engine-v4 two-device hardware gate (2026-08-23) to
// reproduce, in automation, the failure observed on real devices:
//
//   Pixel 6 (host) and Linux desktop (join), commit 8ee51fc, engine v4.
//   Both players cast the SAME summon (Basic Windhound, 83 mana) on the same
//   turn, each targeting a tile adjacent to itself, then both stood fast.
//   Both devices then reported:
//     "state hash mismatch on turn 3"
//     Linux local=a19f0fa5... peer=296d7f2e...
//     Pixel  local=296d7f2e... peer=a19f0fa5...
//   (mirrored -- a genuine state divergence, not one-sided corruption).
//
// Existing coverage gap this probes: peer_summon_replication_test.dart (M4.16)
// only ever has ONE side summon -- caster summons, verifier passes. Nothing in
// the suite has both players summon on the SAME turn, which is what puts two
// _castSummon calls (each drawing `rng.nextInt` for the minion id, see
// deterministic_resolution.dart:3223) into a single Phase-5 settlement.
//
// ## OUTCOME (2026-08-23, M4.22 characterization)
//
// Both variants below remain GREEN, and that is now understood rather than
// mysterious. `spellFromElements` (certified_cast_fixture.dart) derives the
// wire `formula` FROM the same element list its synthetic proof attests, so
// every fixture spell is honest by construction. The real defect needs a spell
// whose authored `SpellAsset.formula` disagrees with its own proof, which the
// shipped `assets/basic_spells/basic_windhound.json` does and no fixture can.
//
// The hypothesis recorded in the second test's preamble below — that a double
// summon "cancels" the local-vs-peer asymmetry — is WRONG, and is left in
// place as the record of what was believed at the time.
// `BattleState.toCanonicalBytes` encodes mana per player, so the two devices
// end up mirrored (a=17/b=75 against a=75/b=17), never equal.
//
// The exact offline reproduction lives in
// m422_summon_desync_characterization_test.dart, which drives the real shipped
// asset through the same TurnSessionPair and reproduces the hardware failure.
//
// Delete this file when the gate is closed out.

import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:rune_duel/battle/engine/turn_loop.dart';
import 'package:rune_duel/engine/border_zone.dart';
import 'package:rune_duel/engine/hex_grid.dart';

import 'certified_cast_fixture.dart';
import 'turn_session_pair.dart';

String _hex(Uint8List b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

void main() {
  test(
    'both players summoning on the same turn keep identical canonical state',
    () async {
      final stateA = makeDuelState(startingMana: 500);
      final stateB = makeDuelState(startingMana: 500);
      final pair = TurnSessionPair();

      final loopA = TurnLoop(
        state: stateA,
        session: pair.sessionA,
        localPlayerId: 'player_a',
        verifyProof: alwaysOk,
        vkBytes: Uint8List(0),
      );
      final loopB = TurnLoop(
        state: stateB,
        session: pair.sessionB,
        localPlayerId: 'player_b',
        verifyProof: alwaysOk,
        vkBytes: Uint8List(0),
      );

      // Basic Windhound's REAL formula, as read from the spell asset actually
      // cast on both devices during the hardware gate:
      //   air water earth air water fire air earth water fire air earth
      // (12 elements -- grants abilities, unlike the 3-earth plain creature
      // the M4.16 test uses). Distinct `variant` values so the two casts are
      // different spell assets, as they were in the real duel: the Pixel cast
      // the shipped `basic_windhound`, the Linux peer a locally-inscribed copy.
      const windhound = <BorderZone>[
        BorderZone.air, BorderZone.water, BorderZone.earth,
        BorderZone.air, BorderZone.water, BorderZone.fire,
        BorderZone.air, BorderZone.earth, BorderZone.water,
        BorderZone.fire, BorderZone.air, BorderZone.earth,
      ];
      final summonA = spellFromElements(
        elements: windhound,
        variant: 50,
        name: 'Windhound A',
        isSummon: true,
      );
      final summonB = spellFromElements(
        elements: windhound,
        variant: 51,
        name: 'Windhound B',
        isSummon: true,
      );
      loopA.localChapterCommitments = [summonA.commitmentHex];
      loopB.localChapterCommitments = [summonB.commitmentHex];

      await Future.wait([
        loopA.runTurn(TurnInput(
          action: SpellCastAction(
              spell: summonA, targetHex: const HexCoord(0, 1)),
        )),
        loopB.runTurn(TurnInput(
          action: SpellCastAction(
              spell: summonB, targetHex: const HexCoord(2, 0)),
        )),
      ]);

      // Both devices must see BOTH creatures.
      expect(stateA.minions, hasLength(2),
          reason: 'device A must see its own summon and the peer\'s');
      expect(stateB.minions, hasLength(2),
          reason: 'device B must see its own summon and the peer\'s');

      final idsA = (stateA.minions.map((m) => m.id).toList()..sort());
      final idsB = (stateB.minions.map((m) => m.id).toList()..sort());
      printOnFailure('A minion ids: $idsA');
      printOnFailure('B minion ids: $idsB');
      expect(idsA, equals(idsB),
          reason: 'minion ids are hashed into toCanonicalBytes -- if the two '
              'devices mint different ids the lockstep hash diverges');

      // The real lockstep gate.
      final canonA = stateA.toCanonicalBytes();
      final canonB = stateB.toCanonicalBytes();
      printOnFailure('canonical A: ${_hex(canonA)}');
      printOnFailure('canonical B: ${_hex(canonB)}');
      expect(_hex(canonA), equals(_hex(canonB)),
          reason: 'this is exactly what _exchangeStateHash compares; a '
              'mismatch here is the observed hardware desync');
    },
  );

  // Hardware bisect (2026-08-23, second paired match, commit 8ee51fc): with
  // only ONE side summoning, both devices still desynced --
  //   local=0f40fa829bd587aad7d3d53c9fa29488ed5a87f2ee01311cc201a264b48f4e2f
  //   peer =106353bd837b599e34db1236feeb726985d9f74671116b5454c2211c031a9cce
  // So simultaneity is not the trigger. That also explains why the test above
  // passes: when BOTH sides summon, each device performs one local summon and
  // one peer summon, so any local-path-vs-peer-path asymmetry cancels out of
  // the hash. With a single summoner it cannot cancel.
  test(
    'a single summon leaves both devices with identical canonical state',
    () async {
      final casterState = makeDuelState(startingMana: 500);
      final verifierState = makeDuelState(startingMana: 500);
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

      const windhound = <BorderZone>[
        BorderZone.air, BorderZone.water, BorderZone.earth,
        BorderZone.air, BorderZone.water, BorderZone.fire,
        BorderZone.air, BorderZone.earth, BorderZone.water,
        BorderZone.fire, BorderZone.air, BorderZone.earth,
      ];
      final summon = spellFromElements(
        elements: windhound,
        variant: 50,
        name: 'Windhound',
        isSummon: true,
      );
      caster.localChapterCommitments = [summon.commitmentHex];

      await Future.wait([
        caster.runTurn(TurnInput(
          action:
              SpellCastAction(spell: summon, targetHex: const HexCoord(0, 1)),
        )),
        verifier.runTurn(TurnInput(action: PassAction())),
      ]);

      expect(casterState.minions, hasLength(1));
      expect(verifierState.minions, hasLength(1));

      final a = casterState.minions.single;
      final b = verifierState.minions.single;
      printOnFailure('caster   minion: id=${a.id} pos=${a.position} '
          'hp=${a.hp} aff=${a.affinity} pers=${a.personality} '
          'abil=${a.abilities} size=${a.sizeBonus} stats=${a.stats}');
      printOnFailure('verifier minion: id=${b.id} pos=${b.position} '
          'hp=${b.hp} aff=${b.affinity} pers=${b.personality} '
          'abil=${b.abilities} size=${b.sizeBonus} stats=${b.stats}');

      final canonA = casterState.toCanonicalBytes();
      final canonB = verifierState.toCanonicalBytes();
      printOnFailure('canonical caster  : ${_hex(canonA)}');
      printOnFailure('canonical verifier: ${_hex(canonB)}');
      expect(_hex(canonA), equals(_hex(canonB)),
          reason: 'single-summon lockstep: this is the hardware failure');
    },
  );
}
