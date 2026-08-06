// SPDX-License-Identifier: GPL-3.0-or-later
//
// duel_battle_setup.dart — symmetric, identity-bound BattleState construction
// for a two-device LAN duel (LAN_BATTLE_WIREUP_PLAN.md §3.1).
//
// Unlike solo_battle_setup.dart's "local always bottom, sentinel pubkey"
// convention (fine for a one-device fake opponent, wrong for two real
// devices), both devices here must independently produce byte-identical
// BattleState — same avatar order, spawns, player ids, and accoutrements —
// with no host/guest branch, or the per-turn state-hash lockstep diverges on
// turn 1. DECISION 2 (plan §2): roles are derived purely from the two
// AUTHENTICATED owner_pubkey hexes (BattleSession.exchangeIdentityAuth's
// result), sorted as BigInt so both devices agree regardless of string case
// or leading-zero formatting.
//
// The peer avatar's accoutrements come from [peerArtifacts] — the peer's
// chapter artifact loadout, exchanged in the clear via
// BattleSession.exchangeArtifactLoadout (see accoutrement_loadout.dart's doc
// comment and BATTLE_AUTH_PLAN §4's avatar-binding requirement, satisfied
// here by setting WizardAvatar.ownerPubkeyHex from the authenticated hex).

import 'package:rune_duel/engine/hex_grid.dart';

import '../../spells/chapter_asset.dart' show ArtifactEntry;
import 'accoutrement_loadout.dart';
import 'battle_state.dart';
import 'component_order.dart';
import 'hex_battlefield.dart';
import 'match_config.dart';
import 'wizard_avatar.dart';

/// Result of [buildDuelBattleState]: the constructed [state] plus which
/// player id (one of the two ownerPubkeyHex strings baked into [state])
/// belongs to the local device.
class DuelBattleSetup {
  const DuelBattleSetup({required this.state, required this.localPlayerId});

  final BattleState state;
  final String localPlayerId;
}

/// True iff [a] sorts before [b] as an unsigned integer (leading-zero- and
/// case-insensitive) — the ordering DECISION 2 uses to assign spawns/ids
/// without a host/guest branch. Mirrors the BigInt-parse convention already
/// used for hex equality elsewhere (e.g. battle_session.dart's `_hexEq`).
bool _hexLessThan(String a, String b) {
  BigInt parse(String s) => BigInt.parse(s.startsWith('0x') ? s.substring(2) : s, radix: 16);
  return parse(a) < parse(b);
}

/// Builds a byte-identical two-avatar [BattleState] on both devices in a LAN
/// duel. [localOwnerHex]/[peerOwnerHex] must be the AUTHENTICATED
/// owner_pubkey hexes from `BattleSession.exchangeIdentityAuth` — never an
/// unauthenticated value a proof merely declares (BATTLE_AUTH_PLAN.md §4).
///
/// Player ids are the two owner hex strings themselves. The lower hex (BigInt
/// order) spawns at the bottom vertex (`spawns[0]`); the higher spawns at the
/// top (`spawns[1]`) — both devices compute this identically, with no
/// knowledge of which side hosted or joined.
DuelBattleSetup buildDuelBattleState({
  required MatchConfig config,
  required List<ArtifactEntry> localArtifacts,
  required List<ArtifactEntry> peerArtifacts,
  required String localOwnerHex,
  required String peerOwnerHex,
  String localWizardName = '',
  String peerWizardName = '',
}) {
  final bottomHex = _hexLessThan(localOwnerHex, peerOwnerHex) ? localOwnerHex : peerOwnerHex;
  final topHex = bottomHex == localOwnerHex ? peerOwnerHex : localOwnerHex;
  final bottomWizardName = bottomHex == localOwnerHex ? localWizardName : peerWizardName;
  final topWizardName = bottomHex == localOwnerHex ? peerWizardName : localWizardName;

  final battlefield = Battlefield(radius: config.gridRadius);
  final spawns = battlefield.spawnPositions(2); // [bottom, top]
  final bottomPos = spawns[0];
  final topPos = spawns[1];

  WizardAvatar buildAvatar({
    required String ownerHex,
    required List<ArtifactEntry> artifacts,
    required String idPrefix,
    required HexCoord position,
    required String teamId,
    required String wizardName,
  }) {
    final accoutrements = accoutrementsFromArtifacts(artifacts, idPrefix: idPrefix);
    final manaGems = accoutrements.where((a) => a.kind == AccoutrementKind.manaGem).length;
    final maxMana = config.innateManaPool + manaGems * config.manaGemPoolPerGem;
    return WizardAvatar(
      playerId: ownerHex,
      ownerPubkeyHex: ownerHex,
      wizardName: wizardName,
      hp: config.playerHp,
      mana: maxMana ~/ 2,
      maxMana: maxMana,
      position: position,
      teamId: teamId,
      baseSpellRange: config.baseRange,
      accoutrements: accoutrements,
    );
  }

  final bottomArtifacts = bottomHex == localOwnerHex ? localArtifacts : peerArtifacts;
  final topArtifacts = bottomHex == localOwnerHex ? peerArtifacts : localArtifacts;

  final bottomAvatar = buildAvatar(
    ownerHex: bottomHex,
    artifacts: bottomArtifacts,
    idPrefix: 'acc_bottom',
    position: bottomPos,
    teamId: 'team_bottom',
    wizardName: bottomWizardName,
  );
  final topAvatar = buildAvatar(
    ownerHex: topHex,
    artifacts: topArtifacts,
    idPrefix: 'acc_top',
    position: topPos,
    wizardName: topWizardName,
    teamId: 'team_top',
  );

  battlefield.occupancy[bottomHex] = bottomPos;
  battlefield.occupancy[topHex] = topPos;

  final state = BattleState(
    config: config,
    avatars: [bottomAvatar, topAvatar],
    teams: [
      Team(id: 'team_bottom', playerIds: [bottomHex]),
      Team(id: 'team_top', playerIds: [topHex]),
    ],
    battlefield: battlefield,
    componentSeating: clockwiseComponentOrder(
      playerIds: [bottomHex, topHex],
      startPositions: [bottomPos, topPos],
      radius: config.gridRadius,
    ),
  );

  return DuelBattleSetup(state: state, localPlayerId: localOwnerHex);
}
