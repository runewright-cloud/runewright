// SPDX-License-Identifier: GPL-3.0-or-later
//
// solo_battle_setup.dart — shared BattleState construction for single-player
// sessions (Solo Practice, Spell Test Lab). Builds the two-avatar battlefield
// (local at bottom vertex, dummy one tile south of the top vertex) and
// converts a chapter's artifact loadout into WizardAvatar accoutrements.
// Extracted from SoloPracticeSettingsScreen so the Spell Test Lab can reuse
// it exactly.
//
// Pure and synchronous, deliberately: it takes an ALREADY-CERTIFIED
// [CertifiedArmor] the same way `buildDuelBattleState` does, and resolving the
// chapter binding + certifying the proof stays with the callers (via
// `certifyEquippedChapterArmor`), which are async and can show an error. This
// file must never parse a proof or read an authored `SpellAsset` field.

import 'package:rune_duel/engine/hex_grid.dart';

import '../../spells/chapter_asset.dart';
import 'accoutrement_loadout.dart';
import 'battle_state.dart';
import 'certified_armor.dart';
import 'hex_battlefield.dart';
import 'match_config.dart';
import 'wizard_avatar.dart';

/// The practice dummy's identity: an EXPLICITLY SYNTHETIC canonical public key
/// that is nobody's Runekey.
///
/// Wild Magic v2 keys on `caster x certified spell behavior x leyline`
/// (docs/WILD_MAGIC_PLAN_VNEXT.md §2), so the dummy needs a caster identity for
/// anything it casts to resolve at all — and the two obvious shortcuts are both
/// wrong. Reusing the local player's key would make the dummy magically
/// indistinguishable from its opponent; an all-zero key is the one value
/// `WildMagic.canonicalPubkeyBytes` singles out as a consensus value invented
/// from nothing, and it is also what every OTHER unidentified caster would
/// collapse onto.
///
/// So it is a fixed constant — practice stays deterministic run to run — whose
/// bytes are the ASCII of its own provenance, left-padded into a Field:
/// `utf8("Runewright/PracticeOpponent/v1")` in the low 30 bytes, high bytes
/// zero (which also keeps it comfortably below the BN254 modulus). It is
/// recognizable and distinct BY CONSTRUCTION — anyone reading the bytes can see
/// what it is, and no code path assigns it to a player — not by any
/// cryptographic argument about `Poseidon2` outputs, which this makes no claim
/// about.
///
/// It is a PRACTICE identity, never a network one: nothing signs with it, no
/// handshake authenticates it, and no match record may carry it.
const String kPracticeOpponentPubkeyHex =
    '0x000052756e657772696768742f50726163746963654f70706f6e656e742f7631';

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
///
/// [localOwnerPubkeyHex] must be the device's REAL canonical gameplay key
/// (`Identity.ownerPubkeyHex`, via `resolveLocalCasterPubkeyHex`). Practice is
/// where a player learns what their spells do, so the wizard at the bottom
/// vertex has to be the same wizard their library previews and their duels
/// cast as — Wild Magic keys on the caster, and a placeholder here would teach
/// them a different spellbook than the one they own. It is required rather
/// than defaulted for exactly that reason: there is no honest stand-in.
///
/// [armor] is the chapter's equipped Aetherial Armor, already certified by
/// `certifyEquippedChapterArmor` — equipment here and nothing more, exactly as
/// in `buildDuelBattleState`: **this function performs no proof parsing,
/// verification or interpretation.** Null means the chapter wears none, which
/// is the ordinary case.
///
/// It is seated on the LOCAL wizard only. The practice dummy stays unarmored
/// by design — it is a target, not an opponent with a spellbook — and the same
/// reasoning that gives it a synthetic identity applies: there is no chapter
/// behind it to equip anything from.
SoloBattleSetup buildSoloBattleState(
  ChapterAsset chapter,
  MatchConfig config, {
  required String localOwnerPubkeyHex,
  CertifiedArmor? armor,
  String localId = 'local',
  String dummyId = 'dummy',
}) {
  // Convert chapter artifacts → WizardAvatar accoutrements (shared helper —
  // see accoutrement_loadout.dart; ids match this function's prior inline
  // logic exactly, so this is not a behavior change).
  final accoutrements = accoutrementsFromArtifacts(chapter.artifacts, idPrefix: 'acc');

  final manaGems = accoutrements.where((a) => a.kind == AccoutrementKind.manaGem).length;
  final maxMana = config.innateManaPool + manaGems * config.manaGemPoolPerGem;

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
    ownerPubkeyHex: localOwnerPubkeyHex,
    // Earth armor raises the pool the wizard starts with — the SAME term
    // `buildDuelBattleState` applies, so a practice wizard opens on the HP a
    // duelling one would. There is no separate armor-HP bar and no max-HP cap;
    // provenance stays readable through `avatar.armor!.armorHpBonus`.
    hp: config.playerHp + (armor?.armorHpBonus ?? 0),
    mana: maxMana ~/ 2,
    maxMana: maxMana,
    position: spawnPos,
    teamId: 'solo',
    baseSpellRange: 3,
    accoutrements: accoutrements,
    armor: armor,
  );

  // Dummy opponent: one mana gem on top of its innate pool, stands still
  // (SoloBattleSession always passes unless the caller opts into scripted
  // casting — see SoloBattleSession.dummyAutoCast, used only by the Spell
  // Test Lab).
  final dummyMaxMana = config.innateManaPool + config.manaGemPoolPerGem;
  final dummy = WizardAvatar(
    playerId: dummyId,
    ownerPubkeyHex: kPracticeOpponentPubkeyHex,
    hp: config.playerHp,
    mana: dummyMaxMana,
    maxMana: dummyMaxMana,
    position: dummyPos,
    teamId: 'foe',
    baseSpellRange: 3,
    accoutrements: [
      const Accoutrement(id: 'dummy_gem', kind: AccoutrementKind.manaGem),
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
    // The dummy performs no components — it has no microphone, no hand, and
    // no choice to conceal — so the only seat at the table is the player's,
    // and they never wait on anyone (docs/SPELL_COMPONENTS_PLAN.md §5.3).
    componentSeating: [localId],
  );

  return SoloBattleSetup(state: battleState, dummyPosition: dummyPos);
}
