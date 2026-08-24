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
//
// ## Coverage hole closed 2026-08-23 (M4.22)
//
// This file used to assert only `minions.hasLength(1)` on each device. That is
// far weaker than the property it exists to defend: a creature that replicates
// but arrives with a divergent id, position, HP, affinity, stat block,
// ability set, personality or size rung passes `hasLength(1)` on both devices
// and still forfeits the duel at `_exchangeStateHash` — which is exactly the
// M4.22 hardware failure. `_exchangeStateHash` compares
// `BattleState.toCanonicalBytes()`, so that is what this test now compares,
// plus a field-by-field minion comparison so a failure names the field instead
// of a byte offset.
//
// It is expected to stay GREEN: this fixture's spell is honest (its wire
// `formula` is derived from the same trajectory its synthetic proof attests),
// and the M4.22 defect needs a spell whose authored wire fields disagree with
// its own proof. The assertions are here so the hole cannot silently reopen,
// not because they currently fail.

import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:rune_duel/battle/engine/turn_loop.dart';
import 'package:rune_duel/engine/border_zone.dart';
import 'package:rune_duel/engine/hex_grid.dart';
import 'package:rune_duel/battle/models/minion.dart';

import 'certified_cast_fixture.dart';
import 'turn_session_pair.dart';

String _hex(Uint8List b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

/// Every [Minion] field `BattleState.toCanonicalBytes` hashes, in the order it
/// hashes them, as a printable record. Compared as a whole so a divergence
/// reports the field that moved rather than a byte offset into a 300-byte blob.
Map<String, Object?> _canonicalMinionFields(Minion m) => {
      'id': m.id,
      'ownerId': m.ownerId,
      'teamId': m.teamId,
      'position.q': m.position.q,
      'position.r': m.position.r,
      'hp': m.hp,
      'affinity': m.affinity.name,
      'stats.maxHp': m.stats.maxHp,
      'stats.damage': m.stats.damage,
      'stats.moveSpeed': m.stats.moveSpeed,
      'stats.attackRange': m.stats.attackRange,
      'abilities': (m.abilities.map((a) => a.name).toList()..sort()).join(','),
      'personality': m.personality.name,
      'sizeBonus': m.sizeBonus,
      'isIllusion': m.isIllusion,
    };

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

      // The creature must be the SAME creature, field by field. `hasLength(1)`
      // alone would accept two different creatures with the same count.
      expect(
        _canonicalMinionFields(verifierState.minions.single),
        equals(_canonicalMinionFields(casterState.minions.single)),
        reason: 'every field here is hashed by toCanonicalBytes — any one of '
            'them differing forfeits the duel on this turn (M4.22)',
      );

      // The real lockstep gate, verbatim: `_exchangeStateHash` hashes exactly
      // these bytes. Asserting on them covers the caster's mana and chain
      // state too, which is where M4.22 actually first diverged — the minion
      // block was downstream of it.
      expect(
        _hex(verifierState.toCanonicalBytes()),
        equals(_hex(casterState.toCanonicalBytes())),
        reason: 'this is the comparison _exchangeStateHash performs; if it '
            'fails the duel forfeits on the summon turn',
      );
    },
  );
}
