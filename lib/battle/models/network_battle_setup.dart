// SPDX-License-Identifier: GPL-3.0-or-later
//
// network_battle_setup.dart — shared BattleState construction for networked
// LAN battles (2-6 players). Structurally parallel to solo_battle_setup.dart;
// unlike solo, avatar positions must be computed identically on every
// device — see BATTLE_PROTOCOL.md §10d (canonical position assignment).
//
// Takes resolved [Accoutrement] lists per slot, not a ChapterAsset: a device
// only ever has its own full chapter locally. A peer's accoutrement loadout
// isn't obtainable from anything exchanged today (the book-commitment
// exchange covers spell commitmentHexes, not artifact loadout) -- see the
// TODO on NetworkPlayerSlot.accoutrements. Callers resolve their own
// accoutrements via chapter_accoutrements.dart's accoutrementsFromChapter.

import 'dart:typed_data';

import '../engine/hash_rng.dart';
import 'battle_state.dart';
import 'component_order.dart';
import 'hex_battlefield.dart';
import 'match_config.dart';
import 'wizard_avatar.dart';

/// One connected player's identity + team assignment, agreed during lobby
/// formation before [buildNetworkBattleState] is called.
class NetworkPlayerSlot {
  const NetworkPlayerSlot({
    required this.playerId,
    required this.ownerPubkeyHex,
    required this.teamId,
    required this.accoutrements,
  });

  final String playerId;

  /// Poseidon2(inscriber's Ed25519 pubkey) — see WizardAvatar.ownerPubkeyHex.
  final String ownerPubkeyHex;

  final String teamId;

  /// This player's resolved artifact loadout. For the local player, derive
  /// via `accoutrementsFromChapter(myChapter)`. For a peer, there is no
  /// artifact-loadout exchange yet (only the spell-commitment book root is
  /// exchanged) -- callers must use a placeholder until that's built.
  // TODO(battle): add an artifact-loadout wire exchange so a peer's real
  //   accoutrements (mana gem count, bookmarks, counter-charms) can be used
  //   here instead of a placeholder.
  final List<Accoutrement> accoutrements;
}

/// Builds an N-player (2-6) [BattleState] for networked LAN battles.
///
/// Position assignment is canonical, not device-relative: [roster] is sorted
/// by [NetworkPlayerSlot.playerId] (ascending) and zipped against
/// [Battlefield.spawnPositions] in that fixed order -- every device must
/// produce byte-identical [WizardAvatar.position] values regardless of which
/// entry is "local," since position feeds the per-turn stateHash
/// (BATTLE_PROTOCOL.md §6). Camera/view rotation so the local player renders
/// at the bottom of their own screen is a UI-layer concern, applied on top of
/// this canonical assignment -- never fed back into it.
///
/// [jointEntropy] must be the per-battle joint entropy from the initial
/// commit-reveal exchange (BATTLE_PROTOCOL.md §3) -- only consumed for the
/// 5-player spawn's random vertex skip, so every device picks the same one
/// (HashRng, not a platform entropy source, for cross-device determinism).
BattleState buildNetworkBattleState({
  required List<NetworkPlayerSlot> roster,
  required MatchConfig config,
  required Uint8List jointEntropy,
}) {
  final sortedRoster = List<NetworkPlayerSlot>.from(roster)
    ..sort((a, b) => a.playerId.compareTo(b.playerId));

  final battlefield = Battlefield(radius: config.gridRadius);
  final spawnRng = sortedRoster.length == 5 ? HashRng(jointEntropy) : null;
  final spawns = battlefield.spawnPositions(sortedRoster.length, rng: spawnRng);

  final avatars = <WizardAvatar>[];
  for (var i = 0; i < sortedRoster.length; i++) {
    final slot = sortedRoster[i];
    final accoutrements = slot.accoutrements;
    final manaGems = accoutrements.where((a) => a.kind == AccoutrementKind.manaGem).length;
    final maxMana = manaGems * config.manaGemPoolPerGem;

    final avatar = WizardAvatar(
      playerId: slot.playerId,
      ownerPubkeyHex: slot.ownerPubkeyHex,
      hp: config.playerHp,
      mana: maxMana,
      maxMana: maxMana,
      position: spawns[i],
      teamId: slot.teamId,
      baseSpellRange: config.baseRange,
      accoutrements: accoutrements,
    );
    avatars.add(avatar);
    battlefield.occupancy[slot.playerId] = spawns[i];
  }

  final teamIds = sortedRoster.map((s) => s.teamId).toSet();
  final teams = [
    for (final teamId in teamIds)
      Team(
        id: teamId,
        playerIds: sortedRoster.where((s) => s.teamId == teamId).map((s) => s.playerId).toList(),
      ),
  ];

  return BattleState(
    config: config,
    avatars: avatars,
    teams: teams,
    battlefield: battlefield,
    // Seating comes off the same canonical spawn assignment above, so every
    // device derives the identical performing order without an exchange —
    // including the 5-player case, whose skipped vertex was itself drawn from
    // the shared joint entropy.
    componentSeating: clockwiseComponentOrder(
      playerIds: [for (final s in sortedRoster) s.playerId],
      startPositions: spawns,
      radius: config.gridRadius,
    ),
  );
}
