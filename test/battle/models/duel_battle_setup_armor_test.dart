// SPDX-License-Identifier: GPL-3.0-or-later
//
// duel_battle_setup_armor_test.dart — certified armor becomes equipment on the
// right wizard, on both devices, and Earth becomes starting HP (engine v6).
//
// The mapping is the load-bearing part. `buildDuelBattleState` has exactly one
// local/peer → bottom/top selector — the BigInt pubkey order DECISION 2 gave it
// — and armor rides it alongside the artifact loadouts. A second, host/guest
// mapping would put each device's own armor on its own bottom wizard and
// desync on turn 1.

import 'package:test/test.dart';
import 'package:rune_duel/battle/models/certified_armor.dart';
import 'package:rune_duel/battle/models/duel_battle_setup.dart';
import 'package:rune_duel/battle/models/match_config.dart';
import 'package:rune_duel/battle/models/solo_battle_setup.dart';
import 'package:rune_duel/battle/models/wizard_avatar.dart';
import 'package:rune_duel/spells/chapter_asset.dart';

import 'certified_armor_fixture.dart';

// Two owner hexes with a known BigInt order: [low] spawns bottom, [high] top.
final _low = '0x${'11' * 32}';
final _high = '0x${'22' * 32}';

const _config = MatchConfig(playerHp: 24, gridRadius: 6, maxPlayers: 2);

DuelBattleSetup _build({
  required String localHex,
  required String peerHex,
  CertifiedArmor? localArmor,
  CertifiedArmor? peerArmor,
  List<ArtifactEntry> localArtifacts = const [],
  List<ArtifactEntry> peerArtifacts = const [],
}) =>
    buildDuelBattleState(
      config: _config,
      localArtifacts: localArtifacts,
      peerArtifacts: peerArtifacts,
      localOwnerHex: localHex,
      peerOwnerHex: peerHex,
      localArmor: localArmor,
      peerArmor: peerArmor,
    );

WizardAvatar _byId(DuelBattleSetup setup, String id) =>
    setup.state.avatars.firstWhere((a) => a.playerId == id);

void main() {
  group('no armor', () {
    test('both wizards start armourless at the configured HP', () {
      final setup = _build(localHex: _low, peerHex: _high);
      for (final av in setup.state.avatars) {
        expect(av.armor, isNull);
        expect(av.hp, 24, reason: 'config.playerHp, unchanged');
      }
    });

    test('solo construction still produces armourless wizards', () {
      // The solo path names no armor argument at all — the optional parameter
      // defaults to null rather than every solo call site passing `armor: null`.
      final solo = buildSoloBattleState(
        ChapterAsset(id: 'ch', name: 'Test', createdAt: DateTime.utc(2026, 8, 26)),
        _config,
      );
      for (final av in solo.state.avatars) {
        expect(av.armor, isNull);
        expect(av.hp, 24);
      }
    });
  });

  group('local/peer -> bottom/top mapping', () {
    test('the local wizard wears the local armor', () {
      final setup = _build(
        localHex: _low,
        peerHex: _high,
        localArmor: armorOf(kFireArmorCodes),
      );
      expect(_byId(setup, _low).armor?.meleeBonus, 1);
      expect(_byId(setup, _high).armor, isNull);
      expect(setup.localPlayerId, _low);
    });

    test('the peer wizard wears the peer armor', () {
      final setup = _build(
        localHex: _low,
        peerHex: _high,
        peerArmor: armorOf(kAirArmorCodes),
      );
      expect(_byId(setup, _low).armor, isNull);
      expect(_byId(setup, _high).armor?.moveSpeedBonus, 1);
    });

    test('the mapping follows the pubkey, not the local role', () {
      // Same match, seen from the device whose hex sorts HIGHER: its own armor
      // must land on the TOP avatar, not on the bottom one.
      final setup = _build(
        localHex: _high,
        peerHex: _low,
        localArmor: armorOf(kFireArmorCodes),
        peerArmor: armorOf(kAirArmorCodes),
      );
      expect(_byId(setup, _high).armor?.meleeBonus, 1,
          reason: 'the local (higher-hex) wizard wears the local armor');
      expect(_byId(setup, _low).armor?.moveSpeedBonus, 1);
    });
  });

  group('host and guest build the same state', () {
    test('canonical bytes are identical from both sides of the same duel', () {
      // Host: local = low hex, wearing fire. Guest: local = high hex, wearing
      // air. Both describe the same match; both must hash the same.
      final host = _build(
        localHex: _low,
        peerHex: _high,
        localArmor: armorOf(runOfCode('F', 7)),
        peerArmor: armorOf(runOfCode('A', 10)),
      );
      final guest = _build(
        localHex: _high,
        peerHex: _low,
        localArmor: armorOf(runOfCode('A', 10)),
        peerArmor: armorOf(runOfCode('F', 7)),
      );
      expect(guest.state.toCanonicalBytes(), host.state.toCanonicalBytes());
      expect(host.localPlayerId, _low);
      expect(guest.localPlayerId, _high);
    });

    test('a swapped armor assignment does NOT hash the same', () {
      // The negative half: if the guest put its own armor on its own bottom
      // wizard (a second, host/guest mapping), this is the state it would
      // build. It must not agree with the host's.
      final host = _build(
        localHex: _low,
        peerHex: _high,
        localArmor: armorOf(runOfCode('F', 7)),
        peerArmor: armorOf(runOfCode('A', 10)),
      );
      final swapped = _build(
        localHex: _high,
        peerHex: _low,
        localArmor: armorOf(runOfCode('F', 7)),
        peerArmor: armorOf(runOfCode('A', 10)),
      );
      expect(swapped.state.toCanonicalBytes(),
          isNot(host.state.toCanonicalBytes()));
    });
  });

  group('Earth -> starting HP', () {
    test('an Earth armor raises the pool the wizard starts with', () {
      final setup = _build(
        localHex: _low,
        peerHex: _high,
        localArmor: armorOf(runOfCode('E', 12)), // ladder rung 12 -> +8
      );
      expect(_byId(setup, _low).hp, 24 + 8);
      expect(_byId(setup, _high).hp, 24,
          reason: 'the unarmored wizard is untouched');
    });

    test('an armor with no Earth adds no HP', () {
      final setup = _build(
        localHex: _low,
        peerHex: _high,
        localArmor: armorOf(runOfCode('F', 7)),
      );
      expect(_byId(setup, _low).armor!.armorHpBonus, 0);
      expect(_byId(setup, _low).hp, 24);
    });

    test('the granted HP stays attributable through avatar.armor', () {
      // One HP pool, no armorHpRemaining, no second bar — but the provenance
      // of the extra points is still recoverable, which is what an eventual
      // armor-breaking mechanic needs.
      final setup = _build(
        localHex: _low,
        peerHex: _high,
        localArmor: armorOf(runOfCode('E', 20)), // -> +11
      );
      final av = _byId(setup, _low);
      expect(av.armor!.armorHpBonus, 11);
      expect(av.hp - av.armor!.armorHpBonus, _config.playerHp);
    });
  });
}
