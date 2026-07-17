// SPDX-License-Identifier: GPL-3.0-or-later
//
// solo_battle_setup.dart — shared BattleState construction for single-player
// sessions (Solo Practice, Spell Test Lab). Builds the two-avatar battlefield
// (local at bottom vertex, dummy one tile south of the top vertex) and
// converts a chapter's artifact loadout into WizardAvatar accoutrements.
// Extracted from SoloPracticeSettingsScreen so the Spell Test Lab can reuse
// it exactly.

import 'package:rune_duel/engine/hex_grid.dart';

import '../../spells/chapter_asset.dart';
import 'battle_state.dart';
import 'hex_battlefield.dart';
import 'match_config.dart';
import 'wizard_avatar.dart';

/// Result of [buildSoloBattleState]: the constructed [state] plus the dummy's
/// spawn position (callers that script dummy behavior need it for targeting).
class SoloBattleSetup {
  const SoloBattleSetup({required this.state, required this.dummyPosition});

  final BattleState state;
  final HexCoord dummyPosition;
}

/// Builds a two-avatar [BattleState] for a solo session: the local player
/// (bottom vertex) against a static dummy opponent (one tile south of the
/// top vertex), with the local player's accoutrements derived from
/// [chapter].artifacts.
SoloBattleSetup buildSoloBattleState(
  ChapterAsset chapter,
  MatchConfig config, {
  String localId = 'local',
  String dummyId = 'dummy',
}) {
  // Convert chapter artifacts → WizardAvatar accoutrements.
  // First mana gem becomes the indestructible core gem.
  final accoutrements = <Accoutrement>[];
  bool coreGemAdded = false;
  for (int i = 0; i < chapter.artifacts.length; i++) {
    final a = chapter.artifacts[i];
    final kind = _toAccoutrementKind(a.kind);
    final isCore = kind == AccoutrementKind.manaGem && !coreGemAdded;
    if (isCore) coreGemAdded = true;
    accoutrements.add(Accoutrement(
      id: 'acc_$i',
      kind: kind,
      isCoreGem: isCore,
      targetCommitmentHex: a.targetCommitmentHex,
    ));
  }
  // Every wizard has at least the indestructible core gem.
  if (!coreGemAdded) {
    accoutrements.insert(
      0,
      const Accoutrement(id: 'acc_core', kind: AccoutrementKind.manaGem, isCoreGem: true),
    );
  }

  final manaGems = accoutrements.where((a) => a.kind == AccoutrementKind.manaGem).length;
  final maxMana = manaGems * config.manaGemPoolPerGem;

  final battlefield = Battlefield(radius: config.gridRadius);
  final spawns = battlefield.spawnPositions(2); // [local=bottom, dummy=top]
  final spawnPos = spawns[0];
  // Dummy sits one tile south of the top vertex (toward the local player's
  // side) so knockback effects — which push away from the caster, i.e.
  // further north/away — have room to register instead of being clipped
  // immediately by the battlefield edge.
  final dummyPos = HexCoord(spawns[1].q, spawns[1].r + 1);

  final avatar = WizardAvatar(
    playerId: localId,
    ownerPubkeyHex: '0x${'0' * 64}',
    hp: config.playerHp,
    mana: maxMana,
    maxMana: maxMana,
    position: spawnPos,
    teamId: 'solo',
    baseSpellRange: 3,
    accoutrements: accoutrements,
  );

  // Dummy opponent: one mana gem, stands still (SoloBattleSession always
  // passes unless the caller opts into scripted casting — see SoloBattleSession
  // .dummyAutoCast, used only by the Spell Test Lab).
  final dummyMaxMana = config.manaGemPoolPerGem;
  final dummy = WizardAvatar(
    playerId: dummyId,
    ownerPubkeyHex: '0x${'0' * 64}',
    hp: config.playerHp,
    mana: dummyMaxMana,
    maxMana: dummyMaxMana,
    position: dummyPos,
    teamId: 'foe',
    baseSpellRange: 3,
    accoutrements: [
      const Accoutrement(id: 'dummy_gem', kind: AccoutrementKind.manaGem, isCoreGem: true),
    ],
  );

  battlefield.occupancy[localId] = spawnPos;
  battlefield.occupancy[dummyId] = dummyPos;

  final battleState = BattleState(
    config: config,
    avatars: [avatar, dummy],
    teams: [
      Team(id: 'solo', playerIds: [localId]),
      Team(id: 'foe', playerIds: [dummyId]),
    ],
    battlefield: battlefield,
  );

  return SoloBattleSetup(state: battleState, dummyPosition: dummyPos);
}

AccoutrementKind _toAccoutrementKind(ArtifactKind kind) => switch (kind) {
      ArtifactKind.manaGem => AccoutrementKind.manaGem,
      ArtifactKind.bookmark => AccoutrementKind.bookmark,
      ArtifactKind.deflectionRod => AccoutrementKind.absorptionRod,
      ArtifactKind.counterCharm => AccoutrementKind.counterCharm,
    };
