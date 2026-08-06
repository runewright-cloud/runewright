// SPDX-License-Identifier: GPL-3.0-or-later
//
// accoutrement_loadout.dart — converts a Chapter's public ArtifactEntry
// loadout into a WizardAvatar's Accoutrement list. Shared by
// solo_battle_setup.dart (local avatar, own chapter) and duel_battle_setup.dart
// (both avatars — the peer's loadout arrives over the wire via
// BattleSession.exchangeArtifactLoadout, LAN_BATTLE_WIREUP_PLAN.md §3.1/§3.2).
//
// Two devices building an avatar from the same ArtifactEntry list MUST
// produce byte-identical Accoutrement ids (BattleState.toCanonicalBytes()
// hashes them) — [idPrefix] plus stable index order is what keeps that
// deterministic across devices.

import '../../spells/chapter_asset.dart' show ArtifactEntry, ArtifactKind;
import 'wizard_avatar.dart';

AccoutrementKind _toAccoutrementKind(ArtifactKind kind) => switch (kind) {
      ArtifactKind.manaGem => AccoutrementKind.manaGem,
      ArtifactKind.bookmark => AccoutrementKind.bookmark,
      ArtifactKind.rodOfSpreading => AccoutrementKind.rodOfSpreading,
      ArtifactKind.counterCharm => AccoutrementKind.counterCharm,
    };

/// Converts [artifacts] into a WizardAvatar's accoutrement list, one-for-one
/// and in order. [idPrefix] namespaces the generated ids (e.g. `'acc'` for the
/// local avatar, `'peer_acc'` for a duel's peer avatar) so two avatars built
/// from identical artifact lists don't collide.
///
/// A wizard carrying no mana gem is a legal loadout: the mana pool is innate
/// (MatchConfig.innateManaPool), so nothing is silently inserted here. That
/// replaces the old behaviour, which prepended a free indestructible "core
/// gem" whenever the chapter declared none.
List<Accoutrement> accoutrementsFromArtifacts(
  List<ArtifactEntry> artifacts, {
  required String idPrefix,
}) {
  final accoutrements = <Accoutrement>[];
  for (int i = 0; i < artifacts.length; i++) {
    final a = artifacts[i];
    accoutrements.add(Accoutrement(
      id: '${idPrefix}_$i',
      kind: _toAccoutrementKind(a.kind),
      charmTrajectory: a.trajectory,
    ));
  }
  return accoutrements;
}
