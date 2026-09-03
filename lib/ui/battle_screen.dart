// SPDX-License-Identifier: GPL-3.0-or-later
//
// battle_screen.dart — in-battle HUD: battlefield grid, player stats,
// artifact counts, and the spell hand for the active chapter.
//
// Layout (portrait):
//   AppBar   — turn counter + leave button
//   Opponent strip — compact HP/mana for each non-local avatar (if any);
//     swaps to a single tapped enemy creature's HP when one is inspected
//     (see _updateInspection / _inspectedMinion)
//   Battlefield  — LayoutBuilder → BattlefieldPainter (Expanded, tappable),
//     with the 4 artifact corner tiles overlaid on the empty space around
//     the hex map (see _ArtifactCornerTile): Counter Charms top-left, Rod
//     of Wind top-right, Mana Gems bottom-right, Bookmarks bottom-left.
//     Long-press activates (currently wired for Rod of Wind only — the
//     rest await the artifact-activation rework, docs/ARTIFACT_SYSTEM_PLAN.md).
//   Action bar  — PASS / spell name / CAST
//   Player HP/MP bars
//   Spell book  — horizontal scroll of SpellCardWidgets (tap → select)

import 'dart:async' show Completer, Timer, unawaited;
import 'dart:convert' show base64Encode;
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui show Image;

import 'package:cryptography/cryptography.dart' show Sha256;
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../battle/engine/tile_entry_resolver.dart'
    show MovePathPrediction, predictAvatarMove, tileOccupied;
import '../battle/engine/line_of_sight.dart'
    show losBlockerTile, tileBeforeBlocker;
import '../battle/engine/turn_loop.dart';
import '../battle/engine/wild_magic_applicator.dart' show WildMagicEvent;
import '../battle/models/battle_state.dart';
import '../battle/models/barrier.dart';
import '../battle/models/casting_enhancements.dart' show CastingEnhancements;
import '../battle/models/creature_spec.dart' show summonSummaryFromFormula;
import '../battle/models/effect_kind.dart'
    show
        SpellAffinity,
        EffectKind,
        formulaEffects,
        formulaEffectLabels,
        kAffinityLabel,
        primaryFormulaAffinity;
import '../battle/models/hex_battlefield.dart' show hexDistance;
import '../battle/models/match_outcome.dart';
import '../battle/models/minion.dart' show Minion;
import '../battle/models/pending_delayed_spell.dart' show PendingDelayedSpell;
import '../battle/models/terrain.dart' show SlowTile, tileBlocksMovement;
import '../battle/models/status_effect_ids.dart';
import '../battle/models/wizard_avatar.dart';
import '../battle/networking/battle_session.dart';
import '../battle/networking/solo_battle_session.dart';
import '../engine/hex_grid.dart';
import '../ffi/prover.dart' as prover;
import '../ffi/srs_cache.dart';
import '../identity/identity.dart';
import '../protocol/match_session.dart' show ProofVerifier;
import '../sorcerer/vocal_scorer.dart';
import '../audio/spell_sound_player.dart';
import '../audio/spell_sound_settings.dart';
import '../spells/chapter_asset.dart';
import '../spells/enhancement_zone.dart';
import '../spells/inscribe.dart' show kInscribeTiers;
import '../spells/sighting_asset.dart';
import '../spells/spell_asset.dart';
import '../spells/spell_permission.dart';
import '../spells/spell_sound_pack.dart' show loadPackSound;
import '../spells/spell_sound_resolver.dart' show resolveSpellSound;
import '../spells/supreme_tags.dart' show deriveSupremeTags;
import '../spells/wild_magic_preview.dart'
    show
        WildMagicPreviewContext,
        activeWildMagicContext,
        overrideWildMagicContext;
import '../dev_flags.dart' show kAllowProoflessSpells;
import 'avatars/avatar_sprites.dart' show AvatarAssignment, AvatarAtlas;
import 'scenery/scenery_map.dart';
import 'scenery/scenery_painter.dart';
import 'battlefield_painter.dart';
import 'manuscript_theme.dart';
import 'safe_layout.dart';
import 'spell_card_painter.dart';
import 'dart:async';
import 'package:record/record.dart';
import '../sorcerer/mfcc.dart';
import 'widgets/hold_to_record_control.dart';
import '../sorcerer/incantation_recall.dart';
import '../sorcerer/incantation_recall_scorer.dart';
import '../sorcerer/vocabulary_profile.dart';
import '../sorcerer/vocal_enrollment.dart';
import '../sorcerer/vocal_template_source.dart';
import '../sorcerer/gesture.dart';
import '../sorcerer/gesture_capture.dart';
import '../sorcerer/gesture_classifier.dart';
import '../sorcerer/imu_sample.dart' show ImuSample;
import '../practice/gesture_enrollment.dart';
import '../practice/gesture_template_source.dart';

// ── Sightings capture (docs/SIGHTINGS_PLAN.md) ──────────────────────────────
//
// LAN duels only (§1.3): SoloBattleSession casts are scripted dummies with a
// sentinel commitment/pubkey and must never be recorded. Sightings are a
// read-only, local side effect (§1.2/§9) — never part of lockstep, never
// affects turn resolution, and a capture failure must never surface to the
// player. See _BattleScreenState._recordSightings for the disk-writing side
// of this; the pure part lives here so it's unit-testable without a widget
// harness.

/// All-zero owner_pubkey sentinel used by solo/practice avatars (see
/// solo_battle_setup.dart) — belt-and-suspenders guard in case a dummy cast
/// is ever mis-wired into a "real" session.
final _kSentinelOwnerPubkeyHex = '0x${'0' * 64}';

/// One opponent cast worth of data to persist as a [SightingAsset].
class SightingCapture {
  const SightingCapture({
    required this.opponentPubkeyHex,
    required this.commitmentHex,
    required this.spellName,
    required this.formula,
    required this.t,
    required this.tier,
    required this.manaCost,
  });

  final String opponentPubkeyHex;
  final String commitmentHex;
  final String spellName;
  final List<String> formula;
  final int t;
  final int tier;
  final int manaCost;
}

/// Pure function: derives the [SightingCapture]s to persist from one turn's
/// [resolved] spells, given [localPlayerId] and the match's [avatars].
/// [certifiedBaseManaCosts] is `TurnLoop.lastCertifiedBaseManaCosts`, keyed
/// by commitmentHex — the certified BASE cost (SIGHTINGS_PLAN.md §2), not
/// the per-cast `spell.manaCost` (always 0 on a reconstructed peer
/// SpellAsset — turn_loop.dart's decode never populates it).
///
/// Excludes: the local player's own casts, casts with no commitmentHex (the
/// wire couldn't identify the spell), casts whose caster avatar can't be
/// found in [avatars], and casts from an avatar whose `ownerPubkeyHex` is
/// empty or the all-zero solo/practice sentinel.
List<SightingCapture> sightingsFromResolved(
  List<ResolvedSpellEvent> resolved,
  String localPlayerId,
  List<WizardAvatar> avatars,
  Map<String, int> certifiedBaseManaCosts,
) {
  final captures = <SightingCapture>[];
  for (final ev in resolved) {
    if (ev.casterId == localPlayerId) continue;
    if (ev.spell.commitmentHex.isEmpty) continue;

    WizardAvatar? avatar;
    for (final a in avatars) {
      if (a.playerId == ev.casterId) {
        avatar = a;
        break;
      }
    }
    if (avatar == null) continue;
    if (avatar.ownerPubkeyHex.isEmpty ||
        avatar.ownerPubkeyHex == _kSentinelOwnerPubkeyHex) {
      continue;
    }

    captures.add(
      SightingCapture(
        opponentPubkeyHex: avatar.ownerPubkeyHex,
        commitmentHex: ev.spell.commitmentHex,
        spellName: ev.spell.name,
        formula: ev.spell.formula,
        t: ev.spell.t,
        tier: ev.spell.tier,
        manaCost: certifiedBaseManaCosts[ev.spell.commitmentHex] ?? 0,
      ),
    );
  }
  return captures;
}

/// Whether casting [spell] will resolve to an Air-flavor tileModification
/// effect (always a ConveyorTile for that pairing) -- pure/cheap, needs only
/// the spell's own formula (see effect_kind.dart formulaEffects) plus its
/// mode.
///
/// Summon-mode spells never qualify: TurnLoop._applySpell reads their element
/// sequence as a creature and returns before EffectResolver/EffectApplicator
/// run (design doc "Summons"), so no ConveyorTile is created and any picked
/// direction is discarded. Without the isSummon guard, a summon whose formula
/// happens to contain an Air tileModification triplet — e.g. the bundled
/// Basic Windhound — prompts the caster for a push direction it never uses.
bool spellNeedsConveyorDirection(SpellAsset spell) =>
    !spell.isSummon &&
    formulaEffects(spell.formula).any(
      (e) =>
          e.kind == EffectKind.tileModification &&
          e.affinity == SpellAffinity.air,
    );

/// Whether leaving the battle screen should ask first.
///
/// Only a **live** duel against a **real peer** is worth guarding. Leaving one
/// closes the session and its socket (see `_BattleScreenState.dispose`), the
/// opponent is shown "lost contact", and there is no rejoin — so a mis-tap on
/// the app-bar close button, or a stray Android back-swipe, throws away a
/// match. Once the match has ended there is nothing left to abandon, and in
/// solo/practice there is no one on the other side, so both leave with a
/// single gesture as before.
///
/// Pulled out as a pure function because it governs two call sites that must
/// not drift apart — the close button and `PopScope.canPop` — and because
/// nothing in the test suite builds a full [BattleScreen], so this is the
/// layer at which the decision can actually be pinned.
bool leavingNeedsConfirmation({
  required bool isRealDuel,
  required bool matchEnded,
}) =>
    isRealDuel && !matchEnded;

/// 0x-prefixed lowercase hex — matches duel_setup.dart's `_bytesToRootHex`
/// convention, needed here for MatchOutcome's hex-string fields.
String _bytesToHex(Uint8List bytes) =>
    '0x${bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';

bool _hexEq(String a, String b) {
  BigInt parse(String s) =>
      BigInt.parse(s.startsWith('0x') ? s.substring(2) : s, radix: 16);
  return parse(a) == parse(b);
}

enum _InputPhase { action, movement, pickingDirection }

// ── Artifact corner tiles ─────────────────────────────────────────────────────
//
// The 4 loadout artifacts (chapter_asset.dart's ArtifactKind — manaGem,
// bookmark, rodOfSpreading, counterCharm), one per corner of the battlefield.
// absorptionRod is deliberately excluded: it's summon-only (never in a
// loadout — accoutrement_loadout.dart never emits it) and out of scope per
// ARTIFACT_SYSTEM_PLAN.md §1.

// Short labels — the triangular corner tiles below only have room near their
// right-angle vertex (see _ArtifactCornerTile), not a full word or two.
const _kCounterCharmDisplay = (Icons.block, Color(0xFFB84040), 'Charms');
const _kRodOfWindDisplay = (Icons.air, Color(0xFFB8D8D8), 'Wind');
const _kManaGemDisplay = (Icons.diamond_outlined, Color(0xFF2B4D8C), 'Gems');
const _kBookmarkDisplay = (Icons.bookmark_outlined, Color(0xFF5588BB), 'Marks');

// ── Status effect display tables ─────────────────────────────────────────────

const Map<String, String> _kStatusLabel = {
  StatusEffectId.speedUp: 'Speed+',
  StatusEffectId.speedDown: 'Speed−',
  StatusEffectId.rangeUp: 'Range+',
  StatusEffectId.rangeDown: 'Range−',
  StatusEffectId.penetrating: 'Piercing',
  StatusEffectId.turbulent: 'Turbulent',
  StatusEffectId.sluggish: 'Sluggish',
  StatusEffectId.quick: 'Quick',
  StatusEffectId.nextSpellCostDouble: '2× Cost',
  StatusEffectId.chainFast: 'Chain+',
  StatusEffectId.chainSlow: 'Chain−',
  StatusEffectId.chainSurcharge: 'Cursed Chain',
  StatusEffectId.statusDormant: 'Dormant',
  StatusEffectId.haymakerDot: 'Burning',
  StatusEffectId.haymakerSlow: 'Slowed',
  StatusEffectId.haymakerStatusDrain: 'Draining Hits',
  StatusEffectId.haymakerDistanceBonus: 'Charging',
  StatusEffectId.revealCounterCharms: 'See Charms',
  StatusEffectId.revealSpells: 'See Spells',
  StatusEffectId.revealTargetTile: 'See Target',
  StatusEffectId.scryingSight: 'Scrying Sight',
};

// Buff IDs render in green; everything else renders in red.
const _kBuffIds = {
  StatusEffectId.speedUp,
  StatusEffectId.rangeUp,
  StatusEffectId.penetrating,
  StatusEffectId.quick,
  StatusEffectId.chainFast,
  StatusEffectId.haymakerDistanceBonus,
  StatusEffectId.revealCounterCharms,
  StatusEffectId.revealSpells,
  StatusEffectId.revealTargetTile,
  StatusEffectId.scryingSight,
};

// ── BattleScreen ──────────────────────────────────────────────────────────────

class BattleScreen extends StatefulWidget {
  const BattleScreen({
    super.key,
    required this.state,
    required this.localPlayerId,
    required this.chapter,
    this.session,
    this.matchId,
    this.peerBookRoot,
    this.peerBookLeafCount,
    this.peerOwnerPubkeyHex,
    this.peerRawPubkey,
    this.peerPermissions,
    this.pactIdHex,
    this.peerAvatarId,
    this.soundPlayerForTesting,
  });

  final BattleState state;
  final String localPlayerId;
  final ChapterAsset chapter;

  /// Supply a [BattleTurnSession] for network play. Defaults to [SoloBattleSession].
  final BattleTurnSession? session;

  /// The real, jointly-derived matchId from `runDuelSetup`
  /// (LAN_BATTLE_WIREUP_PLAN.md §3.2) — cross-match domain separation for
  /// TurnLoop's HashRng seeding. Null for solo/test play, matching
  /// TurnLoop.matchId's own doc comment.
  final Uint8List? matchId;

  /// Stage 2 (LAN_BATTLE_WIREUP_PLAN.md §4) — all four null together for
  /// solo/test play (unchanged behavior); all four set together for a real
  /// LAN duel, straight from `DuelSetupResult`. Turns on proof verification +
  /// cast authorization (peerBookRoot/peerOwnerPubkeyHex/peerPermissions) and
  /// Phase D signed state hashes (peerOwnerPubkeyHex's authenticated pair,
  /// peerRawPubkey — BATTLE_AUTH_PLAN §6).
  final String? peerBookRoot;

  /// The peer's chapter leaf count (SPELL_DRAW_WIRING_PLAN.md §3), declared
  /// publicly alongside [peerBookRoot] — set together in a real duel, null
  /// for solo/test play, matching TurnLoop's own doc comment.
  final int? peerBookLeafCount;
  final String? peerOwnerPubkeyHex;
  final Uint8List? peerRawPubkey;
  final List<SpellPermission>? peerPermissions;

  /// Set only when this duel is a graduation battle
  /// (docs/MASTER_APPRENTICE_PLAN.md §7.3) — the already-agreed
  /// GraduationPact's id, carried into the signed [MatchOutcome] at match
  /// end (`_handleMatchEnd`) so the settlement step can find it. Null for
  /// an ordinary duel, matching [MatchOutcome.pactIdHex]'s own
  /// [kNoGraduationPact] default.
  final String? pactIdHex;

  /// The peer's chosen avatar id (docs/AVATAR_PICKER_PLAN.md §5.2/§5.5), from
  /// `DuelSetupResult.peerAvatarId`. Null for solo/test play — matching every
  /// other peer-* field's convention — in which case the dummy keeps its
  /// deterministic default sprite. Presentation only: installed into
  /// [_BattleScreenState._avatarAssignment], never read by engine code.
  final String? peerAvatarId;

  /// Test-only injection point: constructing an [SpellSoundPlayer] pool is
  /// harmless, but the moment it actually plays a clip it constructs a real
  /// `audioplayers.AudioPlayer`, which throws (uncatchably, from inside an
  /// unawaited async init — see docs/SPELL_SOUND_PACK_PLAN.md §9) under
  /// `flutter test`, no platform plugin being registered. A widget test that
  /// needs to observe the reveal-plays-a-sound behavior supplies a fake
  /// subclass here instead. Null in every real screen construction.
  final SpellSoundPlayer? soundPlayerForTesting;

  @override
  State<BattleScreen> createState() => _BattleScreenState();
}

class _BattleScreenState extends State<BattleScreen>
    with TickerProviderStateMixin {
  List<SpellAsset?> _spells = [];
  late TurnLoop _loop;
  late AnimationController _pulseController;

  // Lazily constructed, same reasoning as practice_screen.dart's _player
  // getter: an AudioPlayer is a hard failure under `flutter test`, and a
  // battle that reveals zero spells (a very early forfeit) should never pay
  // for one. Settings are loaded once and cached -- volume/mute changes made
  // from Settings mid-match take effect on the next resolution, not
  // retroactively on an in-flight clip.
  SpellSoundPlayer? _soundPlayerOrNull;
  SpellSoundPlayer get _soundPlayer =>
      widget.soundPlayerForTesting ?? (_soundPlayerOrNull ??= SpellSoundPlayer());
  SpellSoundSettings _soundSettings = const SpellSoundSettings();

  /// The library-wide preview context this duel displaces, restored on
  /// dispose. Captured at construction rather than in initState so it is
  /// well-defined on every path dispose can be reached by. See initState.
  final WildMagicPreviewContext _wildMagicContextBeforeDuel =
      activeWildMagicContext.value;

  // Stage 2 verifier init (see _initTurnLoop): true once _loop is safe to
  // read AND the battle-start opening deal has run (TurnLoop.startBattle), so
  // turn 1 is fully castable. build() gates the interactive battle UI behind
  // this — nothing above (event handlers, callbacks) runs before a player can
  // interact with a rendered widget, so this is the only guard needed against
  // reading `_loop` before it's assigned.
  bool _loopReady = false;

  // Init sequencing: _loop is constructed and _spells resolved on two
  // concurrent async paths (_initTurnLoop, _loadSpells). Once BOTH are done
  // (tracked by these flags), _maybeSetLocalChapterCommitments fires the
  // battle-start deal exactly once (_battleStarting guards re-entry) before
  // flipping _loopReady. See _startBattleIfNeeded.
  bool _loopConstructed = false;
  bool _spellsLoaded = false;
  bool _battleStarting = false;

  // Fail-closed (CLAUDE.md quality bar): set if VK/SRS/identity init for a
  // real duel throws. When non-null, build() shows a blocking error instead
  // of ever falling back to trusting peer casts unverified.
  String? _verifierInitError;

  // Same gate, one phase later: set when TurnLoop.runTurn throws mid-turn in
  // a REAL duel (state hash mismatch, a failed reveal/proof check, a peer
  // forfeit). At that point this device's state and the peer's have already
  // diverged, so the match cannot be played on — see the catch in
  // [_submitTurn]. Null in solo/practice, where a turn error is local and
  // recoverable and stays a snackbar.
  String? _turnError;

  // Set when the PEER forfeits (BattleSession.peerForfeit). The mirror image
  // of [_turnError]: there, this device caught the violation and stopped; here
  // the other device caught one and stopped, and without this we would keep
  // waiting for frames that are never coming. Kept separate from [_turnError]
  // so the message can say whose device ended the match — "you cheated" and
  // "they think you cheated" are very different things to read at 2am.
  String? _peerForfeitReason;

  // Set when the peer's connection drops with no forfeit
  // (BattleSession.peerConnectionLost) — backgrounded app, locked screen,
  // Wi-Fi range, killed process. Distinct from [_peerForfeitReason] because
  // nobody diagnosed anything here: the duel just lost its other half, and
  // the honest message is "we can't reach them", not "their device ended it".
  String? _connectionLostReason;

  // Cast animation — glowing orb(s) for the spell(s) resolved on the most
  // recent turn. Fixed for one playback of _castAnimController; replaced
  // (and the controller restarted) each time a new turn resolves with casts.
  late AnimationController _castAnimController;
  List<CastAnimation> _castAnimations = const [];
  List<ConveyorChainAnimation> _conveyorChainAnimations = const [];

  // Wizard movement — this turn's walks, played back from inside runTurn the
  // instant the engine resolves them (see _playAvatarWalks), which is both the
  // turn's real chronology (movement is Phase 3; casts are Phase 4+) and the
  // only moment at which the tokens haven't already jumped: the painter draws
  // live engine state every frame, so playback deferred until runTurn returns
  // shows the destination first and the walk second.
  //
  // Cleared the moment playback ends. That is load-bearing: knockback, Zephyr
  // and friends move the same wizards later in the same turn, and a lingering
  // animation would pin their token to where the movement phase left them. See
  // BattlefieldPainter.avatarMoveAnimations.
  late AnimationController _moveAnimController;
  List<AvatarMoveAnimation> _avatarMoveAnimations = const [];

  // The Summons phase's equivalent, driven by the same controller (the two
  // playbacks never overlap — avatars walk in Phase 3, creatures in Phase 5b).
  // Same clear-the-moment-playback-ends rule, and load-bearing for the same
  // reason.
  List<MinionMoveAnimation> _minionMoveAnimations = const [];

  // Attacks — wizard haymakers (Phase 4b) and creature strikes (Phase 5b),
  // played back the moment the engine resolves them, exactly like the walks.
  // Its own controller rather than _moveAnimController's, because a creature's
  // strike plays *concurrently* with the lunge that delivers it: one timeline
  // could not hold both without the blow being early or the lunge being late.
  // Cleared the instant playback ends — see BattlefieldPainter.attackAnimations.
  late AnimationController _attackAnimController;
  List<AttackAnimation> _attackAnimations = const [];

  /// How long one attack takes to play once it starts. Short: a swipe is a
  /// beat, not a scene, and every turn with a melee creature on the board pays
  /// this cost.
  static const _kAttackPlayback = Duration(milliseconds: 620);

  /// Decoded wizard sprite sheet, or null until it lands (or if it failed) —
  /// the painter falls back to the placeholder disc tokens either way.
  ui.Image? _avatarAtlas;

  /// Which sprite each wizard wears. Starts at the deterministic default
  /// (every wizard gets a Hero from their playerId) and gains explicit
  /// entries as the local and peer avatar choices load in — see
  /// [_loadLocalAvatarChoice] and AvatarAssignment.explicit's doc comment for
  /// the property both entries together exist to keep.
  AvatarAssignment _avatarAssignment = const AvatarAssignment();

  // Phase A of the local player's own in-flight cast this turn: the held,
  // pulsing orb at the cast tile, set the instant the cast is confirmed and
  // cleared once the turn resolves and _castAnimations takes over for the
  // travel+burst leg (phase B). Null whenever no cast is pending -- see
  // _commitAction / _submitTurn / _pendingCastOrbs.
  HexCoord? _pendingCastOrigin;
  SpellAffinity? _pendingCastAffinity;

  // Turn interaction state — two phases: action then movement.
  _InputPhase _phase = _InputPhase.action;
  SpellAsset? _selectedSpell;

  /// The hand slot [_selectedSpell] was selected from — the only
  /// duplicate-safe identity for a card when the hand holds several copies
  /// of the same Basic spell's grid (docs/BASIC_SPELLS_PLAN.md §7). Carried
  /// into SpellCastAction/MysterySpellCastAction.handIndex so TurnLoop can
  /// prove membership for the SPECIFIC copy cast, not just "a" copy.
  int? _selectedHandIndex;
  HexCoord? _targetHex; // spell target (action phase)
  TurnAction? _pendingAction;
  List<HexCoord> _movePath = const []; // movement path (movement phase)
  bool _isBusy = false;

  // ── Match end (MASTER_APPRENTICE_PLAN.md §4) ────────────────────────────────
  //
  // Set the instant TurnLoop.runTurn reports the win condition fired, so no
  // further turn is submittable (_submitTurn checks this alongside _isBusy).
  // _matchEndSummary is populated slightly later, once _handleMatchEnd's
  // (possibly async, real-duel-only) signed MatchOutcome exchange settles --
  // see that method's doc comment. Kept separate from _isBusy because a
  // match-ending turn already resets _isBusy via _resetTurn, and the two
  // states are not otherwise coupled.
  bool _matchEnded = false;
  _MatchEndSummary? _matchEndSummary;

  /// Loaded once for a real duel (see _initTurnLoop) — kept only to sign the
  /// end-of-match MatchOutcome (_handleMatchEnd). Null for solo/practice,
  /// where there is no peer to settle an outcome with.
  Identity? _localIdentity;

  // Airy Scrying Pool reveal (MESH_ARCHITECTURE.md §13b): the opponent's
  // committed spell-target tile for this turn, if an active DivinationLink
  // resolved one. Set asynchronously by _beginTurnAndRevealScry once
  // _commitAction's TurnLoop.beginTurn() call returns; null otherwise. Shown
  // on the battlefield during the movement phase so the scrying player can
  // make an informed move before submitting the turn.
  HexCoord? _scryRevealedTile;

  // Conveyor push-direction prompt (pickingDirection phase): the tile the
  // ConveyorTile is about to be created on, and the completer _onTapBattlefield
  // resolves when the player taps one of its 6 highlighted neighbor hexes
  // (or null on cancel). See _pickConveyorDirection.
  HexCoord? _conveyorPickOrigin;
  Completer<HexCoord?>? _conveyorPickCompleter;

  // Resolution-phase melee prompt: set by _pickMeleeTarget (TurnLoop's
  // meleeTargetPicker callback, invoked mid-runTurn once movement has
  // resolved). _isBusy is already true by this point (we're inside
  // _submitTurn's await), so _onTapBattlefield's usual busy-guard is
  // special-cased for this state — see its top.
  bool _pickingMelee = false;
  List<HexCoord> _meleeCandidates = const [];
  Completer<HexCoord?>? _meleePickCompleter;

  // Post-resolution free-move prompt — an Airy Barrier burst, a Boost run, or
  // both: set by _pickFreeMoveDirection (TurnLoop's freeMoveDirectionPicker
  // callback, invoked after every spell for the turn has resolved). Same shape
  // and the same _isBusy caveat as the melee prompt above, except the player
  // builds a *path* here (a Boost can run several tiles) and commits it with
  // the MOVE button, so _freeMovePath accumulates taps until then.
  bool _pickingFreeMove = false;
  FreeMoveGrant _freeMoveGrant = FreeMoveGrant.none;
  List<HexCoord> _freeMovePath = const [];
  Completer<List<HexCoord>?>? _freeMovePickCompleter;

  // UI-facing phase label for the phase banner, driven by TurnLoop.onPhase
  // for the two internal phases (Summons, Resolution) the pre-submission
  // _InputPhase can't see — see _phaseLabel.
  TurnPhase? _submittingPhase;

  // Resolution-phase MtG-style card reveal sequence (see _playResolvedSpellSequence):
  // incantation thumbnails move to this neutral tray after their 2s card
  // reveal, and are cleared at the start of the next turn's sequence ("end
  // of turn"). Long-tapping a thumbnail re-opens its card.
  List<_ResolvedThumbnail> _incantationTray = [];

  // commitmentHex-independent lookup so a live on-grid summon's long-tap can
  // re-show the exact SpellAsset that created it (for the full card + live
  // HP) — keyed by Minion.id, populated as each summon's ResolvedSpellEvent
  // is processed. Not pruned on death (match-scoped, small) — deliberately,
  // since a copy can outlive the original it borrows its card from (see
  // _cardForMinion).
  final Map<String, SpellAsset> _summonSpellByMinionId = {};

  // Cast-time enhancement choice — zone tag ('fire'/'air'/'water'/'earth')
  // or null for neutral (no enhancement). Eligibility is
  // _selectedSpell.supremeTags; see _EnhancementPicker.
  String? _selectedEnhancement;

  // ── Phase 0: artifact activation (docs/ARTIFACT_SYSTEM_PLAN.md §10) ────────
  //
  // Every loadout artifact is passive + one consumable activation, at most one
  // per player per turn, declared publicly BEFORE the action is committed.
  // That ordering is the mechanic: spending anything drops your own counter
  // charms for the turn, and the opponent sees it while they can still change
  // their cast.
  //
  // As of 2026-07-31 this is no longer a forced full-screen prompt at the top
  // of the turn: the main phase is free to browse (hand, board) and a
  // long-press on a corner tile declares and fires the exchange right then —
  // so its effect (mana, a redrawn hand, the rod bonus) lands before the
  // player picks a spell, if that's the order they want. A player who commits
  // a spell without ever long-pressing anything gets the implicit "declared
  // nothing" path TurnLoop.beginArtifactPhase always supported (see
  // [_commitAction]). A short tap on a tile still just explains it.

  /// This turn's dedicated Phase-0 entropy/rod-roll exchange
  /// (TurnLoop.beginArtifactEntropy) is fired eagerly and unconditionally —
  /// it isn't gated on any player decision — so it's already settled by the
  /// time the player looks at the board. See [_beginArtifactEntropyForTurn].
  bool _artifactEntropyStarted = false;

  /// Guards the corner-tile long-press against firing twice while the
  /// Phase-0 exchange it started is still in flight.
  bool _artifactPhaseInFlight = false;

  /// True once this turn's Phase-0 declaration exchange has resolved (with
  /// or without an actual declaration) — the one-per-turn budget is spent
  /// either way, so a further long-press is a no-op.
  bool _artifactPhaseResolved = false;

  /// Both sides' settled declarations for the current turn — refreshed once
  /// the Phase-0 exchange completes. Drives the corner tiles' outlined
  /// ("mine") / dimmed ("charms down") states and the opponent toast (see
  /// [_beginArtifactPhaseForTurn]).
  ArtifactActivationRound _artifactRound = const ArtifactActivationRound();

  bool get _localCharmsDown => _artifactRound.local != null;

  int _accoutrementCount(WizardAvatar? avatar, AccoutrementKind kind) =>
      avatar?.accoutrements.where((a) => a.kind == kind).length ?? 0;

  /// Short tap on any of the four corner tiles: a read-only reminder of what
  /// that artifact does.
  void _onArtifactCornerTap(AccoutrementKind kind) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(_artifactHelpText(kind))),
    );
  }

  /// Long-press on a corner tile: declare that artifact's activation and
  /// fire the Phase-0 exchange immediately, so its effect is visible before
  /// the player picks a spell. No-ops (falling back to the tap's help text)
  /// for counter charm (never declarable), a kind the wizard holds none of,
  /// or once this turn's declaration has already been made/settled.
  void _onArtifactCornerLongPress(AccoutrementKind kind) {
    if (_isBusy || _phase != _InputPhase.action) return;
    if (_artifactPhaseInFlight || _artifactPhaseResolved) return;
    if (!kActivatableArtifactKinds.contains(kind) ||
        _accoutrementCount(_local, kind) == 0) {
      _onArtifactCornerTap(kind);
      return;
    }
    _localArtifactDeclaration = kind;
    unawaited(_beginArtifactPhaseForTurn());
  }

  /// This turn's local declaration, set by [_onArtifactCornerLongPress]
  /// before it fires the Phase-0 exchange. Read once by [_pickArtifactActivation]
  /// and never mutated after that — the exchange is one-shot per turn.
  AccoutrementKind? _localArtifactDeclaration;

  static String _artifactHelpText(AccoutrementKind kind) => switch (kind) {
    AccoutrementKind.manaGem =>
      'Mana Gem — passive: +100 max mana and +10 regen each. '
          'Spend one for an instant 100 mana (the pool shrinks first).',
    AccoutrementKind.counterCharm =>
      'Counter Charm — passive: 5% per unspent charm for your melee to '
          'shatter a gem or wither a foe’s spell. Fires its counter on its '
          'own; it has no activation to spend.',
    AccoutrementKind.bookmark =>
      'Bookmark — passive: +1 hand size each. '
          'Burn one to redraw your whole hand, ready next turn.',
    AccoutrementKind.rodOfSpreading =>
      'Rod of Wind — passive: 10% per rod for +1 movement next turn. '
          'Spend one for +1 effect radius (or minion size) on this turn’s cast.',
    AccoutrementKind.absorptionRod =>
      'Absorption Rod — halves the duration of timed effects from an '
          'incoming spell, then is consumed. No activation.',
  };

  static String _artifactLabel(AccoutrementKind kind) => switch (kind) {
    AccoutrementKind.manaGem => 'Mana Gem',
    AccoutrementKind.counterCharm => 'Counter Charm',
    AccoutrementKind.bookmark => 'Bookmark',
    AccoutrementKind.rodOfSpreading => 'Rod of Wind',
    AccoutrementKind.absorptionRod => 'Absorption Rod',
  };

  /// TurnLoop's [ArtifactActivationPicker]: no longer a blocking prompt —
  /// resolves immediately with whatever [_onArtifactCornerLongPress] already
  /// staged in [_localArtifactDeclaration] (filtered to what TurnLoop says is
  /// actually [available], in case a gem/rod/bookmark got consumed by
  /// something else between the long-press and this call), or null if the
  /// player never long-pressed anything.
  Future<AccoutrementKind?> _pickArtifactActivation(
    List<AccoutrementKind> available,
  ) async {
    final declared = _localArtifactDeclaration;
    return available.contains(declared) ? declared : null;
  }

  /// Fires this turn's dedicated entropy exchange (TurnLoop.beginArtifactEntropy)
  /// — unconditional, not gated on any declaration, so the rod-passive roll is
  /// already settled before the player looks at their hand. Fire-and-forget
  /// from the two places a turn begins (battle start, and right after the
  /// previous turn resets). Errors are swallowed here for the same reason
  /// [_beginArtifactPhaseForTurn] swallows them: a withheld reveal is a
  /// lockstep break that resurfaces wherever the turn actually gets
  /// submitted.
  Future<void> _beginArtifactEntropyForTurn() async {
    if (_matchEnded || _artifactEntropyStarted) return;
    _artifactEntropyStarted = true;
    try {
      await _loop.beginArtifactEntropy();
    } catch (_) {
      // Deliberately silent — see the doc comment above.
    }
  }

  /// Opens (or joins, if already in flight/settled) the turn's Phase-0
  /// declaration exchange. Called from three places: a corner-tile
  /// long-press (the player declares something), [_commitAction] (a safety
  /// net so the implicit "declared nothing" path still updates the UI and
  /// shows the opponent toast even if the player never long-pressed
  /// anything), and nowhere else — this is deliberately NOT fired eagerly at
  /// the top of the turn anymore, so the main phase stays free to browse.
  ///
  /// TurnLoop memoizes the phase, so whichever caller gets here first does
  /// the real work; the other(s) just await the same Future. Errors are
  /// swallowed here on purpose: a withheld Phase-0 reveal is a lockstep
  /// break, and the memoized failure re-throws out of `beginTurn` at cast
  /// time, where [_beginTurnAndRevealScry] and [_submitTurn] already surface
  /// it as a blocking error. Reporting it twice would just race two dialogs.
  Future<void> _beginArtifactPhaseForTurn() async {
    if (_matchEnded || _artifactPhaseInFlight) return;
    _artifactPhaseInFlight = true;
    try {
      final round = await _loop.beginArtifactPhase();
      if (!mounted) return;
      final peerJustRevealed = !_artifactPhaseResolved && round.peer != null;
      setState(() {
        _artifactRound = round;
        _artifactPhaseResolved = true;
      });
      if (peerJustRevealed) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Opponent spent a ${_artifactLabel(round.peer!)} — '
              'their counter charms are down this turn',
            ),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } catch (_) {
      // Deliberately silent — see the doc comment above.
    } finally {
      _artifactPhaseInFlight = false;
    }
  }

  // Earth/Mystery only: chosen delay in turns (0 = fire immediately).
  int _mysteryDelay = 0;

  // A Mystery cast's local secret, staged when CAST is pressed and promoted
  // to _myPendingMysterySecrets only once _submitTurn's runTurn call
  // actually succeeds — a turn that fails to send must not leave behind a
  // reveal the engine never created a matching PendingDelayedSpell for.
  _PendingMysterySecret? _stagedMysterySecret;
  final List<_PendingMysterySecret> _myPendingMysterySecrets = [];

  // Status-effect inspection: null = show local player; non-null = show opponent.
  WizardAvatar? _inspectedAvatar;

  // Opponent-strip inspection: null = default strip (all opposing wizards);
  // non-null = the last-tapped enemy creature, shown in its place (HP only —
  // minions have no mana). Mutually exclusive with _inspectedAvatar being
  // set for the same tap; see _updateInspection.
  Minion? _inspectedMinion;

  // Battlefield geometry — tracked from LayoutBuilder so tap handler can convert
  double _hexSize = 20;
  Offset _fieldCenter = Offset.zero;

  // ── Scenery backdrop (purely cosmetic; see lib/ui/scenery/) ─────────────────
  // Seeded from the duel's shared matchId so both devices see the same
  // landscape; solo play gets a fresh local seed per battle. Fixed at initState
  // so the terrain doesn't reshuffle on rebuild.
  late final int _scenerySeed;
  SceneryMap? _scenery;
  ui.Image? _sceneryAtlas;

  // RenderBox key on the battlefield paint area, so a tile's local pixel
  // (in _fieldCenter/_hexSize space) can be mapped to a global screen point —
  // used to grow a resolution-phase spell card out of the tile it just hit.
  final GlobalKey _battlefieldKey = GlobalKey();

  // RenderBox key on the incantation tray, so a resolving card can reverse-
  // bloom toward where its thumbnail lands (see _thumbnailTarget).
  final GlobalKey _incantationTrayKey = GlobalKey();

  // Resolution-reveal hold-back: battlefield effects created this turn that
  // haven't had their spell's card resolve yet. Passed to the painter, which
  // skips drawing them until _playResolvedSpellSequence reveals each spell's
  // set. Populated from the resolved events' created* handles at turn end.
  Set<String> _hiddenCloudIds = const {};
  Set<HexCoord> _hiddenTileHexes = const {};
  Set<String> _hiddenMinionIds = const {};

  // The same hold-back for the window those three sets can't cover: while
  // runTurn is in flight the engine creates effects between network awaits, and
  // the painter — which repaints every frame off _pulseController, not off
  // rebuilds — would draw each one the instant it appeared, seconds before its
  // card. Non-null only for the duration of one runTurn call; see
  // ResolutionBaseline and _submitTurn.
  ResolutionBaseline? _resolutionBaseline;

  // The one effect group currently blooming into view (0.5s), scaled up out
  // of the tile its spell hit. Driven by _effectBloomController; null when no
  // reveal is in flight.
  EffectBloom? _effectBloom;
  late AnimationController _effectBloomController;

  // True while a resolution reveal that will produce at least one incantation
  // thumbnail is running. Keeps the (possibly still-empty) tray mounted so a
  // resolving card can measure it and reverse-bloom into the exact slot its
  // thumbnail will land in — even for the turn's first incantation.
  bool _revealReservesTray = false;

  // ── Spell components (docs/SPELL_COMPONENTS_PLAN.md) ───────────────────────
  //
  // Vocal and somatic share ONE capture window — the CAST press-and-hold —
  // because segmentation is part of both sensor paths and enrollment is
  // press-delimited for both. Whichever components the match enabled open on
  // the same press and close on the same release.
  VocalScorer? _vocalScorer;
  bool _isCapturingVoice = false;

  /// True while the CAST hold is open — either component. Drives the
  /// performing banner and blocks the action bar.
  bool get _isPerformingComponents => _isCapturingVoice || _isCapturingGesture;

  bool get _vocalOn => widget.state.config.vocalComponents;
  bool get _somaticOn => widget.state.config.somaticComponents;
  bool get _componentsOn => widget.state.config.componentsEnabled;

  /// Decides which slot was spoken at each position of a held incantation.
  IncantationRecallScorer? _recallScorer;

  /// Mic capture for one held cast. The window is press-delimited, matching
  /// enrollment exactly — hold_to_record_control.dart's header requires it:
  /// if enrollment is press-delimited but live capture is not, templates are
  /// cut differently from live queries and every DTW distance is skewed.
  AudioRecorder? _castRecorder;
  StreamSubscription<Uint8List>? _castSub;
  BytesBuilder? _castPcm;

  /// What the caster just recited, waiting to be attached to the cast.
  IncantationRecall? _pendingRecall;

  // ── Somatic components ─────────────────────────────────────────────────────

  /// IMU capture for one held cast. Same press-delimited window as the mic
  /// above and as gesture enrollment — SOMATIC_GESTURE_PLAN.md §7 requires
  /// exactly one segmentation mechanism, since templates cut differently from
  /// live queries skew every DTW distance.
  GestureCapture? _gestureCapture;
  bool _isCapturingGesture = false;

  /// The player's enrolled reps, loaded once per match. Null until loaded (and
  /// after a failed load): with no templates every gesture resolves to
  /// neutral, which is the correct un-calibrated default — a cast with no
  /// enhancement, never a guessed one.
  Map<Gesture, List<List<List<double>>>>? _gestureTemplates;

  /// Shipped constants — grid-searched through
  /// test/sorcerer/gesture_confusion_e2e_test.dart, never hand-tuned here.
  static const _gestureClassifier = GestureClassifier();

  // ── Sequential casting (SPELL_COMPONENTS_PLAN.md §5.2) ─────────────────────

  /// False while an earlier player in this turn's order is still performing.
  /// Gates the LOCK-IN only: selecting a spell, picking a target and browsing
  /// the hand stay live throughout, which is what lets a player hear their
  /// opponent's incantation and change their mind before committing.
  bool _componentSlotOpen = true;

  /// Guards against arming the same turn's wait twice (the action phase is
  /// re-entered on every rebuild path that resets the turn).
  int? _componentSlotArmedForTurn;

  @override
  void initState() {
    super.initState();
    _startStallWatchdog();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat();
    _castAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    );
    _effectBloomController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
    // One walk, however many tiles it covers — see _walkStateAt. Long enough
    // that a two-tile move reads as walking, short enough that it never feels
    // like a wait before the spells resolve.
    _moveAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    // Duration is set per playback (see _playAttacks): an attack riding a walk
    // has to wait out the lunge before it lands, and the wait is part of the
    // controller's own timeline.
    _attackAnimController = AnimationController(
      vsync: this,
      duration: _kAttackPlayback,
    );
    // Cards opened during this duel must preview their wild magic exactly as
    // this duel will resolve it: as the LOCAL AVATAR (the identity TurnLoop
    // keys the local caster on — `_casterOwnerPubkeyHex`, resolved from
    // `WizardAvatar.ownerPubkeyHex`) under the MATCH's leyline. The host is
    // authoritative over MatchConfig, so a guest fights under their host's
    // tradition and their whole library finds different wild magic for the
    // duration (WILD_MAGIC_PLAN.md §7.5). Restored in dispose().
    overrideWildMagicContext(
      WildMagicPreviewContext(
        casterPubkeyHex: _localAvatarOwnerPubkeyHex(),
        leyline: widget.state.config.leyline,
      ),
    );
    _initScenery();
    unawaited(_loadAvatarAtlas());
    _seedPeerAvatarChoice();
    unawaited(_loadLocalAvatarChoice());
    _loadSpells();
    if (_vocalOn) unawaited(_initVocalComponents());
    if (_somaticOn) unawaited(_initSomaticComponents());
    _initTurnLoop();
    _listenForPeerForfeit();
    unawaited(_loadSoundSettings());
  }

  /// The identity this duel's local casts are keyed on for Wild Magic — the
  /// local `WizardAvatar.ownerPubkeyHex`, i.e. exactly what
  /// `TurnLoop._casterOwnerPubkeyHex` resolves for [BattleScreen.localPlayerId]
  /// (WILD_MAGIC_PLAN_VNEXT.md §2). Reading the avatar rather than the device's
  /// own identity is what makes the card and the duel agree by construction:
  /// whatever the avatar was seated with is what will actually cast.
  ///
  /// Null when the state has no avatar for the local player or its key is a
  /// stub, which previews as no wild magic rather than as some other wizard's.
  String? _localAvatarOwnerPubkeyHex() {
    final hex = _local?.ownerPubkeyHex;
    return (hex == null || hex.isEmpty) ? null : hex;
  }

  Future<void> _loadSoundSettings() async {
    final settings = await SpellSoundSettings.load();
    if (!mounted) return;
    setState(() => _soundSettings = settings);
  }

  /// The mute control D-4/E-4 requires be reachable from inside battle, not
  /// only from Settings — see the AppBar action in [build].
  Future<void> _toggleSoundMute() async {
    final updated = _soundSettings.withMuted(!_soundSettings.muted);
    setState(() => _soundSettings = updated);
    await updated.save();
  }

  /// Ends the match on THIS device when the peer's device forfeits.
  ///
  /// Subscribed once, for the whole match, and never awaited by the turn
  /// sequence — a forfeit arrives asynchronously, typically while we are
  /// blocked on an exchange the peer has already abandoned. Solo/practice
  /// sessions expose a future that never completes, so this is a no-op there.
  void _listenForPeerForfeit() {
    final session = widget.session;
    if (session == null) return;
    unawaited(
      session.peerForfeit.then((reason) {
        if (!mounted) return;
        setState(() => _peerForfeitReason = reason);
      }),
    );
    // Same subscription shape, the other way a duel loses its peer. Gated on
    // [_matchEnded]: at a normal finish both sides tear their sockets down,
    // and whichever closes second would otherwise raise a connection-lost
    // error over the top of the result screen.
    unawaited(
      session.peerConnectionLost.then((reason) {
        if (!mounted || _matchEnded) return;
        setState(() => _connectionLostReason = reason);
      }),
    );
  }

  /// Picks this battle's backdrop seed and kicks off the atlas decode.
  ///
  /// In a LAN duel the seed is derived from the shared `matchId`, so both
  /// devices generate the same landscape without exchanging a byte — the map is
  /// a pure function of a value they already agree on. Solo play has no peer to
  /// agree with, so it just takes fresh local entropy each battle.
  ///
  /// The atlas decode is async; until it lands the painter draws nothing and
  /// the scaffold colour shows through, exactly as before this feature existed.
  void _initScenery() {
    final matchId = widget.matchId;
    _scenerySeed = matchId != null
        ? scenerySeedFromBytes(matchId)
        : Random().nextInt(1 << 31);
    unawaited(_loadSceneryAtlas());
  }

  /// Decodes the wizard sprite sheet. Same fail-soft contract as the scenery
  /// atlas: a missing or corrupt pack must never take the battle down, it just
  /// leaves every wizard as the placeholder disc token.
  Future<void> _loadAvatarAtlas() async {
    try {
      final image = await AvatarAtlas.load();
      if (mounted) setState(() => _avatarAtlas = image);
    } catch (e) {
      debugPrint('avatars: atlas load failed — $e');
    }
  }

  /// Installs [BattleScreen.peerAvatarId] into [_avatarAssignment] under the
  /// peer's playerId. Synchronous (the id already arrived with the widget,
  /// no storage read needed) and safe to call even when it's null — a
  /// solo/test dummy simply contributes no entry. In a LAN duel
  /// `playerId == ownerPubkeyHex` (duel_battle_setup.dart: "Player ids are
  /// the two owner hex strings themselves"), so [widget.peerOwnerPubkeyHex]
  /// is the correct key here.
  void _seedPeerAvatarChoice() {
    final peerId = widget.peerOwnerPubkeyHex;
    final peerAvatarId = widget.peerAvatarId;
    if (peerId == null || peerAvatarId == null || peerAvatarId.isEmpty) return;
    _avatarAssignment = AvatarAssignment(
      explicit: {..._avatarAssignment.explicit, peerId: peerAvatarId},
    );
  }

  /// Loads the local player's saved avatar choice and installs it into
  /// [_avatarAssignment] under [BattleScreen.localPlayerId]. Wrapped in
  /// try/catch for the same reason settings_screen.dart's `_loadSeed` is:
  /// secure storage has no platform channel under `flutter test`, and a
  /// failure here should just leave the deterministic default in place, not
  /// take the battle down.
  Future<void> _loadLocalAvatarChoice() async {
    try {
      final avatarId = await Identity.loadAvatarId();
      if (avatarId == null || avatarId.isEmpty || !mounted) return;
      setState(() {
        _avatarAssignment = AvatarAssignment(
          explicit: {..._avatarAssignment.explicit, widget.localPlayerId: avatarId},
        );
      });
    } catch (e) {
      debugPrint('avatars: local avatar choice load failed — $e');
    }
  }

  Future<void> _loadSceneryAtlas() async {
    try {
      final image = await SceneryAtlas.load();
      if (mounted) setState(() => _sceneryAtlas = image);
    } catch (e) {
      // A missing or corrupt atlas must never take the battle down: log it and
      // leave the backdrop unpainted.
      debugPrint('scenery: atlas load failed — $e');
    }
  }

  /// Returns the backdrop for the current panel, generating (or re-generating,
  /// on a resize that exposes more ground) as needed.
  ///
  /// Called from within `build`, so it deliberately does not `setState`: the
  /// result is consumed by the same build pass that produced it.
  SceneryMap _sceneryFor(Size panel, double hexSize) {
    final needed = sceneryRadiusForPanel(panel, hexSize);
    final cached = _scenery;
    if (cached != null && cached.radius >= needed) return cached;
    return _scenery = generateSceneryMap(
      seed: _scenerySeed,
      radius: needed,
      // Band the terrain against the battlefield itself, so the arena looks
      // like the region it is named for and the extremes sit out past the edge.
      focusRadius: widget.state.config.gridRadius,
    );
  }

  /// Constructs [_loop]. For solo/test play (no session, or a
  /// [SoloBattleSession]) this resolves immediately with `verifyProof`/
  /// `vkBytes`/`signMessage` all null, exactly as before Stage 2 existed.
  ///
  /// For a real LAN duel, this loads the agreed tier's bundled VK asset,
  /// extracts the circuit bytecode, and initializes the SRS/CRS cache
  /// (`initSrsCached`) — required before `verify_ultra_honk`'s first call
  /// even though this device never proves in the match (CLAUDE.md Bug-
  /// Avoidance #4: a pure verifier that never proves in that session never
  /// initializes the global CRS otherwise). Also reloads the local
  /// [Identity] to bind `TurnLoop.signMessage` for Phase D's signed state
  /// hash (BATTLE_AUTH_PLAN §6) — cheap and side-effect-free
  /// (`Identity.loadOrCreate` just re-reads secure storage).
  ///
  /// Fail-closed: any failure here (network down on first SRS download,
  /// missing asset, etc.) sets [_verifierInitError] and the match never
  /// starts, rather than silently falling back to trusting peer casts
  /// unverified (CLAUDE.md quality bar — "a check that fails open is worse
  /// than no check").
  /// True for a LAN duel against a real peer; false for solo/practice, where
  /// there is no peer to verify and [SoloBattleSession] stands in.
  bool get _isRealDuel {
    final session = widget.session;
    return session != null && session is! SoloBattleSession;
  }

  Future<void> _initTurnLoop() async {
    final session = widget.session;
    final isRealDuel = _isRealDuel;

    ProofVerifier? verifyProof;
    Map<int, Uint8List>? vkByTier;
    Future<List<int>> Function(List<int>)? signMessage;

    if (isRealDuel) {
      try {
        // ALL three tiers, not just the match's negotiated one. Each spell is
        // proven at the smallest tier covering its own T, so a duel routinely
        // has to verify proofs from tiers other than config.tier. Loading only
        // that one made every such cast abort in barretenberg with
        // "num_public_inputs mismatch with VK" and forfeit the match. All three
        // VKs are already bundled (see pubspec.yaml assets); they are a few KB
        // each, so there is nothing to gain by loading them lazily.
        vkByTier = {
          for (final t in kInscribeTiers)
            t: (await rootBundle.load('assets/circuits/ca_v2_4_tier$t.vk'))
                .buffer
                .asUint8List(),
        };
        // The SRS still initializes from the LARGEST tier's bytecode: it must
        // cover the biggest proof this device might verify, and the cache is
        // sized to the tier-48 floor regardless of which tier triggers it
        // (see srs_cache.dart). Sizing it from config.tier would leave a
        // tier-12 match unable to verify a tier-48 cast.
        final tier = kInscribeTiers.last;
        final circuitJson = await rootBundle.loadString(
          'assets/circuits/ca_v2_4_tier$tier.json',
        );
        final bytecode = await prover.extractBytecode(circuitJson);
        await prover.initSrsCached(bytecode, cachePath: await srsCachePath());
        verifyProof = prover.verifyProof;

        final identity = await Identity.loadOrCreate();
        signMessage = (message) => identity.sign(message);
        // Kept for the end-of-match signed MatchOutcome exchange
        // (MASTER_APPRENTICE_PLAN.md §4) -- see _handleMatchEnd.
        _localIdentity = identity;
      } catch (e) {
        if (!mounted) return;
        setState(() => _verifierInitError = '$e');
        return;
      }
    }

    if (!mounted) return;
    // Copied to a local so the closure below captures a non-nullable map —
    // Dart won't promote `vkByTier` inside a closure.
    final vks = vkByTier;
    _loop = TurnLoop(
      state: widget.state,
      session: session ?? SoloBattleSession(state: widget.state),
      localPlayerId: widget.localPlayerId,
      matchId: widget.matchId,
      tier: widget.state.config.tier,
      verifyProof: verifyProof,
      vkBytesForTier: vks == null ? null : (t) => vks[t],
      peerBookRoot: widget.peerBookRoot,
      peerBookLeafCount: widget.peerBookLeafCount,
      peerOwnerPubkeyHex: widget.peerOwnerPubkeyHex,
      peerPermissions: widget.peerPermissions ?? const [],
      signMessage: signMessage,
      peerRawPubkey: widget.peerRawPubkey,
      isVocalComponents: widget.state.config.vocalComponents,
      isSomaticComponents: widget.state.config.somaticComponents,
      meleeTargetPicker: _pickMeleeTarget,
      freeMoveDirectionPicker: _pickFreeMoveDirection,
      artifactActivationPicker: _pickArtifactActivation,
      onMovementResolved: _playAvatarWalks,
      onSummonMovementResolved: _playSummonWalks,
      onMeleeResolved: _playMeleeStrikes,
      onPhase: _onEnginePhase,
      // DEV FLAG (lib/dev_flags.dart) — the only site that turns proofless
      // peer casts on. Delete this argument with the flag.
      allowProoflessSpells: kAllowProoflessSpells,
    );
    _loopConstructed = true;
    _maybeSetLocalChapterCommitments();
    setState(() {});
  }

  /// Sets [TurnLoop.localChapterCommitments] once both [_loop] exists and
  /// [_spells] has resolved — called from both [_initTurnLoop] and
  /// [_loadSpells], since they run concurrently and either can finish
  /// first. Safe to call speculatively before either is ready (no-ops). Once
  /// both prerequisites are met it fires the battle-start deal
  /// ([_startBattleIfNeeded]), which is what flips [_loopReady].
  void _maybeSetLocalChapterCommitments() {
    if (!_loopConstructed || !_spellsLoaded) return;
    final resolved = _spells.whereType<SpellAsset>().toList();
    final commitments = resolved.map((s) => s.commitmentHex).toList()..sort();
    _loop.localChapterCommitments = commitments;
    _loop.localChapterSpells = resolved;
    _startBattleIfNeeded();
  }

  /// Runs the battle-start entropy exchange + opening deal
  /// ([TurnLoop.startBattle]) once, then flips [_loopReady] so build() drops
  /// its spinner and turn 1 is playable with a full hand. Fail-closed like
  /// [_initTurnLoop]: a withheld/failed exchange surfaces as a blocking error
  /// rather than starting a match with no hand. A withheld reveal here also
  /// forfeits the match on the engine side (TurnLoop._resolveEntropy).
  Future<void> _startBattleIfNeeded() async {
    if (_battleStarting) return;
    _battleStarting = true;
    try {
      await _loop.startBattle();
    } catch (e) {
      if (!mounted) return;
      setState(() => _verifierInitError = '$e');
      return;
    }
    if (!mounted) return;
    setState(() => _loopReady = true);
    // Turn 1's dedicated artifact entropy (rod roll). Every later turn's is
    // kicked off from _submitTurn, right after _resetTurn. The Phase-0
    // declaration itself is NOT started here — see _onArtifactCornerLongPress
    // / _commitAction.
    unawaited(_beginArtifactEntropyForTurn());
    // Turn 1's performing order. Deliberately after startBattle(), which is
    // what draws the leading seat from the joint entropy — arming earlier
    // would order turn 1 off the fallback seat 0 on both devices and only
    // start rotating from turn 2.
    _armComponentSlot();
  }

  /// Builds the active scorer for vocal components.
  ///
  /// The once-per-match ambient noise-floor calibration is GONE with the move
  /// to recall scoring: volume is no longer scored at all. It was only ever
  /// used to normalise a loudness component, and the design doc (§944) already
  /// flagged that volume-scaling penalises players who can't project, in
  /// venues that are loud by design. Recall asks WHICH word, not how loudly.
  Future<void> _initVocalComponents() async {
    _vocalScorer = VocalScorerFactory.create();
    final enrollment = await VocalEnrollment.open();
    // The profile is passed so a slot whose enrolled audio is for a word the
    // player has since changed reads as stale and falls back to the bundled
    // template, instead of scoring them against a word they no longer say.
    final vocabulary = await VocabularyProfile.load();
    final scorer = IncantationRecallScorer(
      templateSource: PerUserEnrolledTemplateSource(
        enrollment: enrollment,
        vocabulary: vocabulary,
      ),
    );
    await scorer.load();
    if (!mounted) return;
    setState(() => _recallScorer = scorer);
  }

  /// Loads the player's enrolled gesture reps and opens the IMU seam.
  ///
  /// Fail-soft, unlike the vocal path's scorer: a player who enabled somatic
  /// components but never enrolled (or whose enrollment fails to read) still
  /// gets a playable match — every gesture resolves to neutral, so they cast
  /// without enhancements rather than being unable to cast at all.
  Future<void> _initSomaticComponents() async {
    _gestureCapture = SensorsGestureCapture();
    try {
      final enrollment = await GestureEnrollment.open();
      final templates = await loadGestureTemplates(
        EnrolledGestureTemplateSource(enrollment),
        // Melee is enrolled and lives in the corpus, but is an action rather
        // than an enhancement (SOMATIC_GESTURE_PLAN.md §3) — offering it as a
        // cast-time candidate could only ever steal a match away from one of
        // the four that mean something here.
        const [Gesture.fire, Gesture.air, Gesture.water, Gesture.earth],
      );
      if (!mounted) return;
      setState(() => _gestureTemplates = templates);
    } catch (e) {
      debugPrint('somatic: gesture template load failed — $e');
    }
  }

  /// How many element words this spell's incantation asks for — its complete
  /// triplets, matching PracticeFormula.fromSpellFormula and the engine's
  /// expected recital. Residual activations resolve to no effect, so they are
  /// neither drilled nor recited nor priced.
  int _expectedElementCount(SpellAsset spell) =>
      (spell.formula.length ~/ 3) * 3;

  /// Opens the mic and the IMU when the caster presses and holds CAST.
  ///
  /// Both components share this one window. Either may be off, and the vocal
  /// half may fail on a denied mic permission, without disturbing the other —
  /// they are independent sensor paths that happen to be segmented together.
  Future<void> _onCastHoldStart() async {
    if (!_componentsOn) return;
    if (_somaticOn && !_isCapturingGesture) {
      final capture = _gestureCapture;
      if (capture != null) {
        // Fail-soft: `flutter run -d linux` is the cheap UI target and has no
        // IMU, so subscribing throws there. A device with no motion sensor
        // should still be able to cast — it just never earns an enhancement,
        // which is the same place every other somatic failure lands.
        try {
          capture.beginCapture();
          setState(() => _isCapturingGesture = true);
        } catch (e) {
          debugPrint('somatic: IMU capture unavailable — $e');
        }
      }
    }
    if (!_vocalOn) return;
    if (_castRecorder != null) return;
    final recorder = AudioRecorder();
    try {
      if (!await recorder.hasPermission()) {
        recorder.dispose();
        return;
      }
      final pcm = BytesBuilder();
      final stream = await recorder.startStream(const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        numChannels: 1,
        sampleRate: MfccExtractor.sampleRate,
      ));
      if (!mounted) {
        await recorder.stop();
        recorder.dispose();
        return;
      }
      setState(() {
        _castRecorder = recorder;
        _castPcm = pcm;
        _castSub = stream.listen(pcm.add, onError: (_) {});
        _isCapturingVoice = true;
      });
    } catch (_) {
      recorder.dispose();
    }
  }

  /// Closes the capture window on release and decides what was said.
  ///
  /// [cancelled] discards the audio instead of scoring it — a press dragged
  /// off the button was not a performed incantation, and scoring it would
  /// charge mana for a recital the player never made.
  Future<IncantationRecall?> _endCastCapture({bool cancelled = false}) async {
    final recorder = _castRecorder;
    final pcm = _castPcm;
    if (recorder == null) return null;
    await _castSub?.cancel();
    try {
      await recorder.stop();
    } catch (_) {
      // Already stopped; the buffered audio is still good.
    }
    recorder.dispose();
    if (mounted) {
      setState(() {
        _castRecorder = null;
        _castSub = null;
        _castPcm = null;
        _isCapturingVoice = false;
      });
    }
    final spell = _selectedSpell;
    final scorer = _recallScorer;
    if (cancelled || pcm == null || spell == null || scorer == null) return null;
    return scorer.score(
      pcm.toBytes(),
      expectedElements: _expectedElementCount(spell),
    );
  }

  /// Closes the IMU window on release and resolves what was performed.
  ///
  /// Returns [Gesture.neutral] for every rejection path — no capture, too
  /// short, not enough sustained motion, no confident match, or an
  /// enhancement this spell has not certified. Neutral is the universal safe
  /// sink (SOMATIC_GESTURE_PLAN.md §0): the worst a misread can do is cast
  /// without an enhancement, never with the wrong one.
  _SomaticOutcome _endGestureCapture({bool cancelled = false}) {
    final capture = _gestureCapture;
    if (capture == null || !_isCapturingGesture) {
      return const _SomaticOutcome(Gesture.neutral, _SomaticVerdict.notCaptured);
    }
    List<ImuSample> samples;
    try {
      samples = capture.endCapture();
    } catch (e) {
      debugPrint('somatic: IMU capture ended badly — $e');
      samples = const [];
    }
    if (mounted) setState(() => _isCapturingGesture = false);
    if (cancelled) {
      return const _SomaticOutcome(Gesture.neutral, _SomaticVerdict.notCaptured);
    }

    // §4.1's free-style gate, ahead of classification: the hold is a
    // performance and a caster who stood still through most of it has not
    // given one. Costs the enhancement and nothing else — a phone's motion is
    // a self-attested claim, so it can never be allowed to move mana.
    if (!castMotionSatisfied(samples, classifier: _gestureClassifier)) {
      return const _SomaticOutcome(Gesture.neutral, _SomaticVerdict.tooStill);
    }

    final templates = _gestureTemplates;
    if (templates == null || templates.isEmpty) {
      return const _SomaticOutcome(Gesture.neutral, _SomaticVerdict.notEnrolled);
    }
    final match = _gestureClassifier.classify(samples, templates);
    if (match.gesture == Gesture.neutral) {
      return const _SomaticOutcome(
        Gesture.neutral,
        _SomaticVerdict.unrecognized,
      );
    }

    // §5.1's client-side eligibility downgrade. Gated on spell.supremeTags —
    // the same field the tap picker gates on, backfilled by deriveSupremeTags()
    // from the very stepper run the proof attests, so it cannot disagree with
    // what the peer will certify. An honest client therefore never trips the
    // peer's `unbacked_enhancement_claim` forfeit; that check remains as the
    // backstop for clients that skip this one.
    final zone = match.gesture.enhancementZone;
    final spell = _selectedSpell;
    if (zone == null || spell == null || !spell.supremeTags.contains(zone)) {
      return _SomaticOutcome(Gesture.neutral, _SomaticVerdict.ineligible,
          attempted: match.gesture);
    }
    return _SomaticOutcome(match.gesture, _SomaticVerdict.applied);
  }

  Future<void> _onCastHoldEnd() async {
    _pendingRecall = await _endCastCapture();
    if (_somaticOn) {
      final outcome = _endGestureCapture();
      if (!mounted) return;
      // The gesture IS the enhancement choice while somatic is on — the tap
      // picker is hidden (§4.2), so nothing else can have set this.
      setState(() {
        _selectedEnhancement = outcome.gesture.enhancementZone;
        if (_selectedEnhancement != 'earth') _mysteryDelay = 0;
      });
      // Always says something, success included: with the picker hidden the
      // player has no other confirmation of what their hands just bought
      // them. And on failure it says WHICH way it fell short — move-more,
      // gesture-more-clearly and this-spell-can't-take-that are three
      // different corrections, which one "no enhancement" would teach none of.
      final message = outcome.message;
      if (message != null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(message)));
      }
      // Mystery needs a delay, and a delay cannot be gestured. Prompt for it
      // now, after the hold, before anything is committed — cancelling here
      // abandons the cast without spending the turn.
      if (_selectedEnhancement == 'earth') {
        final delay = await _pickMysteryDelay();
        if (!mounted) return;
        if (delay == null) {
          setState(() => _selectedEnhancement = null);
          return;
        }
        setState(() => _mysteryDelay = delay);
      }
    }
    await _onCast();
  }

  Future<void> _onCastHoldCancel() async {
    await _endCastCapture(cancelled: true);
    if (_somaticOn) _endGestureCapture(cancelled: true);
  }

  @override
  void dispose() {
    activeWildMagicContext.value = _wildMagicContextBeforeDuel;
    _stallTimer?.cancel();
    _pulseController.dispose();
    _castAnimController.dispose();
    _effectBloomController.dispose();
    _moveAnimController.dispose();
    _attackAnimController.dispose();
    _vocalScorer?.dispose();
    _gestureCapture?.dispose();
    unawaited(_soundPlayerOrNull?.dispose() ?? Future<void>.value());
    // This screen owns the session and its transport from the moment the
    // lobby hands off (battle_lobby_screen.dart's `_handedOff`), and nothing
    // else ever released them — so leaving a duel by any route left the
    // socket open for the life of the process. That is not just a leak: an
    // open socket is exactly what the peer reads as "still there", leaving
    // them blocked on an exchange from a player who has walked away. Closing
    // it is what turns their silent freeze into a "lost contact" message.
    // Not awaited — dispose() cannot be async, and the teardown has no
    // failure mode this screen could act on.
    unawaited(widget.session?.close() ?? Future<void>.value());
    super.dispose();
  }

  Future<void> _loadSpells() async {
    final all = await SpellAsset.loadAll();
    if (!mounted) return;
    final byId = {for (final s in all) s.id: s};

    // Backfill supremeTags for spells added to a chapter before this
    // eligibility tracking existed, so the cast-time enhancement picker
    // sees correct eligibility even for older chapters — mirrors
    // library_screen.dart's _addToChapter backfill. Also binds each entry's
    // chapter-chosen personality glyph (design doc "Personalities") onto its
    // resolved SpellAsset — the entry, not the underlying spell, is the
    // source of truth now that personality is picked per-chapter-add rather
    // than at inscription (see ChapterEntry.summonPersonality).
    final resolved = <SpellAsset?>[];
    for (final entry in widget.chapter.entries) {
      var spell = byId[entry.spellId];
      final personality = entry.summonPersonality;
      if (spell != null && personality != null) {
        spell = spell.withSummonPersonality(personality);
      }
      if (spell != null &&
          spell.supremeTags.isEmpty &&
          spell.initialGrid.isNotEmpty) {
        final derived = deriveSupremeTags(spell);
        if (derived.isNotEmpty) {
          final updated = spell.withSupremeTags(derived.toList());
          await updated.save();
          resolved.add(updated);
          continue;
        }
      }
      resolved.add(spell);
    }
    if (!mounted) return;
    _spellsLoaded = true;
    setState(() => _spells = resolved);
    _maybeSetLocalChapterCommitments();
  }

  WizardAvatar? get _local =>
      widget.state.avatars.cast<WizardAvatar?>().firstWhere(
        (a) => a?.playerId == widget.localPlayerId,
        orElse: () => null,
      );

  List<WizardAvatar> get _opponents => widget.state.avatars
      .where((a) => a.playerId != widget.localPlayerId)
      .toList();

  /// This turn's movement budget for the local player, including a
  /// committed Dash's doubling -- mirrors TurnLoop.runTurn's own speeds-map
  /// computation (see turn_loop.dart's header comment on why the flag rides
  /// the movement commit-reveal). Used everywhere the movement-phase UI
  /// needs to know how far the player can actually walk: the tap-to-path
  /// budget check in _onTapBattlefield and the predicted-path preview in
  /// build().
  int get _localMoveBudget {
    final local = _local;
    if (local == null) return 0;
    final base = local.effectiveMoveSpeed;
    return _pendingAction is DashAction ? base * 2 : base;
  }

  /// Every committed-but-unresolved cast to render as a held, pulsing orb:
  /// this client's own same-turn cast (phase A, before the turn resolves)
  /// plus every in-flight Mystery cast from the shared, public
  /// [BattleState.pendingDelayedSpells] -- so opponents' pending Mystery
  /// casts render here too, not just the local player's own.
  List<PendingCastOrb> get _pendingCastOrbs {
    final orbs = <PendingCastOrb>[];
    final orderedPlayerIds = widget.state.avatars
        .map((a) => a.playerId)
        .toList();
    final origin = _pendingCastOrigin;
    final affinity = _pendingCastAffinity;
    if (origin != null && affinity != null) {
      orbs.add(
        PendingCastOrb(
          origin: origin,
          color: BattlefieldPainter.colorForWizard(
            widget.localPlayerId,
            localPlayerId: widget.localPlayerId,
            orderedPlayerIds: orderedPlayerIds,
          ),
        ),
      );
    }
    for (final pending in widget.state.pendingDelayedSpells) {
      final pendingAffinity = primaryFormulaAffinity(pending.spell.formula);
      if (pendingAffinity == null) continue;
      final caster = widget.state.avatars
          .where((a) => a.playerId == pending.ownerId)
          .firstOrNull;
      orbs.add(
        PendingCastOrb(
          origin: pending.origin,
          color: BattlefieldPainter.colorForWizard(
            pending.ownerId,
            localPlayerId: widget.localPlayerId,
            orderedPlayerIds: orderedPlayerIds,
          ),
          rangeRadius: caster != null
              ? _maxCastRange(caster, pending.origin)
              : 0,
        ),
      );
    }
    return orbs;
  }

  Map<HexCoord, List<SpellAffinity>> _barrierRings() {
    final result = <HexCoord, List<SpellAffinity>>{};
    for (final av in widget.state.avatars) {
      if (!av.isAlive) continue;
      final active = av.barriers.entries
          .where((e) => e.value.isAlive)
          .map((e) => e.key)
          .toList();
      if (active.isNotEmpty) result[av.position] = active;
    }
    for (final m in widget.state.minions) {
      if (!m.isAlive) continue;
      final active = m.barriers.entries
          .where((e) => e.value.isAlive)
          .map((e) => e.key)
          .toList();
      if (active.isNotEmpty) result[m.position] = active;
    }
    return result;
  }

  static double _hexSizeFromConstraints(Size available, int radius) {
    final byWidth = available.width / (3 * radius + 2);
    final byHeight = available.height / (sqrt(3) * (2 * radius + 1));
    // Upper bound raised from 36 now that the artifact tiles are corner
    // triangles hugging the literal corners (see _ArtifactCornerTile) rather
    // than a rectangle reserving a safe margin — the map is free to grow
    // under/behind them.
    return min(byWidth, byHeight).clamp(6.0, 56.0);
  }

  // ── Helpers ─────────────────────────────────────────────────────────────────

  bool _isValidHex(HexCoord hex) {
    final r = widget.state.config.gridRadius;
    return hex.q.abs() <= r && hex.r.abs() <= r && (hex.q + hex.r).abs() <= r;
  }

  void _resetTurn() {
    _phase = _InputPhase.action;
    _selectedSpell = null;
    _selectedHandIndex = null;
    _targetHex = null;
    _pendingAction = null;
    _movePath = const [];
    _isBusy = false;
    _selectedEnhancement = null;
    _mysteryDelay = 0;
    // Phase A of the held cast orb ends here -- on success, _submitTurn's
    // caller populates _castAnimations right after this for phase B; on
    // failure (turn never committed), there's nothing left to hold.
    _pendingCastOrigin = null;
    _pendingCastAffinity = null;
    _scryRevealedTile = null;
    _submittingPhase = null;
    // A fresh turn means a fresh Phase 0 — see _beginArtifactEntropyForTurn /
    // _beginArtifactPhaseForTurn, kicked off right after this by the two
    // places a turn begins.
    _localArtifactDeclaration = null;
    _artifactEntropyStarted = false;
    _artifactPhaseInFlight = false;
    _artifactPhaseResolved = false;
  }

  // ── Spell components: order + banner (SPELL_COMPONENTS_PLAN.md §5.2) ────────

  // ── Stall watchdog ──────────────────────────────────────────────────────────

  /// The peer frame this device has been blocked on long enough to say so, or
  /// null when nothing is overdue. Mirrors
  /// [BattleTurnSession.stalledExchange] into build state.
  String? _stalledExchange;
  Timer? _stallTimer;

  /// Polls the session for an overdue exchange.
  ///
  /// A poll rather than a push because the stall is defined by elapsed time,
  /// not by an event — the whole failure mode is that *nothing* happens. Two
  /// seconds is well under the eight-second threshold the session applies, and
  /// costs nothing: the tick only calls setState when the value actually
  /// changes.
  void _startStallWatchdog() {
    if (!_isRealDuel) return;
    _stallTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (!mounted) return;
      final session = widget.session;
      final stalled =
          session is BattleSession ? session.stalledExchange : null;
      if (stalled != _stalledExchange) {
        setState(() => _stalledExchange = stalled);
      }
    });
  }

  /// Opens the local player's lock-in when everyone ahead of them in this
  /// turn's order has performed.
  ///
  /// Idempotent per turn — the action phase is re-entered on several paths
  /// and re-arming would drop a signal already consumed. Called wherever a
  /// fresh action phase begins.
  void _armComponentSlot() {
    if (!widget.state.config.sequentialCasting) return;
    final turn = _loop.componentTurnNumber;
    if (_componentSlotArmedForTurn == turn) return;
    _componentSlotArmedForTurn = turn;

    final leading = _loop.localComponentSlot(turn) <= 0;
    setState(() => _componentSlotOpen = leading);
    if (leading) return;
    unawaited(
      _loop.awaitComponentSlot().then((_) {
        // Guard on the turn: a signal that lands after the turn moved on
        // must not reopen a slot that belongs to a different order.
        if (!mounted || _componentSlotArmedForTurn != turn) return;
        setState(() => _componentSlotOpen = true);
      }),
    );
  }

  /// Display name for whoever leads this turn's performing order.
  String _componentPerformerName() {
    final order = _loop.componentOrder(_loop.componentTurnNumber);
    if (order.isEmpty) return 'your opponent';
    final id = order.first;
    if (id == widget.localPlayerId) return 'you';
    final name = widget.state.avatars
        .where((a) => a.playerId == id)
        .map((a) => a.wizardName)
        .firstOrNull;
    return (name == null || name.isEmpty) ? 'your opponent' : name;
  }

  /// The one components banner: what to do right now, or who to wait for.
  /// Null when there is nothing to say (components off, or not the action
  /// phase).
  String? get _componentBannerText {
    if (_isPerformingComponents) {
      // Deliberately no words: recalling them IS the exercise, and a
      // sight-reading mode (at a mana premium) is a later pass.
      if (_vocalOn && _somaticOn) return 'SPEAK AND GESTURE THE INCANTATION';
      if (_vocalOn) return 'SPEAK THE INCANTATION';
      return 'GESTURE THE INCANTATION';
    }
    if (!_componentsOn || _phase != _InputPhase.action) return null;
    if (!_componentSlotOpen) {
      return '${_componentPerformerName().toUpperCase()} IS CASTING — LISTEN';
    }
    if (widget.state.config.sequentialCasting) return 'YOUR COMPONENTS';
    return null;
  }

  // ── Phase banner / engine phase notifications ─────────────────────────────────

  /// TurnLoop.onPhase: fired for the two internal phases (Summons,
  /// Resolution) that happen inside the opaque `await runTurn(...)` call --
  /// see _phaseLabel for how this combines with the pre-submission
  /// _InputPhase to drive the phase banner.
  void _onEnginePhase(TurnPhase phase) {
    if (!mounted) return;
    setState(() => _submittingPhase = phase);
  }

  /// TurnLoop.onMovementResolved: walks every wizard who actually went
  /// somewhere this turn, and blocks the turn until the walk finishes.
  ///
  /// Called synchronously with the engine's position update, so the `setState`
  /// below installs the animation before any frame can render the new
  /// occupancy — that is what stops the token teleporting to its destination
  /// and then snapping back to walk. Cleared as soon as playback ends so
  /// post-movement displacement (knockback, Zephyr) isn't overridden by a spent
  /// animation — see _avatarMoveAnimations.
  ///
  /// Wizards who stayed put and were in no collision are dropped: they're drawn
  /// from occupancy exactly as before, so including them would buy nothing —
  /// and a turn where NOBODY moved skips the movement beat entirely rather than
  /// holding on a still board.
  Future<void> _playAvatarWalks(List<AvatarMoveEvent> events) async {
    if (!mounted) return;
    final moves = events
        .where((e) => e.path.length > 1 || e.lungeTile != null)
        .map(
          (e) => AvatarMoveAnimation(
            playerId: e.playerId,
            path: e.path,
            lungeTile: e.lungeTile,
            wonContestAt: e.wonContestAt,
          ),
        )
        .toList();
    if (moves.isEmpty) return;
    setState(() => _avatarMoveAnimations = moves);
    // .orCancel, because runTurn is blocked on this: leaving the battle screen
    // mid-walk disposes the controller, and a plain TickerFuture simply never
    // completes when its ticker is cancelled — which would strand the turn (and
    // its open exchange) forever rather than letting it unwind.
    await _moveAnimController.forward(from: 0).orCancel.catchError((_) {});
    if (!mounted) return;
    setState(() => _avatarMoveAnimations = const []);
  }

  /// TurnLoop.onSummonMovementResolved: the Summons-phase twin of
  /// [_playAvatarWalks], with the same contract — installed synchronously with
  /// the engine's position update, cleared as soon as playback ends.
  ///
  /// A melee creature's whole attack is the lunge-and-recoil, so an event with
  /// a lunge tile is kept even when its path never left home: that IS the blow
  /// landing, and dropping it would make a melee summon look inert.
  Future<void> _playSummonWalks(
    List<MinionMoveEvent> events,
    List<AttackEvent> attacks,
  ) async {
    if (!mounted) return;
    final moves = events
        .where((e) => e.path.length > 1 || e.lungeTile != null)
        .map(
          (e) => MinionMoveAnimation(
            minionId: e.minionId,
            path: e.path,
            lungeTile: e.lungeTile,
          ),
        )
        .toList();
    if (moves.isEmpty && attacks.isEmpty) return;
    if (moves.isEmpty) {
      // Nothing walked — a creature with reach striking from where it stood.
      // No lunge to wait for, so the blow lands immediately.
      await _playAttacks(attacks, lead: Duration.zero);
      return;
    }
    setState(() => _minionMoveAnimations = moves);
    // Both playbacks run on one wall clock: the walk plays out while the
    // attacks wait out their lead-in, so a melee creature's blade crosses its
    // target on the frame its lunging token gets there.
    await Future.wait([
      _moveAnimController.forward(from: 0).orCancel.catchError((_) {}),
      _playAttacks(attacks, lead: _walkStrikeLead),
    ]);
    if (!mounted) return;
    setState(() => _minionMoveAnimations = const []);
  }

  /// How long into a walk playback the walkers arrive — the moment an attack
  /// riding that walk should land. Derived from the movement timeline itself so
  /// the two can't drift apart if either duration changes.
  Duration get _walkStrikeLead =>
      _moveAnimController.duration! * kAttackStrikeStart;

  /// TurnLoop.onMeleeResolved: the wizards' Phase 4b haymakers. Nobody is
  /// walking during the melee round, so these land straight away.
  Future<void> _playMeleeStrikes(List<AttackEvent> attacks) =>
      _playAttacks(attacks, lead: Duration.zero);

  /// Plays [attacks] — a red swipe across the target for a blow struck at arm's
  /// length, an elementally coloured orb thrown across the tiles for one with
  /// reach — and blocks the turn until they finish, exactly like the walks.
  ///
  /// [lead] is dead time at the head of the playback, for attacks that ride a
  /// concurrent walk and must not land before the attacker arrives. It is added
  /// to the controller's duration rather than awaited beforehand, so the whole
  /// thing stays one cancellable playback: the turn is blocked on this, and a
  /// bare `Future.delayed` on a screen that has since been disposed would
  /// strand it.
  Future<void> _playAttacks(
    List<AttackEvent> attacks, {
    required Duration lead,
  }) async {
    if (!mounted || attacks.isEmpty) return;
    final total = lead + _kAttackPlayback;
    final startFraction = total.inMicroseconds == 0
        ? 0.0
        : lead.inMicroseconds / total.inMicroseconds;
    final anims = [
      for (final a in attacks)
        AttackAnimation(
          fromHex: a.from,
          toHex: a.to,
          melee: a.isMelee,
          // A punch has no element to express (AttackEvent.affinity is null for
          // wizards); a creature's shot is coloured by its own affinity, which
          // is the same colour its token's label already wears.
          color: a.isMelee || a.affinity == null
              ? BattlefieldPainter.meleeStrikeColor
              : BattlefieldPainter.colorForAffinity(a.affinity!),
          startFraction: startFraction,
        ),
    ];
    _attackAnimController.duration = total;
    setState(() => _attackAnimations = anims);
    await _attackAnimController.forward(from: 0).orCancel.catchError((_) {});
    if (!mounted) return;
    setState(() => _attackAnimations = const []);
  }

  /// TurnLoop.meleeTargetPicker: invoked once per turn, after movement has
  /// resolved, only when the local avatar actually has an adjacent hostile
  /// target. Highlights [candidates] on the battlefield and waits for the
  /// player to tap one (see _onTapBattlefield's _pickingMelee branch) or the
  /// melee bar's PASS button.
  Future<HexCoord?> _pickMeleeTarget(List<HexCoord> candidates) async {
    if (!mounted) return null;
    final completer = Completer<HexCoord?>();
    setState(() {
      _pickingMelee = true;
      _meleeCandidates = candidates;
      _meleePickCompleter = completer;
    });
    final result = await completer.future;
    if (mounted) {
      setState(() {
        _pickingMelee = false;
        _meleeCandidates = const [];
        _meleePickCompleter = null;
      });
    }
    return result;
  }

  /// TurnLoop's [FreeMovePathPicker]: the local wizard earned a reactive move
  /// this turn — an Airy Barrier's free burst step, a Boost's paid run, or
  /// both. Lets the player build a path tile by tap (see _onTapBattlefield's
  /// _pickingFreeMove branch), shows what each extra tile will cost them, and
  /// waits for MOVE (_ActionBar's onConfirmFreeMove) or STAND
  /// (onDeclineFreeMove). Only ever called with a non-empty [grant].
  ///
  /// Lifts the resolution hold-back for the duration of the prompt and puts it
  /// back afterwards. This is the one moment in the turn where the player makes
  /// a *decision* against a board that's still mid-reveal — Phase 5.5 runs
  /// after this turn's spells have already created their lava, ice and clouds —
  /// and asking someone to step somewhere while hiding what's on the tile is a
  /// worse bug than the pop-in the hold-back exists to prevent. Restoring the
  /// snapshot re-hides them, so they still bloom out of their cast tiles with
  /// their cards. See [ResolutionBaseline].
  Future<List<HexCoord>?> _pickFreeMoveDirection(FreeMoveGrant grant) async {
    if (!mounted) return null;
    final completer = Completer<List<HexCoord>?>();
    final heldBack = _resolutionBaseline;
    setState(() {
      _pickingFreeMove = true;
      _freeMoveGrant = grant;
      _freeMovePath = const [];
      _freeMovePickCompleter = completer;
      _resolutionBaseline = null;
    });
    final result = await completer.future;
    if (mounted) {
      setState(() {
        _pickingFreeMove = false;
        _freeMoveGrant = FreeMoveGrant.none;
        _freeMovePath = const [];
        _freeMovePickCompleter = null;
        _resolutionBaseline = heldBack;
      });
    }
    return result;
  }

  /// The simulated free-move walk for the path tapped so far — the same
  /// [predictAvatarMove] the movement phase uses, so conveyor push-throughs
  /// and slow tiles read identically in both places.
  MovePathPrediction get _freeMovePrediction => predictAvatarMove(
    state: widget.state,
    origin: _local!.position,
    declaredPath: _freeMovePath,
    budget: _freeMoveGrant.maxTiles,
    moverId: widget.localPlayerId,
  );

  /// What the free-move run tapped so far will cost, in the Boost's resource.
  /// 0 while the player is still inside their free tiles (the burst step and
  /// any Potency freebie), and 0 always when no Boost is in the grant.
  ///
  /// Prices off budget *spent*, not tiles drawn, and calls the engine's own
  /// [TurnLoop.boostMoveCost] rather than re-deriving the formula — the
  /// preview and the charge must be the same arithmetic or the player gets
  /// billed something they never agreed to.
  int get _freeMoveCost {
    final resource = _freeMoveGrant.boostResource;
    if (resource == null || _local == null) return 0;
    final spent = _freeMoveGrant.maxTiles - _freeMovePrediction.budgetRemaining;
    return TurnLoop.boostMoveCost(
      resource,
      max(0, spent - _freeMoveGrant.freeTiles),
    );
  }

  /// Phase banner text — "Summons" / "Main" / "Move" / "Resolution".
  /// Pre-submission phases come straight from [_phase] (this UI already
  /// knows which one it's in); the two mid-submission phases come from
  /// [_submittingPhase], set by [_onEnginePhase].
  String get _phaseLabel {
    if (_pickingMelee || _pickingFreeMove) return 'Resolution';
    if (_isBusy) {
      return _submittingPhase == TurnPhase.actionResolve
          ? 'Resolution'
          : 'Summons';
    }
    return switch (_phase) {
      _InputPhase.action => 'Main',
      _InputPhase.movement => 'Move',
      _InputPhase.pickingDirection => 'Main',
    };
  }

  // ── Action phase ─────────────────────────────────────────────────────────────

  // ── Mana affordability gate ──────────────────────────────────────────────
  //
  // The engine charges the caster with a clamp (`.clamp(0, _kMaxMana)`), so
  // overspending locally looks harmless — the bar just empties. The opponent's
  // device is the one that notices: TurnLoop._verifyPeerSpellCast sends
  // the cast fizzles for want of mana, wasting the turn. That asymmetry is
  // what a player sees as "my laptop let me cast it and my Pixel desynced".
  // These three helpers are the barrier; TurnLoop.previewSpellCost is the
  // single shared price so the gate and the deduction cannot disagree.

  /// What [spell] would cost right now under [enhancementZone] (the same zone
  /// strings the enhancement picker uses; null = no enhancement). Null when
  /// there's no local avatar to price against — callers treat that as
  /// "unknown, don't block".
  int? _spellCost(SpellAsset spell, {String? enhancementZone}) {
    if (_local == null) return null;
    return _loop.previewSpellCost(
      spell,
      isPotent: enhancementZone == 'fire',
      isVelocity: enhancementZone == 'air',
      isEfficiency: enhancementZone == 'water',
    );
  }

  /// The cheapest [spell] can be made this turn: with Water/Efficiency's −1/3
  /// applied if the spell actually earned that supreme tag. This — not the
  /// unenhanced cost — is what gates *selection*, because the enhancement
  /// picker only appears once a card is selected. Gating selection on the
  /// dearer price would put a spell the player can afford out of reach.
  int? _bestCaseSpellCost(SpellAsset spell) => _spellCost(
    spell,
    enhancementZone: spell.supremeTags.contains('water') ? 'water' : null,
  );

  /// Whether [spell] is unaffordable under *every* enhancement choice — the
  /// hand-strip greying rule.
  bool _isUnaffordable(SpellAsset spell) {
    final mana = _local?.mana;
    final cost = _bestCaseSpellCost(spell);
    if (mana == null || cost == null) return false;
    return cost > mana;
  }

  /// [handIndex] is [spell]'s position in [_handSpells] — the slot tapped in
  /// the hand strip, not derived from [spell] itself, since a hand may hold
  /// several copies of the same Basic spell's grid (docs/BASIC_SPELLS_PLAN.md
  /// §7) and only the slot disambiguates which copy this is.
  void _selectSpell(int handIndex, SpellAsset spell) {
    if (_isBusy || _phase != _InputPhase.action) return;
    if (_loop.isHandSlotWithered(handIndex))
      return; // §9: withered, not castable
    if (_isUnaffordable(spell)) return; // can't pay for it under any enhancement
    setState(() {
      if (_selectedHandIndex == handIndex) {
        _selectedSpell = null;
        _selectedHandIndex = null;
        _targetHex = null;
      } else {
        _selectedSpell = spell;
        _selectedHandIndex = handIndex;
      }
      _selectedEnhancement = null;
      _mysteryDelay = 0;
    });
  }

  /// The local player's current hand (SPELL_DRAW_WIRING_PLAN.md §5) — what
  /// [_SpellBook] renders. Empty until the opening deal has run (TurnLoop
  /// dealing races the chapter-load, same as [_spells] itself).
  List<SpellAsset?> get _handSpells => _loop.localSpellDraw?.hand ?? const [];

  /// Confirm the action and advance to the movement phase.
  void _commitAction(TurnAction action) {
    // Lock-in. Told to the peer FIRST, before any of the turn's exchanges are
    // touched, so the next player's controls open the moment this player stops
    // performing rather than waiting on the Phase-0 round trip below — which
    // cannot complete until that same next player has declared, and so would
    // deadlock the pair (SPELL_COMPONENTS_PLAN.md §5.3).
    //
    // Sent for EVERY action type, not just casts: a Dash consumes its slot
    // exactly as a cast does, so nothing about what was chosen leaks from the
    // timing of when someone acted.
    _loop.signalComponentsDone();
    // Safety net: if the player never long-pressed a corner tile, this is
    // where Phase 0 actually opens (declaring nothing) — beginTurn() below
    // awaits the same memoized exchange either way, so this just makes sure
    // the UI (the opponent toast, the corner tiles' outlined state) updates
    // promptly rather than silently, whichever path fired it first.
    unawaited(_beginArtifactPhaseForTurn());
    setState(() {
      _pendingAction = action;
      _phase = _InputPhase.movement;
      _movePath = const [];
      _scryRevealedTile = null;
      // Same-turn cast, phase A: hold a pulsing orb at the cast tile from
      // the moment the cast is confirmed (before movement/resolution) until
      // the turn resolves and _submitTurn hands off to the travel+burst
      // playback. Mystery casts are excluded -- their pending orb comes from
      // the shared widget.state.pendingDelayedSpells instead (see
      // _pendingCastOrbs), since it must persist across turns and be visible
      // to the opponent too.
      if (action case SpellCastAction(:final spell) when _local != null) {
        _pendingCastOrigin = _local!.position;
        _pendingCastAffinity = primaryFormulaAffinity(spell.formula);
      }
    });
    // Exchanges this turn's action commit with the peer right away (rather
    // than waiting for TurnLoop.runTurn at final submit) so an active Airy
    // Scrying Pool link can reveal the opponent's spell target in time to
    // inform the movement choice below (MESH_ARCHITECTURE.md §13b). Fire-
    // and-forget: the movement phase UI is usable immediately; the reveal
    // (if any) paints in as soon as the round trip completes.
    unawaited(_beginTurnAndRevealScry(action));
  }

  Future<void> _beginTurnAndRevealScry(TurnAction action) async {
    final HexCoord? revealed;
    try {
      revealed = await _loop.beginTurn(action);
    } catch (e) {
      // A genuine protocol failure (bad reveal, bad scry opening) — surface
      // it exactly like _submitTurn's catch-all does, and discard the failed
      // call so the next beginTurn() (for whatever action the player picks
      // next) starts clean instead of replaying this cached failure.
      _loop.cancelPendingTurn();
      if (!mounted) return;
      setState(_resetTurn);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Turn error: $e')));
      return;
    }
    if (!mounted || _phase != _InputPhase.movement) return;
    setState(() => _scryRevealedTile = revealed);
  }

  void _onDash() => _commitAction(DashAction());
  void _onMeditateMain() => _commitAction(MeditateAction());

  Future<void> _onCast() async {
    final spell = _selectedSpell;
    final target = _targetHex;
    if (spell == null || target == null) return;

    // Backstop behind the disabled CAST button. The button is the barrier the
    // player sees; this is the one that holds if mana changed under a stale
    // frame, or if a future call site reaches _onCast some other way. Both
    // read the same TurnLoop.previewSpellCost the deduction uses.
    final cost = _spellCost(spell, enhancementZone: _selectedEnhancement);
    final mana = _local?.mana;
    if (cost != null && mana != null && cost > mana) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Not enough mana: ${spell.name.isEmpty ? 'that spell' : spell.name}'
            ' costs $cost, you have $mana.',
          ),
        ),
      );
      return;
    }

    if (_selectedEnhancement == 'earth') {
      await _onCastMystery(spell, target);
      return;
    }

    // Air-flavor tileModification (ConveyorTile): the casting wizard picks a
    // push direction whenever this cast will create one -- not tied to
    // targeting. Mystery/delayed casts don't get this prompt (handled above,
    // before this point) and fall back to a random direction in the engine.
    HexCoord? conveyorDirection;
    if (spellNeedsConveyorDirection(spell)) {
      conveyorDirection = await _pickConveyorDirection(target);
      if (conveyorDirection == null) return; // player cancelled
      if (!mounted) return;
    }

    final isPotent = _selectedEnhancement == 'fire';
    final isVelocity = _selectedEnhancement == 'air';
    final isEfficiency = _selectedEnhancement == 'water';

    // The recall was captured while the player held CAST (_onCastHoldEnd).
    // Consumed here so it can never leak into a later cast: a stale recall
    // would price one incantation against a different spell's trajectory.
    final recall = _pendingRecall;
    _pendingRecall = null;
    _commitAction(
      SpellCastAction(
        spell: spell,
        targetHex: target,
        isPotent: isPotent,
        isVelocity: isVelocity,
        isEfficiency: isEfficiency,
        recall: recall,
        conveyorDirection: conveyorDirection,
        handIndex: _selectedHandIndex,
      ),
    );
  }

  /// Asks how long an Earth/Mystery cast should lie hidden, 0–3 turns.
  ///
  /// Only reached under somatic components: a delay is a number, and a number
  /// cannot be gestured. With the tap picker hidden (§4.2) this is the one
  /// place the gesture-only flow hands a decision back to the screen.
  /// Returns null if dismissed, which abandons the cast — nothing has been
  /// committed at this point, so no turn is spent.
  Future<int?> _pickMysteryDelay() => showDialog<int>(
        context: context,
        barrierDismissible: true,
        builder: (ctx) => AlertDialog(
          backgroundColor: kParchmentColor,
          title: Text('MYSTERY DELAY', style: manuscriptHeaderStyle(fontSize: 16)),
          content: Text(
            'How many turns should the spell lie hidden before it fires?',
            style: manuscriptCaptionStyle(),
          ),
          actions: [
            for (var d = 0; d <= 3; d++)
              TextButton(
                onPressed: () => Navigator.pop(ctx, d),
                child: Text(
                  d == 0 ? 'NOW' : '$d',
                  style: const TextStyle(
                    fontFamily: 'serif',
                    letterSpacing: 2,
                    color: kIlluminationGold,
                  ),
                ),
              ),
          ],
        ),
      );

  /// Opens [playerId]'s graveyard (cast + withered spells). Passes [_loop]
  /// straight through rather than a snapshot — [_GraveyardDialog] polls it
  /// so a reactivation vanishes from an already-open dialog, since nothing
  /// else in this codebase re-renders an open `showDialog` route when
  /// engine state mutates elsewhere.
  void _showGraveyard(String playerId) {
    final avatar = widget.state.avatars
        .where((a) => a.playerId == playerId)
        .firstOrNull;
    final name = avatar != null && avatar.wizardName.isNotEmpty
        ? avatar.wizardName
        : playerId;
    showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (_) => _GraveyardDialog(loop: _loop, playerId: playerId, title: name),
    );
  }

  /// Prompts the caster to choose a push direction for the ConveyorTile
  /// about to be created at [origin], by tapping one of its 6 highlighted
  /// neighbor hexes (see BattlefieldPainter.directionPickHexes). Returns the
  /// chosen unit HexCoord, or null if the player cancelled.
  Future<HexCoord?> _pickConveyorDirection(HexCoord origin) async {
    final completer = Completer<HexCoord?>();
    setState(() {
      _conveyorPickOrigin = origin;
      _conveyorPickCompleter = completer;
      _phase = _InputPhase.pickingDirection;
    });
    final result = await completer.future;
    if (mounted) {
      setState(() {
        _conveyorPickOrigin = null;
        _conveyorPickCompleter = null;
        _phase = _InputPhase.action;
      });
    }
    return result;
  }

  /// Earth/Mystery cast: hides [target] and [_mysteryDelay] inside a
  /// commitment. Delay 0 fires immediately (same-turn) via
  /// MysterySpellCastAction.immediateTarget; delay 1–3 stages a local secret
  /// that _submitTurn reveals automatically once its fireTurn arrives.
  Future<void> _onCastMystery(SpellAsset spell, HexCoord target) async {
    final rng = Random.secure();
    final nonce = Uint8List.fromList(
      List<int>.generate(16, (_) => rng.nextInt(256)),
    );
    final commitment = await PendingDelayedSpell.commitmentHash(
      target: target,
      delay: _mysteryDelay,
      nonce: nonce,
    );
    final isImmediate = _mysteryDelay == 0;

    if (!isImmediate) {
      _stagedMysterySecret = _PendingMysterySecret(
        id: PendingDelayedSpell.idFromCommitment(commitment),
        target: target,
        delay: _mysteryDelay,
        nonce: nonce,
        fireTurn: widget.state.turnNumber + 1 + _mysteryDelay,
      );
    }

    final recall = _pendingRecall;
    _pendingRecall = null;
    _commitAction(
      MysterySpellCastAction(
        spell: spell,
        mysteryCommitment: commitment,
        immediateTarget: isImmediate ? target : null,
        immediateNonce: isImmediate ? nonce : null,
        recall: recall,
        handIndex: _selectedHandIndex,
      ),
    );
  }

  // ── Movement phase ────────────────────────────────────────────────────────────

  /// Confirms the move phase with whatever path is currently staged --
  /// possibly empty, which is how a player voluntarily stays put for free
  /// (as opposed to [_onMeditateMove], which stays put for +25 mana).
  void _onConfirmMove() => _submitTurn(_pendingAction!, movePath: _movePath);

  void _onMeditateMove() =>
      _submitTurn(_pendingAction!, movePath: const [], meditateInMove: true);

  // ── Status-effect inspection ──────────────────────────────────────────────────

  /// After any battlefield tap, update which avatar's status effects are
  /// shown and which entity's HP/mana the opponent strip displays. Tapping
  /// an occupied hex shows that entity; tapping empty ground (or the local
  /// player's own avatar/minion) reverts both to their defaults.
  void _updateInspection(HexCoord hex) {
    WizardAvatar? occupantAvatar;
    for (final av in widget.state.avatars) {
      if (widget.state.battlefield.occupancy[av.playerId] == hex) {
        occupantAvatar = av;
        break;
      }
    }
    if (occupantAvatar != null) {
      // Only hold an override for non-local avatars.
      final isOpponent = occupantAvatar.playerId != widget.localPlayerId;
      setState(() {
        _inspectedAvatar = isOpponent ? occupantAvatar : null;
        _inspectedMinion = null;
      });
      return;
    }

    final occupantMinion = widget.state.minions
        .where((m) => m.isAlive && m.occupiedTiles.contains(hex))
        .firstOrNull;
    // Only hold an override for minions on a hostile team.
    final isEnemyMinion =
        occupantMinion != null && occupantMinion.teamId != _local?.teamId;
    setState(() {
      _inspectedAvatar = null;
      _inspectedMinion = isEnemyMinion ? occupantMinion : null;
    });
  }

  /// Clouds (Water-Fire) base effect: entities in a cloud's radius may only
  /// target/be targeted by adjacent entities. Returns 1 if [caster] is inside
  /// any cloud (or carries the lingering Earth-flavor restriction status), or
  /// if [hex] is inside any cloud; otherwise [caster]'s normal spell range.
  ///
  /// Mirrors TurnLoop._cloudBoundToAdjacent, including its Earthen Scrying
  /// Pool exemption — this only gates what the UI lets the local player tap,
  /// so letting it disagree would either hide legal casts or offer casts the
  /// engine then fizzles.
  /// Where the currently-selected spell will actually land, when the line
  /// from the local wizard to their declared target is blocked.
  ///
  /// Mirrors TurnLoop._applySpell's retarget exactly — including the
  /// `penetrating` exemption — for the same reason [_maxCastRange] mirrors the
  /// cloud rule: a UI that disagrees with the engine either hides legal casts
  /// or offers ones that resolve somewhere else entirely. Null when the line
  /// is clear (the common case) or nothing is selected.
  HexCoord? _blockedLandingHex() {
    final local = _local;
    final target = _targetHex;
    final spell = _selectedSpell;
    if (local == null || target == null || spell == null) return null;
    final penetrating = local.activeStatusEffects.any(
      (fx) => !fx.isDormant && fx.effectTypeId == StatusEffectId.penetrating,
    );
    final blocker = losBlockerTile(
      widget.state,
      local.position,
      target,
      penetrating: penetrating,
    );
    if (blocker == null) return null;
    // A summon lands one hex short of the blocker rather than on it — a
    // creature needs a tile it can stand on. Mirrors _applySpell's split.
    return spell.isSummon
        ? tileBeforeBlocker(local.position, target, blocker)
        : blocker;
  }

  /// Current HP of every terrain tile, read through [BattleState.terrainHpAt]
  /// so an illusory copy shows its true 1 HP rather than the type's pool.
  Map<HexCoord, int> _terrainHpForPainter() => {
        for (final hex in widget.state.tileEffects.keys)
          hex: widget.state.terrainHpAt(hex),
      };

  Map<HexCoord, List<SpellAffinity>> _terrainBarrierElements() => {
        for (final entry in widget.state.terrainBarriers.entries)
          if (entry.value.values.any((b) => b.isAlive))
            entry.key: entry.value.entries
                .where((e) => e.value.isAlive)
                .map((e) => e.key)
                .toList(),
      };

  /// [includeSelectedEnhancement]: add Velocity's [CastingEnhancements
  /// .velocityRangeBonus] when the in-progress cast's enhancement picker has
  /// 'air' selected. Only correct for the *local player's own live cast* —
  /// true at this method's two live-targeting call sites, left false for the
  /// pending-mystery-orb display (which reflects a past cast's already-
  /// resolved range, never the current live [_selectedEnhancement]).
  int _maxCastRange(
    WizardAvatar caster,
    HexCoord hex, {
    bool includeSelectedEnhancement = false,
  }) {
    if (caster.activeStatusEffects.any(
      (fx) => !fx.isDormant && fx.effectTypeId == StatusEffectId.scryingSight,
    )) {
      return caster.effectiveSpellRange;
    }
    final casterBound =
        caster.activeStatusEffects.any(
          (fx) => fx.effectTypeId == StatusEffectId.cloudBoundTargeting,
        ) ||
        widget.state.clouds.any(
          (c) => hexDistance(caster.position, c.position) <= c.radius,
        );
    final hexBound = widget.state.clouds.any(
      (c) => hexDistance(hex, c.position) <= c.radius,
    );
    final base = (casterBound || hexBound) ? 1 : caster.effectiveSpellRange;
    final velocityBonus =
        includeSelectedEnhancement && _selectedEnhancement == 'air'
        ? CastingEnhancements.velocityRangeBonus
        : 0;
    return base + velocityBonus;
  }

  // ── Battlefield tap ───────────────────────────────────────────────────────────

  void _onTapBattlefield(Offset localPos) {
    final hex = pixelToHex(localPos, _fieldCenter, _hexSize);

    // Checked before the _isBusy guard on purpose: the melee prompt fires
    // from inside _submitTurn's in-flight runTurn() call, so _isBusy is
    // already true by the time it's shown — see _pickMeleeTarget.
    if (_pickingMelee) {
      if (_meleeCandidates.contains(hex)) {
        _meleePickCompleter?.complete(hex);
      }
      return;
    }

    // Same reasoning as the melee branch: the free-move prompt also fires from
    // inside the in-flight runTurn() call — see _pickFreeMoveDirection.
    //
    // Path building mirrors the movement phase's rules exactly (tap the tip to
    // undo, tap the origin to clear, adjacency and terrain against the
    // *simulated* position) — this is the same gesture the player already
    // knows, just with a mana/life price attached and a smaller budget.
    if (_pickingFreeMove) {
      final local = _local;
      if (local == null) return;
      // A bare Airy Barrier burst is one free step with nothing to weigh, so
      // it still commits on the tap — no MOVE button, no path building. Only a
      // Boost (which is spending the player's HP or mana) needs confirmation.
      if (_freeMoveGrant.boostResource == null) {
        if (_loop.freeMoveCandidatesFor(local.playerId).contains(hex)) {
          _freeMovePickCompleter?.complete([hex]);
        }
        return;
      }
      final origin = local.position;
      final prediction = _freeMovePrediction;
      final tip = prediction.path.last;

      if (_freeMovePath.isNotEmpty &&
          (hex == _freeMovePath.last || hex == tip)) {
        setState(() =>
            _freeMovePath = _freeMovePath.sublist(0, _freeMovePath.length - 1));
        return;
      }
      if (hex == origin && _freeMovePath.isNotEmpty) {
        setState(() => _freeMovePath = const []);
        return;
      }
      if (prediction.indeterminate) return;
      if (hexDistance(tip, hex) != 1) return;
      if (!widget.state.battlefield.isInBounds(hex)) return;
      final tileEffect = widget.state.tileEffects[hex];
      if (tileBlocksMovement(tileEffect)) return;
      // Occupied tiles are unenterable — the engine's walk stops there too,
      // and a step the player pays for and doesn't get is the worst outcome.
      if (tileOccupied(
        widget.state,
        hex,
        ignoreAvatarId: widget.localPlayerId,
      )) {
        return;
      }
      final stepCost =
          1 + (tileEffect is SlowTile ? tileEffect.extraMoveCost : 0);
      if (stepCost > prediction.budgetRemaining) return;

      setState(() => _freeMovePath = [..._freeMovePath, hex]);
      return;
    }

    if (_isBusy) return;

    if (_phase == _InputPhase.pickingDirection) {
      // Candidate direction hexes are relative to the pick origin, not
      // necessarily in-bounds themselves (the direction is a property of
      // the tile being created, independent of where that happens to sit
      // relative to the board edge) -- checked before _isValidHex on purpose.
      final origin = _conveyorPickOrigin;
      if (origin == null) return;
      final delta = HexCoord(hex.q - origin.q, hex.r - origin.r);
      if (HexGrid.directions.contains(delta)) {
        _conveyorPickCompleter?.complete(delta);
      }
      return;
    }

    if (!_isValidHex(hex)) return;

    if (_phase == _InputPhase.action) {
      if (_selectedSpell == null) return;
      final local = _local;
      if (local == null) return;
      if (hexDistance(local.position, hex) >
          _maxCastRange(local, hex, includeSelectedEnhancement: true)) {
        return;
      }
      setState(() => _targetHex = hex);
    } else {
      final local = _local;
      if (local == null) return;
      final origin = local.position;
      // Simulates DeterministicResolution.walkAvatar's real walk -- including
      // any conveyor
      // pushes along the way -- so the tap target the player sees matches
      // what will actually happen when the turn resolves. See
      // predictAvatarMove's doc comment for why this can't predict past a
      // closed conveyor loop (needs post-entropy RNG not known yet).
      final prediction = predictAvatarMove(
        state: widget.state,
        origin: origin,
        declaredPath: _movePath,
        budget: _localMoveBudget,
        moverId: widget.localPlayerId,
      );
      final tip = prediction.path.last;

      // Tap the last voluntary step (or the simulated tip it pushed to) → undo it.
      if (_movePath.isNotEmpty && (hex == _movePath.last || hex == tip)) {
        setState(() => _movePath = _movePath.sublist(0, _movePath.length - 1));
        return;
      }
      // Tap origin while path is non-empty → clear path.
      if (hex == origin && _movePath.isNotEmpty) {
        setState(() => _movePath = const []);
        return;
      }
      // Once the simulated walk hits an unresolved conveyor loop, nothing
      // past that point is predictable client-side -- stop planning there.
      if (prediction.indeterminate) return;
      // Next step must be adjacent to the simulated current position (i.e.
      // after any conveyor pushes so far), not just the last tile tapped.
      if (hexDistance(tip, hex) != 1) return;
      // Must not be impassable.
      final tileEffect = widget.state.tileEffects[hex];
      if (tileBlocksMovement(tileEffect)) return;
      // Must fit within remaining move budget (pushes are free, already
      // reflected in prediction.budgetRemaining).
      final stepCost =
          1 + (tileEffect is SlowTile ? tileEffect.extraMoveCost : 0);
      if (stepCost > prediction.budgetRemaining) return;

      setState(() => _movePath = [..._movePath, hex]);
    }

    // Always update inspection regardless of phase or action outcome.
    _updateInspection(hex);
  }

  // ── Turn submission ───────────────────────────────────────────────────────────

  Future<void> _submitTurn(
    TurnAction action, {
    List<HexCoord> movePath = const [],
    bool meditateInMove = false,
  }) async {
    if (_isBusy || _matchEnded) return;
    setState(() {
      _isBusy = true;
      // Summons is the first internal phase runTurn will actually reach;
      // _onEnginePhase corrects this to actionResolve once melee/resolution
      // begins. See _phaseLabel.
      _submittingPhase = TurnPhase.summons;
      // Freeze what's on the field now, so anything the engine conjures during
      // the awaits below stays off-screen until the resolution sequence blooms
      // it out of its cast tile. Handed off to _hiddenCloudIds & co. the moment
      // runTurn returns (and dropped on the error path). See ResolutionBaseline.
      _resolutionBaseline = ResolutionBaseline(
        cloudIds: widget.state.clouds.map((c) => c.id).toSet(),
        tileHexes: widget.state.tileEffects.keys.toSet(),
        minionIds: widget.state.minions.map((m) => m.id).toSet(),
      );
    });

    // Reveal any of our own pending Mystery casts whose fireTurn is the turn
    // this call is about to produce (state.turnNumber increments as the
    // very first step of TurnLoop.runTurn — see its doc comment).
    final upcomingTurn = widget.state.turnNumber + 1;
    final dueSecrets = _myPendingMysterySecrets
        .where((s) => s.fireTurn == upcomingTurn)
        .toList();
    final reveals = dueSecrets
        .map(
          (s) => DelayedSpellReveal(
            pendingSpellId: s.id,
            targetTile: s.target,
            delay: s.delay,
            nonce: s.nonce,
          ),
        )
        .toList();

    final input = TurnInput(
      action: action,
      movePath: movePath,
      meditateInMove: meditateInMove,
      delayedSpellReveals: reveals,
    );
    final staged = _stagedMysterySecret;

    try {
      final win = await _loop.runTurn(input);
      if (!mounted) return;
      _myPendingMysterySecrets.removeWhere(dueSecrets.contains);
      if (staged != null) _myPendingMysterySecrets.add(staged);
      _stagedMysterySecret = null;
      // Snapshot both event streams; the staggered reveal below plays one
      // spell's orb + card at a time, so it needs the raw cast events (with
      // casterId, to correlate each orb with its resolved spell) — not a
      // pre-flattened orb list. Conveyor chains have no card, so they still
      // play together up front.
      final castEvents = List<SpellCastEvent>.from(_loop.lastCastEvents);
      final chains = _loop.lastConveyorChainEvents
          .map((e) => ConveyorChainAnimation(path: e.path, killed: e.killed))
          .toList();
      // (Wizard walks already played, from inside runTurn — see
      // _playAvatarWalks.)
      final resolved = List<ResolvedSpellEvent>.from(_loop.lastResolvedSpells);
      // Wild magic is untelegraphed by design, so this snapshot is the ONLY
      // channel through which either player learns a global effect fired.
      final wildMagic = List<WildMagicEvent>.from(_loop.lastWildMagicEvents);
      // LAN-only (§1.3): SoloBattleSession casts are scripted dummies with a
      // sentinel commitment — never record them. Snapshot the base-cost map
      // synchronously (it's reset at the top of the next runTurn, and this
      // capture runs fire-and-forget).
      if (widget.session != null && widget.session is! SoloBattleSession) {
        unawaited(
          _recordSightings(
            resolved,
            Map<String, int>.from(_loop.lastCertifiedBaseManaCosts),
          ),
        );
      }
      // Hold every effect created this turn off the field; the reveal sequence
      // un-hides each spell's set (and blooms it) only once that spell's card
      // has finished. See _playResolvedSpellSequence / _bloomSpellEffects.
      //
      // Seeded from the resolution baseline rather than from the resolved
      // events alone, so this takes over exactly what the baseline was already
      // holding back — otherwise anything created outside a ResolvedSpellEvent
      // (a wild-magic conjuration, say) would pop into view at this handoff.
      // The tail of _playResolvedSpellSequence releases whatever no spell
      // claimed.
      final baseline = _resolutionBaseline;
      final hiddenClouds = widget.state.clouds
          .map((c) => c.id)
          .where((id) => baseline != null && !baseline.cloudIds.contains(id))
          .toSet();
      final hiddenTiles = widget.state.tileEffects.keys
          .where((h) => baseline != null && !baseline.tileHexes.contains(h))
          .toSet();
      final hiddenMinions = widget.state.minions
          .map((m) => m.id)
          .where((id) => baseline != null && !baseline.minionIds.contains(id))
          .toSet();
      for (final ev in resolved) {
        hiddenClouds.addAll(ev.createdCloudIds);
        hiddenTiles.addAll(ev.createdTileHexes);
        hiddenMinions.addAll(ev.createdMinionIds);
      }
      setState(() {
        _resetTurn();
        // A fresh turn means a fresh Phase 0: clear last turn's read-out
        // before the new exchange (kicked off below) replaces it, so the
        // "charms are down" warning can never linger a turn too long.
        _artifactRound = const ArtifactActivationRound();
        _castAnimations = const [];
        _conveyorChainAnimations = chains;
        _hiddenCloudIds = hiddenClouds;
        _hiddenTileHexes = hiddenTiles;
        _hiddenMinionIds = hiddenMinions;
        // The three sets above now hold back everything it was holding back.
        _resolutionBaseline = null;
        _effectBloom = null;
        // Set synchronously, in the same setState _resetTurn runs in, so no
        // further turn is submittable the instant win condition fires — even
        // though _handleMatchEnd's summary (and, for a real duel, its signed
        // MatchOutcome exchange) resolves slightly later. See _matchEnded's
        // doc comment.
        if (win != null && win.isOver) _matchEnded = true;
      });
      // Also runs when only the hidden sets are non-empty: something is being
      // held back that no card will reveal, and the sequence's tail is what
      // releases it.
      if (resolved.isNotEmpty ||
          chains.isNotEmpty ||
          wildMagic.isNotEmpty ||
          hiddenClouds.isNotEmpty ||
          hiddenTiles.isNotEmpty ||
          hiddenMinions.isNotEmpty) {
        unawaited(
          _playResolvedSpellSequence(resolved, castEvents, chains, wildMagic),
        );
      }
      // Open the next turn's dedicated artifact entropy immediately (the rod
      // roll), so it's already settled before the player looks at their
      // hand. The Phase-0 declaration itself waits for a long-press or the
      // action commit — see _beginArtifactPhaseForTurn. No-ops once the
      // match is over.
      unawaited(_beginArtifactEntropyForTurn());
      // The next turn's performing order — one seat further round the table
      // than this one's. Must run after runTurn returned, since that is what
      // advanced state.turnNumber and so what the order is keyed on.
      _armComponentSlot();
      if (win != null && win.isOver) {
        unawaited(_handleMatchEnd(win));
      }
    } catch (e) {
      if (!mounted) return;
      // Turn never committed — discard the not-yet-real staged secret rather
      // than leaving a reveal the engine has no matching PendingDelayedSpell
      // for (dueSecrets are left in place; they'll be retried next submit).
      _stagedMysterySecret = null;
      setState(() {
        _resetTurn();
        // Nothing left to reveal — whatever a half-applied turn managed to
        // create must not stay invisible for the rest of the match.
        _resolutionBaseline = null;
      });
      if (_isRealDuel) {
        // Fail-closed, same doctrine as [_verifierInitError]. In a LAN duel
        // every throw out of runTurn is a lockstep break: the turn is
        // half-applied on THIS device (TurnLoop mutates state as it goes) and
        // fully applied on the peer's, or vice versa. TurnLoop has already
        // sent a forfeit for the checks it owns. Continuing from here means
        // playing two different matches that agree on nothing but the frames
        // they exchange — and the divergence surfaces later as effects that
        // exist on one screen only (a cloud drawn on the caster's device but
        // not the target's, a cast the target's device never applied and so
        // never range-restricts). A 4-second snackbar is exactly how that
        // stays invisible until it looks like an unrelated rendering bug, so
        // this stops the duel and shows what actually broke.
        //
        // Two exceptions, literally: a turn that ends because the PEER
        // forfeited or their connection dropped is not a lockstep break and
        // must not be reported as one. Those two now interrupt a blocked
        // exchange instead of leaving it hanging until teardown (see
        // BattleSession._awaitFrame), which means they can surface here for
        // the first time — and `_turnError` outranks both dedicated banners in
        // build(), so reporting them here would replace "they ended the duel,
        // and here is why they said" with "this duel broke lockstep". The
        // session's own peerForfeit/peerConnectionLost callbacks have already
        // set the right state; this just declines to overwrite it.
        if (e is PeerForfeitException || e is PeerConnectionLostException) {
          return;
        }
        setState(() => _turnError = '$e');
      } else {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Turn error: $e')));
      }
    }
  }

  // ── Match end (MASTER_APPRENTICE_PLAN.md §4) ────────────────────────────────

  /// Builds the local result from [win] and, for a real duel between exactly
  /// two avatars, signs a [MatchOutcome] and exchanges it with the peer via
  /// [BattleSession.exchangeMatchOutcome] before persisting a
  /// [MatchOutcomeRecord] — the two-signature artifact a future graduation-
  /// battle settlement (docs/MASTER_APPRENTICE_PLAN.md §7.4) can trust.
  ///
  /// Never blocks the local win/loss/draw display on the network exchange:
  /// [_matchEnded] (and the summary's own [_MatchEndSummary.isLocalVictor])
  /// are this device's own TurnLoop's verdict, which is authoritative for
  /// THIS device regardless of whether the peer cooperates with signing.
  /// [_MatchEndSummary.settled] just says whether that verdict is now also
  /// PROVABLE to a third party.
  ///
  /// Solo/practice (no real peer) and team battles (more than two avatars,
  /// where "the loser" isn't a single well-defined party) both skip signing
  /// entirely and report an unsettled result — see the two early returns.
  Future<void> _handleMatchEnd(WinCheckResult win) async {
    if (win.winningTeamId == null) {
      if (!mounted) return;
      setState(
        () => _matchEndSummary = const _MatchEndSummary(
          isDraw: true,
          isLocalVictor: false,
        ),
      );
      return;
    }

    final avatars = widget.state.avatars;
    final isLocalVictor = avatars.any(
      (a) =>
          a.teamId == win.winningTeamId && a.playerId == widget.localPlayerId,
    );

    if (!_isRealDuel || avatars.length != 2) {
      if (!mounted) return;
      setState(
        () => _matchEndSummary = _MatchEndSummary(
          isDraw: false,
          isLocalVictor: isLocalVictor,
        ),
      );
      return;
    }

    final identity = _localIdentity;
    final matchId = widget.matchId;
    final peerOwnerPubkeyHex = widget.peerOwnerPubkeyHex;
    final peerRawPubkey = widget.peerRawPubkey;
    String? settlementError;
    var settled = false;

    if (identity == null ||
        matchId == null ||
        peerOwnerPubkeyHex == null ||
        peerRawPubkey == null) {
      // Should be unreachable when _isRealDuel is true (all four are set
      // together — see widget.peerBookRoot's doc comment) but fail closed
      // rather than crash on a future refactor that breaks that invariant.
      settlementError = 'missing real-duel identity/peer data';
    } else {
      try {
        final victorAvatar = avatars.firstWhere(
          (a) => a.teamId == win.winningTeamId,
        );
        final loserAvatar = avatars.firstWhere(
          (a) => a.teamId != win.winningTeamId,
        );
        final stateHash = await Sha256().hash(widget.state.toCanonicalBytes());
        final outcome = MatchOutcome(
          matchIdHex: _bytesToHex(matchId),
          victorPubkeyHex: victorAvatar.ownerPubkeyHex,
          loserPubkeyHex: loserAvatar.ownerPubkeyHex,
          finalStateHashHex: _bytesToHex(Uint8List.fromList(stateHash.bytes)),
          pactIdHex: widget.pactIdHex ?? kNoGraduationPact,
          endedAtTurn: widget.state.turnNumber,
        );
        final mine = await SignedMatchOutcome.sign(
          outcome: outcome,
          signerIdentity: identity,
        );
        final theirs = await (widget.session! as BattleSession)
            .exchangeMatchOutcome(mine);

        if (!outcome.sameFieldsAs(theirs.outcome)) {
          settlementError =
              'peer reported a different match outcome — not settled';
        } else if (theirs.rawPubkeyBase64 != base64Encode(peerRawPubkey) ||
            !_hexEq(theirs.signerPubkeyHex, peerOwnerPubkeyHex)) {
          settlementError =
              'peer outcome not signed by the authenticated peer identity';
        } else {
          final record = MatchOutcomeRecord(
            outcome: outcome,
            mine: mine,
            theirs: theirs,
          );
          if (!await record.isFullyValid()) {
            settlementError = 'match outcome record failed validation';
          } else {
            await record.save();
            settled = true;
          }
        }
      } catch (e) {
        settlementError = 'match outcome exchange failed: $e';
      }
    }

    if (!mounted) return;
    setState(() {
      _matchEndSummary = _MatchEndSummary(
        isDraw: false,
        isLocalVictor: isLocalVictor,
        settled: settled,
        settlementError: settlementError,
      );
    });
  }

  // ── Sightings capture (docs/SIGHTINGS_PLAN.md §4) ───────────────────────────

  /// Persists every opponent cast in [resolved] as a [SightingAsset]. A
  /// local side effect only — never surfaces a failure to the player, never
  /// blocks or affects the turn. [baseManaCosts] must be a snapshot taken
  /// synchronously right after `runTurn` returns (see the call site in
  /// [_submitTurn]), since this runs fire-and-forget and
  /// `TurnLoop.lastCertifiedBaseManaCosts` is reset at the top of the next
  /// turn. Needs no `mounted` guard: this only touches disk, never widget
  /// state.
  Future<void> _recordSightings(
    List<ResolvedSpellEvent> resolved,
    Map<String, int> baseManaCosts,
  ) async {
    try {
      for (final capture in sightingsFromResolved(
        resolved,
        widget.localPlayerId,
        widget.state.avatars,
        baseManaCosts,
      )) {
        await SightingAsset.record(
          opponentPubkeyHex: capture.opponentPubkeyHex,
          commitmentHex: capture.commitmentHex,
          spellName: capture.spellName,
          formula: capture.formula,
          t: capture.t,
          tier: capture.tier,
          manaCost: capture.manaCost,
        );
      }
    } catch (e) {
      debugPrint('Sightings capture failed: $e');
    }
  }

  // ── Resolution-phase card reveal ────────────────────────────────────────────

  /// Plays the MtG-style card reveal for each spell resolved this turn, in
  /// resolution order (design: "fewest step count first, ties by hash" --
  /// already the order TurnLoop.lastResolvedSpells is in). Each spell resolves
  /// one at a time and in full: its cast orb flies out and hits, its card
  /// grows out of the hit tile and holds for 2 seconds, then the next spell's
  /// orb goes off. Afterwards the card becomes a neutral-tray thumbnail
  /// (incantation) or is recorded for its on-grid summon. Conveyor chains have
  /// no card, so they play together up front. Clears the previous turn's tray
  /// first ("at the end of turn clear away those thumbnails").
  ///
  /// [castEvents] is the raw cast-event stream. It's a subsequence of [events]
  /// in the same resolution order (a resolved spell has an orb only when its
  /// formula has an elemental affinity), so a single advancing cursor matches
  /// each spell to its orb — see the (casterId, targetHex) guard below.
  /// Shows one wild-magic reveal for 2.5 seconds (or until tapped away), then
  /// returns. Serialised by the caller so two effects from a balanced spell
  /// read one at a time rather than stacking.
  Future<void> _showWildMagicBanner(WildMagicEvent event) async {
    // Since slice 7 a wild-magic event can have MORE THAN ONE author: two
    // casters who roll the same effect in one simultaneous batch produce a
    // single world event between them. The banner names whose runes were in
    // it, which is all the attribution the player needs — the effect hit
    // everyone either way (see wild_magic_applicator.dart's symmetry rule).
    final ids = event.contributingCasterIds;
    final mine = ids.contains(widget.localPlayerId);
    final theirs = ids.any((id) => id != widget.localPlayerId);
    final casterLabel = mine && theirs
        ? 'runes on both sides'
        : mine
            ? 'your own rune'
            : theirs
                ? "your opponent's rune"
                : 'the leyline itself';
    final navigator = Navigator.of(context);
    final entry = OverlayEntry(
      builder: (_) => _WildMagicBanner(event: event, casterLabel: casterLabel),
    );
    navigator.overlay?.insert(entry);
    await Future<void>.delayed(const Duration(milliseconds: 2500));
    entry.remove();
  }

  Future<void> _playResolvedSpellSequence(
    List<ResolvedSpellEvent> events,
    List<SpellCastEvent> castEvents,
    List<ConveyorChainAnimation> chains,
    List<WildMagicEvent> wildMagic,
  ) async {
    if (!mounted) return;
    // Wizard walks are NOT played here: they already played, from inside
    // runTurn at the moment the engine moved the tokens (_playAvatarWalks).
    // Wild magic resolves BEFORE formula effects (design v3.0 L746), so it is
    // revealed first — and on its own full-screen banner rather than folded
    // into the spell cards, because it is a global, symmetric effect that has
    // nothing to do with the tile the spell was aimed at. See
    // _WildMagicBanner's doc comment for why this reveal is load-bearing.
    for (final ev in wildMagic) {
      if (!mounted) return;
      await _showWildMagicBanner(ev);
    }
    if (!mounted) return;
    // Reserve the tray for the whole reveal if any incantation will land in it,
    // so even the first one's card can measure the tray and shrink into its
    // real slot (rather than falling back to a bottom-of-screen guess).
    setState(() {
      _incantationTray = [];
      _revealReservesTray = events.any((e) => !e.isSummon);
    });

    final castMs = _castAnimController.duration?.inMilliseconds ?? 1000;
    final impact = Duration(
      milliseconds: (castMs * kCastOrbImpactFraction).round(),
    );

    // Conveyor pushes have no card to reveal — play them together first, then
    // clear them so they don't replay under each staggered spell orb (both
    // ride the shared _castAnimController).
    if (chains.isNotEmpty) {
      await _castAnimController.forward(from: 0);
      if (!mounted) return;
      setState(() => _conveyorChainAnimations = const []);
    }

    var castCursor = 0;
    for (final ev in events) {
      if (!mounted) return;

      // This spell's orb, if it has one (see the [castEvents] doc note).
      final cast =
          castCursor < castEvents.length &&
              castEvents[castCursor].casterId == ev.casterId &&
              castEvents[castCursor].toHex == ev.targetHex
          ? castEvents[castCursor++]
          : null;

      // Fly the orb out and let it reach its target before the card grows out
      // of the burst (the burst's tail plays behind the card's barrier).
      if (cast != null) {
        setState(
          () => _castAnimations = [
            CastAnimation(
              fromHex: cast.fromHex,
              toHex: cast.toHex,
              color: BattlefieldPainter.colorForWizard(
                cast.casterId,
                localPlayerId: widget.localPlayerId,
                orderedPlayerIds: widget.state.avatars
                    .map((a) => a.playerId)
                    .toList(),
              ),
            ),
          ],
        );
        _castAnimController.forward(from: 0);
        await Future<void>.delayed(impact);
        if (!mounted) return;
      }

      // Card reveal, not effect bloom — the card is the moment the player is
      // looking at the spell (E-2). Fire-and-forget: a decode/store hiccup on
      // one clip must never block or fail the reveal it's decorating.
      unawaited(_playSpellSound(ev));

      await showSpellCardFullscreen(
        context,
        ev.spell,
        autoDismissAfter: const Duration(seconds: 2),
        growFrom: _tileGlobalCenter(ev.targetHex),
        shrinkTo: _thumbnailTarget(ev),
        countered: ev.wasCountered,
        counteredByLabel: ev.wasCountered
            ? (ev.counterCharmOwnerId == widget.localPlayerId
                  ? 'Blocked by your ward'
                  : "Blocked by the opponent's ward")
            : null,
        // A charm that matched only a prefix cancels those formulas and lets
        // the rest through — the card must still read as a spell that
        // resolved, so it gets the banner, not the ribbon.
        partialCounterLabel: _partialCounterLabel(ev),
      );
      if (!mounted) return;
      // A countered cast leaves no thumbnail anywhere — nothing was
      // actually summoned or resolved, so neither the grid map nor the
      // incantation tray gets an entry for it.
      if (!ev.wasCountered) {
        setState(() {
          final minionId = ev.summonMinionId;
          if (ev.isSummon && minionId != null) {
            _summonSpellByMinionId[minionId] = ev.spell;
          } else if (!ev.isSummon) {
            _incantationTray = [
              ..._incantationTray,
              _ResolvedThumbnail(spell: ev.spell, casterId: ev.casterId),
            ];
          }
        });
      }

      // Now that the card has finished, let this spell's created effects
      // (clouds/terrain/summons) bloom out of the cast tile before the next
      // orb launches.
      await _bloomSpellEffects(ev);
      if (!mounted) return;
    }

    // Clear the last spell's orb and reveal anything still held back (defensive
    // — every created handle should already have bloomed via its event).
    if (mounted) {
      setState(() {
        _castAnimations = const [];
        _hiddenCloudIds = const {};
        _hiddenTileHexes = const {};
        _hiddenMinionIds = const {};
        _effectBloom = null;
        _revealReservesTray = false;
      });
    }
    // Finding 3 (docs/SPELL_SOUND_PACK_PLAN.md): an 8.5s clip would otherwise
    // outlive its 2s card and bleed into the next phase (E-3).
    unawaited(_soundPlayerOrNull?.stopAll() ?? Future<void>.value());
  }

  /// Plays [ev]'s resolution sound: a fizzle for a full counter (nothing
  /// resolved, so the spell's own sound would be a lie), or the spell's
  /// resolved sound otherwise — D-6's elemental default when it has no
  /// explicit one. [normalized] selects the gain policy (E-4/D-4): built-in
  /// pack clips (including the D-6 default, which only ever picks a pack
  /// entry) were loudness-matched at build time; imported/synced clips
  /// weren't and play at [kUnnormalizedSoundGain] instead.
  Future<void> _playSpellSound(ResolvedSpellEvent ev) async {
    try {
      if (ev.wasCountered) {
        final bytes = await loadPackSound('magicfail');
        if (bytes == null) return;
        await _soundPlayer.play(bytes, settings: _soundSettings, normalized: true);
        return;
      }
      final bytes = await resolveSpellSound(ev.spell);
      if (bytes == null) return;
      final normalized =
          ev.spell.soundHash == null || ev.spell.soundSource == SpellSoundSource.builtIn;
      await _soundPlayer.play(bytes, settings: _soundSettings, normalized: normalized);
    } catch (_) {
      // Sound is cosmetic — never let a resolve/decode failure interrupt the
      // reveal sequence it's decorating.
    }
  }

  /// Un-hides the battlefield effects [ev] created and scales them up out of
  /// its cast tile over [_effectBloomController]'s 0.5s. No-op for a spell that
  /// created nothing (a pure damage/status incantation).
  Future<void> _bloomSpellEffects(ResolvedSpellEvent ev) async {
    final cloudIds = ev.createdCloudIds.toSet();
    final tileHexes = ev.createdTileHexes.toSet();
    final minionIds = ev.createdMinionIds.toSet();
    if (cloudIds.isEmpty && tileHexes.isEmpty && minionIds.isEmpty) return;
    if (!mounted) return;
    setState(() {
      _hiddenCloudIds = _hiddenCloudIds.difference(cloudIds);
      _hiddenTileHexes = _hiddenTileHexes.difference(tileHexes);
      _hiddenMinionIds = _hiddenMinionIds.difference(minionIds);
      _effectBloom = EffectBloom(
        origin: ev.targetHex,
        cloudIds: cloudIds,
        tileHexes: tileHexes,
        minionIds: minionIds,
      );
    });
    await _effectBloomController.forward(from: 0);
    if (!mounted) return;
    setState(() => _effectBloom = null);
  }

  /// Global-screen pixel center of [hex] on the battlefield, or null if the
  /// battlefield hasn't been laid out yet. Uses the same hex→pixel mapping the
  /// painter does (in _fieldCenter/_hexSize space) then lifts it to global
  /// coordinates via the battlefield's RenderBox — so a resolution card can
  /// grow out of the exact tile the spell hit.
  Offset? _tileGlobalCenter(HexCoord hex) {
    final box =
        _battlefieldKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    return box.localToGlobal(hexToPixel(hex, _fieldCenter, _hexSize));
  }

  /// Banner text for a PARTIALLY countered cast — a trajectory charm matched a
  /// prefix of the spell and cancelled those formulas while the rest resolved
  /// (docs/COUNTER_CHARM_KINSHIP_PLAN.md §2.3). Null when no charm fired, and
  /// null for a full counter, which gets the COUNTERED ribbon instead.
  String? _partialCounterLabel(ResolvedSpellEvent ev) {
    if (ev.wasCountered || ev.counteredFormulas <= 0) return null;
    final n = ev.counteredFormulas;
    final whose = ev.counterCharmOwnerId == widget.localPlayerId
        ? 'your ward'
        : "the opponent's ward";
    return 'PARTLY COUNTERED — $n formula${n == 1 ? "" : "s"} '
        'cancelled by $whose';
  }

  /// Where [ev]'s card should reverse-bloom to as it resolves — the spot its
  /// thumbnail comes to rest. A summon lives on the grid, so its own tile; an
  /// incantation drops into the next open slot of the left-aligned tray, which
  /// we compute from the tray box + the slot index (the thumbnail isn't added
  /// until after the card, so the current tray length *is* its index). A
  /// countered cast leaves no thumbnail anywhere — null here lets the card's
  /// own fallback shrink it straight back into the tile it hit, i.e. it just
  /// dissolves at the point of impact instead of flying to a resting spot.
  Offset? _thumbnailTarget(ResolvedSpellEvent ev) {
    if (ev.wasCountered) return null;
    final summonPos = ev.summonPosition;
    if (ev.isSummon && summonPos != null) return _tileGlobalCenter(summonPos);

    final box =
        _incantationTrayKey.currentContext?.findRenderObject() as RenderBox?;
    if (box != null && box.hasSize) {
      // _IncantationTray geometry: 8px horizontal padding, 48px thumbnails,
      // 8px separators, laid out left→right in resolution order.
      const pad = 8.0, thumb = 48.0, sep = 8.0;
      final index = _incantationTray.length;
      final topLeft = box.localToGlobal(Offset.zero);
      final x = topLeft.dx + pad + index * (thumb + sep) + thumb / 2;
      final y = topLeft.dy + box.size.height / 2;
      return Offset(x, y);
    }

    // Tray not laid out yet (shouldn't happen while reserved) — aim bottom-left.
    final size = MediaQuery.of(context).size;
    return Offset(40, size.height - 40);
  }

  /// Long-press on the battlefield: re-opens a live summon's card (with
  /// current/max HP) if the tapped hex holds one this client can resolve a
  /// card for — its own cast, or the original's card tinted blue for a copied
  /// creature (see [_cardForMinion]). No-op everywhere else.
  void _onLongPressBattlefield(Offset localPos) {
    final hex = pixelToHex(localPos, _fieldCenter, _hexSize);
    final minion = widget.state.minions
        .where((m) => m.isAlive && m.occupiedTiles.contains(hex))
        .firstOrNull;
    if (minion == null) return;
    final card = _cardForMinion(minion, _summonSpellByMinionId);
    if (card == null) return;
    showSpellCardFullscreen(
      context,
      card.spell,
      liveHp: minion.hp,
      // The creature's own max, not the card's: a copy's card is borrowed and
      // an Illusions clone is 1 HP whatever it copied.
      liveMaxHp: minion.stats.maxHp,
      phantasmal: card.phantasmal,
    );
  }

  // ── Build ───────────────────────────────────────────────────────────────────

  /// Confirms before abandoning a duel in progress.
  ///
  /// Leaving now closes the session and its socket (see [dispose]), which the
  /// opponent sees as "lost contact" — the duel really is over for both
  /// players, and there is no rejoin. That makes a bare mis-tap on a phone
  /// app bar expensive, which is what this guards.
  ///
  /// Skipped once the match has ended: at that point the close button is just
  /// "go back", and there is nothing left to abandon.
  Future<void> _confirmLeaveBattle() async {
    if (!leavingNeedsConfirmation(
      isRealDuel: _isRealDuel,
      matchEnded: _matchEnded,
    )) {
      if (mounted) Navigator.of(context).pop();
      return;
    }
    final leave = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Leave this duel?'),
        content: const Text(
          'The duel ends here for both of you — your opponent is told you '
          'lost contact, and there is no way back into this match.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Keep duelling'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Leave'),
          ),
        ],
      ),
    );
    if (leave == true && mounted) Navigator.of(context).pop();
  }

  /// Extra guidance appended to a verifier-init failure when it looks like
  /// the one-time SRS download, rather than a genuine fault.
  ///
  /// A device that has never inscribed a spell has no SRS cached, and
  /// `initSrsCached` fetches it over the network on first use — including on
  /// a device that only ever *verifies* (CLAUDE.md Bug-Avoidance #4). At a
  /// venue with no usable internet that is a blocking error whose raw text
  /// ("SRS download failed", a reqwest timeout) gives a player no idea that
  /// the fix is "do this once at home". The check is a substring sniff on an
  /// error string, so it is deliberately additive — it never replaces the
  /// underlying message, only appends to it.
  String _srsHint(String error) {
    final e = error.toLowerCase();
    final looksLikeSrs = e.contains('srs') ||
        e.contains('download') ||
        e.contains('timedout') ||
        e.contains('timed out');
    if (!looksLikeSrs) return '';
    return '\n\nThis device downloads its proving data once, the first time '
        'it duels or inscribes a spell, and needs an internet connection to '
        'do it. Connect to the internet and inscribe a spell once; after '
        'that, duelling works offline.';
  }

  /// Plain-English gloss for a peer forfeit tag (the strings passed to
  /// `BattleTurnSession.sendForfeit`). The raw tag is always shown alongside
  /// this — it is what makes a bug report actionable — but the tags read as
  /// accusations of cheating, and during development the overwhelmingly more
  /// likely cause is a mismatch between two builds or two libraries.
  String _forfeitExplanation(String reason) {
    final tag = reason.split(':').first;
    switch (tag) {
      case 'unauthorized_spell':
        return 'They saw a spell cast from this device that is not bound to '
            'your Runekey — most often a spell that reached your library by '
            'import or trade, which stays bound to the wizard who inscribed '
            'it. Check the Library: spells not bound to your key are marked.';
      case 'invalid_spell_proof':
      case 'missing_spell_proof':
        return "A spell cast from this device carried no valid proof for their "
            'device to verify.';
      case 'duplicate_spell_cast':
        return 'They saw the same spell cast twice in one match.';
      case 'book_membership_failed':
      case 'cast_out_of_hand':
        return 'They saw a spell cast that was not in this device’s committed '
            'chapter, or not in the hand dealt from it.';
      case 'unbacked_enhancement_claim':
        return 'They saw a cast-time enhancement claimed that this spell’s '
            'certified dominance data does not support.';
      case 'state_hash_mismatch':
        return 'The two devices computed different battlefields for the same '
            'turn. Usually a version mismatch — check both are running the '
            'same build.';
      case 'battle_protocol_mismatch':
        return 'The two devices are running incompatible battle protocol '
            'versions. Update both to the same build.';
      case 'armor_certification_failed':
      case 'armor_loadout_malformed':
        return 'An equipped Aetherial Armor could not be certified before the '
            'duel began — its proof, its owner, or the artifact slots it costs '
            'did not check out on one of the two devices.';
      case 'bad_state_signature':
      case 'missing_state_signature':
      case 'auth_failed':
      case 'auth_self':
      case 'auth_malformed_response':
        return 'Identity authentication between the two devices failed.';
      case 'withheld_reveal':
      case 'withheld_forced_reveal':
      case 'withheld_refresh_reveal':
        return 'Their device stopped waiting for a commit-reveal step from '
            'this one. Usually a dropped connection rather than foul play.';
      case 'malformed_reveal':
      case 'malformed_forced_reveal':
      case 'bad_spell_reveal':
      case 'bad_scry_opening':
      case 'forced_reveal_slot_mismatch':
      case 'commitment_mismatch':
        return 'A commit-reveal step from this device did not match what was '
            'committed to earlier in the turn.';
      default:
        return 'Their device found something it could not verify and stopped.';
    }
  }

  /// Full-screen, non-dismissable failure state — the only thing this screen
  /// renders once a duel is unsafe to play (verifier init failed, or lockstep
  /// broke mid-turn). Deliberately a dead end with one way out: there is no
  /// "continue anyway" for a match whose two devices disagree.
  Widget _blockingError(String message) => Scaffold(
    backgroundColor: const Color(0xFF1A1008),
    body: SafeScreenBody(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, color: Colors.redAccent, size: 48),
              const SizedBox(height: 16),
              SelectableText(
                message,
                style: manuscriptBodyStyle(fontSize: 14, color: kParchmentColor),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              OutlinedButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Leave'),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    // Stage 2 fail-closed gate (see _initTurnLoop): never render the
    // interactive battle UI before _loop exists, and never silently
    // proceed if verifier init failed.
    final initError = _verifierInitError;
    if (initError != null) {
      return _blockingError(
        'Could not prepare this duel for play:\n$initError'
        '${_srsHint(initError)}',
      );
    }
    // Same gate for a mid-turn lockstep break (see _submitTurn's catch): the
    // two devices have diverged, so there is nothing safe left to render.
    final turnError = _turnError;
    if (turnError != null) {
      return _blockingError(
        'This duel broke lockstep and cannot continue — the two devices no '
        'longer agree on the battlefield:\n\n$turnError',
      );
    }
    // The peer's device stopped and told us why. Nothing is wrong with THIS
    // device's state, but the match is over either way: they are no longer
    // answering any exchange. Ranked below _turnError because when both fire,
    // the local diagnosis is the more specific one.
    final forfeit = _peerForfeitReason;
    if (forfeit != null) {
      return _blockingError(
        "The other wizard's device ended this duel:\n\n"
        '${_forfeitExplanation(forfeit)}\n\n($forfeit)',
      );
    }
    // Ranked last of the three: a forfeit or a local desync says WHY the duel
    // stopped, and both of those also end with the socket closing. This is
    // what is left when neither device diagnosed anything — the peer simply
    // went away.
    final lost = _connectionLostReason;
    if (lost != null) {
      return _blockingError(
        'Lost contact with the other wizard.\n\n'
        'Their device stopped answering — the app was closed or '
        'backgrounded, the screen locked, or they moved out of range of the '
        'network. The duel cannot continue from here.\n\n($lost)',
      );
    }
    if (!_loopReady) {
      return const Scaffold(
        backgroundColor: Color(0xFF1A1008),
        body: Center(
          child: CircularProgressIndicator(color: kIlluminationGold),
        ),
      );
    }

    final local = _local;
    final config = widget.state.config;
    final foes = _opponents;

    final scaffold = Scaffold(
      backgroundColor: const Color(0xFF1A1008),
      appBar: AppBar(
        backgroundColor: kInkColor,
        foregroundColor: kParchmentColor,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: 'Leave battle',
          onPressed: _confirmLeaveBattle,
        ),
        title: Text(
          widget.state.turnNumber == 0
              ? 'BATTLE'
              : 'TURN ${widget.state.turnNumber}',
          style: manuscriptHeaderStyle(fontSize: 18, color: kParchmentColor),
        ),
        actions: [
          // Reachable from inside battle, not only from Settings (E-4) — a
          // player who wants quiet mid-duel shouldn't have to leave it to get
          // there.
          IconButton(
            icon: Icon(_soundSettings.muted ? Icons.volume_off : Icons.volume_up),
            tooltip: _soundSettings.muted ? 'Unmute spell sounds' : 'Mute spell sounds',
            onPressed: () => unawaited(_toggleSoundMute()),
          ),
        ],
      ),
      // The app is edge-to-edge on Android (API 36 target; Android 15+ has no
      // opt-out), so this body is laid out behind the system navigation bar
      // and the spell hand at the bottom of the Column would be drawn under
      // it. SafeScreenBody is the app-wide policy for that — see
      // safe_layout.dart. It was first noticed on Samsung hardware, but only
      // because Samsung defaults to the taller 3-button nav bar; the missing
      // inset is the same on every device and the platform reports its size.
      body: SafeScreenBody(
        child: Column(
          children: [
            // DEV FLAG (lib/dev_flags.dart): a duel running without proof
            // verification must never be mistakable for a real one. Delete
            // this with the flag.
            if (kAllowProoflessSpells && _isRealDuel)
              const _UnverifiedPlayBanner(),
  
            // Phase banner — always visible, so it's never ambiguous whether
            // the battle is waiting on the local player's Main/Move decision
            // or playing out Summons/Resolution.
            _PhaseBanner(label: _phaseLabel),
  
            // Names the peer frame this device has been blocked on. Without it a
            // stalled exchange is indistinguishable from a hung app: the board
            // just stops responding, with no error, which is exactly how a
            // playtest freeze was reported. Purely informational — the duel is
            // still live and will resume the moment the frame arrives.
            if (_stalledExchange != null)
              _StalledExchangeBanner(exchange: _stalledExchange!),
  
            // Opponent strip — swaps to the tapped enemy creature's HP (no
            // mana row: minions don't have any) when one is inspected. Guards
            // isAlive too: a dead minion is removed from state.minions by the
            // engine, but this reference isn't cleared until the next tap.
            // Watery Scrying Pool reveal — sits directly over the opponent
            // strip below it; sourced from TurnLoop.revealedEnemyHand, which
            // is reset every turn (see TurnLoop._beginTurnImpl), so this
            // clears on its own at the next turn boundary with no separate
            // expiry timer here.
            if ((_loop.revealedEnemyHand?.isNotEmpty ?? false) && foes.isNotEmpty)
              _RevealedHandRow(spells: _loop.revealedEnemyHand!),
  
            if (_inspectedMinion != null && _inspectedMinion!.isAlive)
              _EnemyCreatureHudRow(minion: _inspectedMinion!)
            else if (foes.isNotEmpty)
              _OpponentHudRow(
                avatars: foes,
                maxHp: config.playerHp,
                onOpenGraveyard: _showGraveyard,
              ),
  
            // Battlefield — tappable, with the 4 artifact corner tiles
            // floating over the empty space around the hex map (see
            // _ArtifactCornerTile) so they don't cost the map any of the
            // Expanded area's height.
            Expanded(
              child: Stack(
                children: [
                  Positioned.fill(
                    child: LayoutBuilder(
                      builder: (ctx, constraints) {
                        final size = Size(
                          constraints.maxWidth,
                          constraints.maxHeight,
                        );
                        final hSize = _hexSizeFromConstraints(
                          size,
                          config.gridRadius,
                        );
                        final center = Offset(size.width / 2, size.height / 2);
                        // Store for tap handler (accessed on next frame — safe
                        // because the values only change on resize, not during
                        // a turn).
                        _hexSize = hSize;
                        _fieldCenter = center;
                        return Stack(
                          children: [
                            GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTapUp: (d) => _onTapBattlefield(d.localPosition),
                              onLongPressStart: (d) =>
                                  _onLongPressBattlefield(d.localPosition),
                              // Cosmetic terrain backdrop, drawn first and on the
                              // same hex geometry as the battlefield so playable
                              // tiles sit squarely on their terrain. See
                              // lib/ui/scenery/.
                              child: CustomPaint(
                                painter: SceneryBackdropPainter(
                                  map: _sceneryFor(size, hSize),
                                  atlas: _sceneryAtlas,
                                  hexSize: hSize,
                                  playRadius: config.gridRadius,
                                ),
                                child: CustomPaint(
                                  key: _battlefieldKey,
                                  painter: BattlefieldPainter(
                                    radius: config.gridRadius,
                                    hexSize: hSize,
                                    // Wash the playable tiles instead of filling
                                    // them, so the scenery shows through inside the
                                    // grid. Falls back to the opaque board if the
                                    // atlas never loaded.
                                    terrainBeneath: _sceneryAtlas != null,
                                    // Same atlas again, this time to build
                                    // impassable tiles as raised rock. Without it
                                    // they fall back to the flat crosshatch.
                                    sceneryAtlas: _sceneryAtlas,
                                    occupancy: widget.state.battlefield.occupancy,
                                    localPlayerId: widget.localPlayerId,
                                    highlightHex: _targetHex,
                                    // Renders the *simulated* path (including any
                                    // free conveyor push-throughs), not just the
                                    // raw tiles tapped, so the player sees where
                                    // they'll actually end up -- see
                                    // predictAvatarMove.
                                    movePath: _local != null
                                        ? predictAvatarMove(
                                            state: widget.state,
                                            origin: _local!.position,
                                            declaredPath: _movePath,
                                            budget: _localMoveBudget,
                                            moverId: widget.localPlayerId,
                                          ).path.skip(1).toList()
                                        : _movePath,
                                    spellRangeRadius:
                                        _selectedSpell != null && _local != null
                                        ? _maxCastRange(
                                            _local!,
                                            _local!.position,
                                            includeSelectedEnhancement: true,
                                          )
                                        : 0,
                                    casterPos: _local?.position,
                                    minions: widget.state.minions
                                        .where((m) => m.isAlive)
                                        .toList(),
                                    localTeamId: _local?.teamId,
                                    barrierRings: _barrierRings(),
                                    pulseAnimation: _pulseController,
                                    castAnimations: _castAnimations,
                                    castAnimation: _castAnimController,
                                    avatarMoveAnimations: _avatarMoveAnimations,
                                    minionMoveAnimations: _minionMoveAnimations,
                                    moveAnimation: _moveAnimController,
                                    attackAnimations: _attackAnimations,
                                    attackAnimation: _attackAnimController,
                                    avatarAtlas: _avatarAtlas,
                                    avatarAssignment: _avatarAssignment,
                                    tileEffects: widget.state.tileEffects,
                                    terrainHp: _terrainHpForPainter(),
                                    terrainBarrierElements:
                                        _terrainBarrierElements(),
                                    blockedLandingHex: _blockedLandingHex(),
                                    clouds: widget.state.clouds,
                                    directionPickHexes:
                                        _phase == _InputPhase.pickingDirection &&
                                            _conveyorPickOrigin != null
                                        ? HexGrid.directions
                                              .map(
                                                (d) => HexCoord(
                                                  _conveyorPickOrigin!.q + d.q,
                                                  _conveyorPickOrigin!.r + d.r,
                                                ),
                                              )
                                              .toList()
                                        : const [],
                                    conveyorChainAnimations:
                                        _conveyorChainAnimations,
                                    pendingCastOrbs: _pendingCastOrbs,
                                    scryRevealHex: _scryRevealedTile,
                                    meleePickHexes: _pickingMelee
                                        ? _meleeCandidates
                                        : const [],
                                    // While the free-move prompt is up, the
                                    // highlight shows the run built so far (or
                                    // the legal first steps when nothing is
                                    // tapped yet), tinted by whichever resource
                                    // is paying: air for a free burst step,
                                    // water/fire for a Boost.
                                    freeMovePickHexes: _pickingFreeMove
                                        ? (_freeMovePath.isEmpty
                                              ? _loop.freeMoveCandidatesFor(
                                                  _local!.playerId,
                                                )
                                              : _freeMovePrediction.path
                                                    .skip(1)
                                                    .toList())
                                        : const [],
                                    freeMovePickColor:
                                        _freeMoveGrant.boostResource == null
                                        ? null
                                        : BattlefieldPainter.colorForAffinity(
                                            _freeMoveGrant.boostResource!,
                                          ),
                                    hiddenCloudIds: _hiddenCloudIds,
                                    hiddenTileHexes: _hiddenTileHexes,
                                    hiddenMinionIds: _hiddenMinionIds,
                                    resolutionBaseline: _resolutionBaseline,
                                    effectBloom: _effectBloom,
                                    effectBloomAnimation: _effectBloomController,
                                  ),
                                  child: const SizedBox.expand(),
                                ),
                              ),
                            ),
                            // Non-interactive: long-press is still hit-tested
                            // manually via _onLongPressBattlefield above, using
                            // pixelToHex on the raw tap position, so these
                            // thumbnails must never intercept a pointer event.
                            IgnorePointer(
                              child: _MinionArtOverlay(
                                minions: widget.state.minions
                                    .where((m) => m.isAlive)
                                    .toList(),
                                spellByMinionId: _summonSpellByMinionId,
                                localTeamId: _local?.teamId,
                                center: center,
                                hexSize: hSize,
                                moveAnimations: _minionMoveAnimations,
                                moveAnimation: _moveAnimController,
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                  Positioned(
                    top: 0,
                    left: 0,
                    child: _ArtifactCornerTile(
                      corner: _TileCorner.topLeft,
                      icon: _kCounterCharmDisplay.$1,
                      color: _kCounterCharmDisplay.$2,
                      label: _kCounterCharmDisplay.$3,
                      count: _accoutrementCount(
                        local,
                        AccoutrementKind.counterCharm,
                      ),
                      // Charms have no activation to spend, so this tile never
                      // lights up — but it DOES grey out on a turn the local
                      // wizard spent something else, because that is precisely
                      // when their charms are down (§2.2). A tap explains it;
                      // there's nothing to long-press-declare.
                      dimmed: _localCharmsDown,
                      onTap: () =>
                          _onArtifactCornerTap(AccoutrementKind.counterCharm),
                    ),
                  ),
                  Positioned(
                    top: 0,
                    right: 0,
                    child: _ArtifactCornerTile(
                      corner: _TileCorner.topRight,
                      icon: _kRodOfWindDisplay.$1,
                      color: _kRodOfWindDisplay.$2,
                      label: _kRodOfWindDisplay.$3,
                      count: local?.rodOfSpreadingCount ?? 0,
                      active: _artifactRound.local ==
                          AccoutrementKind.rodOfSpreading,
                      onTap: () =>
                          _onArtifactCornerTap(AccoutrementKind.rodOfSpreading),
                      onLongPress: () => _onArtifactCornerLongPress(
                        AccoutrementKind.rodOfSpreading,
                      ),
                    ),
                  ),
                  Positioned(
                    bottom: 0,
                    right: 0,
                    child: _ArtifactCornerTile(
                      corner: _TileCorner.bottomRight,
                      icon: _kManaGemDisplay.$1,
                      color: _kManaGemDisplay.$2,
                      label: _kManaGemDisplay.$3,
                      count: _accoutrementCount(local, AccoutrementKind.manaGem),
                      active: _artifactRound.local == AccoutrementKind.manaGem,
                      onTap: () =>
                          _onArtifactCornerTap(AccoutrementKind.manaGem),
                      onLongPress: () =>
                          _onArtifactCornerLongPress(AccoutrementKind.manaGem),
                    ),
                  ),
                  Positioned(
                    bottom: 0,
                    left: 0,
                    child: _ArtifactCornerTile(
                      corner: _TileCorner.bottomLeft,
                      icon: _kBookmarkDisplay.$1,
                      color: _kBookmarkDisplay.$2,
                      label: _kBookmarkDisplay.$3,
                      count: _accoutrementCount(local, AccoutrementKind.bookmark),
                      active: _artifactRound.local == AccoutrementKind.bookmark,
                      onTap: () =>
                          _onArtifactCornerTap(AccoutrementKind.bookmark),
                      onLongPress: () =>
                          _onArtifactCornerLongPress(AccoutrementKind.bookmark),
                    ),
                  ),
                ],
              ),
            ),
  
            // Cast-time enhancement picker — only when the selected spell
            // achieved supreme dominance in at least one zone.
            //
            // HIDDEN under somatic components (SPELL_COMPONENTS_PLAN.md §4.2):
            // the gesture performed during the hold is what selects the
            // enhancement there, and leaving a tap path alongside it would mean
            // two sources of truth for one choice — with the tap winning
            // whenever the player forgot to release last.
            if (_phase == _InputPhase.action &&
                !_somaticOn &&
                _selectedSpell != null &&
                _selectedSpell!.supremeTags.isNotEmpty)
              _EnhancementPicker(
                availableTags: _selectedSpell!.supremeTags.toSet(),
                selected: _selectedEnhancement,
                mysteryDelay: _mysteryDelay,
                onSelect: (zone) => setState(() {
                  _selectedEnhancement = _selectedEnhancement == zone
                      ? null
                      : zone;
                  if (_selectedEnhancement != 'earth') _mysteryDelay = 0;
                }),
                onDelayChanged: (d) => setState(() => _mysteryDelay = d),
              ),
  
            // …and what stands in its place under somatic. The picker was the
            // only thing telling a player which enhancements a spell had
            // actually certified; hiding it without this would leave them
            // guessing which gesture is even worth attempting.
            if (_phase == _InputPhase.action &&
                _somaticOn &&
                _selectedSpell != null &&
                _selectedSpell!.supremeTags.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                child: Text(
                  'Gesture to enhance: '
                  '${_selectedSpell!.supremeTags.map((z) => kEnhancementLabel[z] ?? z).join(' · ')}',
                  textAlign: TextAlign.center,
                  style: manuscriptCaptionStyle(color: kIlluminationGold),
                ),
              ),
  
            // Phase-0 read-out is corner-tile-only now (2026-07-31): "mine" is
            // the outlined tile, "charms down" is the dimmed counter-charm
            // tile, and the opponent's declaration is a one-shot toast fired
            // from _beginArtifactPhaseForTurn the moment it's revealed, rather
            // than a banner that lingers for the rest of the turn.
  
            // Components: whose turn it is to perform, and what to do while the
            // hold is open. One banner rather than two — vocal and somatic share
            // the window, so a player performing both wants one instruction.
            if (_componentBannerText != null)
              Container(
                width: double.infinity,
                color: _isPerformingComponents
                    ? const Color(0xFF6B1F1F)
                    : kInkColor,
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  _componentBannerText!,
                  textAlign: TextAlign.center,
                  style: manuscriptHeaderStyle(
                    fontSize: 16,
                    color: kParchmentColor,
                  ),
                ),
              ),
  
            // Action bar
            _ActionBar(
              phase: _phase,
              selectedSpell: _selectedSpell,
              // Priced under the enhancement actually chosen, which can differ
              // from the hand strip's best-case figure (Water/Efficiency is −1/3;
              // everything else is full price).
              selectedSpellCost: _selectedSpell != null
                  ? _spellCost(
                      _selectedSpell!,
                      enhancementZone: _selectedEnhancement,
                    )
                  : null,
              // Under somatic the enhancement is not known until release, so the
              // exact figure above is only the no-enhancement price. This is the
              // cheapest it could turn out to be, and the button shows the pair
              // as a range. Affordability still gates on the DEARER of the two
              // (see _ActionBar): offering a cast the caster might not be able
              // to pay for would make the PEER forfeit, not merely inconvenience
              // this device.
              selectedSpellCostFloor: _somaticOn && _selectedSpell != null
                  ? _bestCaseSpellCost(_selectedSpell!)
                  : null,
              availableMana: _local?.mana,
              hasTarget: _targetHex != null,
              movePathLength: _movePath.length,
              isBusy: _isBusy || _isPerformingComponents || !_componentSlotOpen,
              pickingMelee: _pickingMelee,
              pickingFreeMove: _pickingFreeMove,
              freeMoveGrant: _freeMoveGrant,
              freeMovePathLength: _freeMovePath.isEmpty
                  ? 0
                  : _freeMovePrediction.path.length - 1,
              freeMoveCost: _freeMoveCost,
              onDash: _onDash,
              onMeditateMain: _onMeditateMain,
              onCast: _onCast,
              componentsEnabled: _componentsOn,
              onCastHoldStart: _onCastHoldStart,
              onCastHoldEnd: _onCastHoldEnd,
              onCastHoldCancel: _onCastHoldCancel,
              onCancel: () => setState(() {
                _selectedSpell = null;
                _targetHex = null;
                _selectedEnhancement = null;
                _mysteryDelay = 0;
              }),
              onMeditateMove: _onMeditateMove,
              onConfirmMove: _onConfirmMove,
              onCancelMove: () => setState(() => _movePath = const []),
              onCancelDirectionPick: () => _conveyorPickCompleter?.complete(null),
              onDeclineMelee: () => _meleePickCompleter?.complete(null),
              onDeclineFreeMove: () => _freeMovePickCompleter?.complete(null),
              onConfirmFreeMove: () =>
                  _freeMovePickCompleter?.complete(_freeMovePath),
            ),
  
            // Incantation thumbnail tray — neutral space outside the grid for
            // spells resolved this turn; long-tap re-opens the full card.
            if (_incantationTray.isNotEmpty || _revealReservesTray)
              _IncantationTray(
                key: _incantationTrayKey,
                thumbnails: _incantationTray,
              ),
  
            // Player HP / MP bars. During a Boost prompt the bar also shows,
            // in a paler shade behind the real level, where the run tapped so
            // far would leave the wizard — the decision is "how much of this bar
            // am I willing to burn", so it has to be visible while deciding.
            if (local != null)
              _PlayerHud(
                avatar: local,
                // Same presentation-only adjustment as the opponent chips
                // above: the bar is scaled to the pool this wizard started
                // with, armor included.
                maxHp: config.playerHp + (local.armor?.armorHpBonus ?? 0),
                pendingManaSpend: _freeMoveGrant.boostResource == SpellAffinity.water
                    ? _freeMoveCost
                    : 0,
                pendingHpSpend: _freeMoveGrant.boostResource == SpellAffinity.fire
                    ? _freeMoveCost
                    : 0,
                onOpenGraveyard: () => _showGraveyard(widget.localPlayerId),
              ),

            // Status effects — local player by default; opponent when inspecting
            _StatusEffectPanel(
              avatar: _inspectedAvatar ?? local,
              isLocal: _inspectedAvatar == null,
            ),
  
            // Spell hand (SPELL_DRAW_WIRING_PLAN.md §5) — the live hand, not
            // the whole chapter; deck count is the small HUD readout the plan
            // calls out as a nice-to-have.
            _SpellBook(
              spells: _handSpells,
              selectedIndex: _selectedHandIndex,
              onSelect: _selectSpell,
              onView: (spell) => showSpellCardFullscreen(context, spell),
              isWithered: (index, _) => _loop.isHandSlotWithered(index),
              // Best-case price per card: what the enhancement picker could get
              // it down to. Shown on every card so the player can budget, and
              // reddened + tap-refused on the ones they can't pay for.
              costOf: (_, spell) => _bestCaseSpellCost(spell),
              isUnaffordable: (_, spell) => _isUnaffordable(spell),
              deckCount: _loop.localSpellDraw?.remaining.length,
            ),
          ],
        ),
      ),
    );

    final summary = _matchEndSummary;
    final body = summary == null
        ? scaffold
        : Stack(
            children: [
              scaffold,
              _MatchEndOverlay(
                summary: summary,
                onLeave: () => Navigator.of(context).pop(),
              ),
            ],
          );

    // The same guard the close button gets, for the system back gesture —
    // which on Android is the *easier* of the two to trigger by accident
    // mid-duel. `canPop: false` intercepts; the callback re-asks and pops for
    // real only on confirmation. Lifted once the match ends, so the result
    // screen still leaves with one gesture.
    return PopScope(
      canPop: !leavingNeedsConfirmation(
        isRealDuel: _isRealDuel,
        matchEnded: _matchEnded,
      ),
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_confirmLeaveBattle());
      },
      child: body,
    );
  }
}

/// The card a live creature should wear, and whether to render it phantasmal.
///
/// A creature summoned by a cast has its own recorded [SpellAsset]. A creature
/// conjured as a *copy* of another (Reflections' summonMirror, Illusions'
/// clone) has no cast of its own, so it borrows the original's card — drawn
/// under [kPhantasmalFilter] so it never passes for the genuine article.
/// [Minion.copiedFromMinionId] always points at the original, so a copy of a
/// copy resolves in one hop, and the original's entry is never pruned, so a
/// copy that outlives what it copied keeps its art.
///
/// Null → no card: this client saw no cast for the creature or its original
/// (a Morphic reform, which is a genuinely different creature derived from
/// half the element sequence, deliberately falls here rather than borrowing a
/// card whose stats it no longer matches).
/// Wraps [child] in the cold-blue copy treatment when [on]; a pass-through
/// otherwise. See [kPhantasmalFilter].
Widget _phantasmal(bool on, Widget child) =>
    on ? ColorFiltered(colorFilter: kPhantasmalFilter, child: child) : child;

({SpellAsset spell, bool phantasmal})? _cardForMinion(
  Minion m,
  Map<String, SpellAsset> spellByMinionId,
) {
  if (spellByMinionId[m.id] case final own?) {
    return (spell: own, phantasmal: false);
  }
  final sourceId = m.copiedFromMinionId;
  if (sourceId == null) return null;
  if (spellByMinionId[sourceId] case final source?) {
    return (spell: source, phantasmal: true);
  }
  return null;
}

/// Renders each live summon's card art as a thumbnail on its battlefield tile,
/// in place of the plain affinity-letter token painted underneath by
/// [BattlefieldPainter]. Purely decorative — sits under an [IgnorePointer] so
/// the existing long-press hit-testing (`_onLongPressBattlefield`, which
/// already opens the full card via [showSpellCardFullscreen]) is unaffected.
///
/// Only minions [_cardForMinion] resolves a card for get a thumbnail;
/// everything else falls back to the painter's plain token.
///
/// Sized to [kHexInscribedSquare], the largest square the tile can hold: the
/// art is how a player tells one creature from another at a glance, and at the
/// old 0.62 it was a stamp rather than a portrait. Adjacent tiles still clear
/// each other, so a full board doesn't turn into overlapping cards.
///
/// Follows [moveAnimations] while the Summons phase plays back, so the
/// thumbnail rides its token instead of sitting at the destination watching the
/// token walk out from under it.
class _MinionArtOverlay extends StatelessWidget {
  const _MinionArtOverlay({
    required this.minions,
    required this.spellByMinionId,
    required this.localTeamId,
    required this.center,
    required this.hexSize,
    this.moveAnimations = const [],
    this.moveAnimation,
  });

  final List<Minion> minions;
  final Map<String, SpellAsset> spellByMinionId;
  final String? localTeamId;
  final Offset center;
  final double hexSize;
  final List<MinionMoveAnimation> moveAnimations;
  final Animation<double>? moveAnimation;

  @override
  Widget build(BuildContext context) {
    final controller = moveAnimation;
    if (moveAnimations.isEmpty || controller == null) return _board(1.0);
    // Rebuilds this subtree per frame of the walk. The painter underneath
    // repaints off the same controller via its repaint listenable, so token
    // and thumbnail step together.
    return AnimatedBuilder(
      animation: controller,
      builder: (_, _) => _board(controller.value),
    );
  }

  Widget _board(double t) {
    final size = hexSize * kHexInscribedSquare;
    final walking = {for (final a in moveAnimations) a.minionId: a};
    return Stack(
      clipBehavior: Clip.none,
      children: [
        for (final m in minions)
          if (_cardForMinion(m, spellByMinionId) case final card?)
            () {
              final pos = BattlefieldPainter.minionTokenPos(
                walking[m.id],
                m.position,
                t,
                center,
                hexSize,
              );
              return Positioned(
                left: pos.dx - size / 2,
                top: pos.dy - size / 2,
                width: size,
                height: size,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: m.teamId == localTeamId
                          ? kIlluminationGold
                          : kRubricRed,
                      width: 1.5,
                    ),
                    borderRadius: BorderRadius.circular(size * 0.16),
                    boxShadow: const [
                      BoxShadow(color: Colors.black45, blurRadius: 2),
                    ],
                  ),
                  // The tint stops at the art: the gold/red border stays true
                  // so a phantasmal creature's side is still readable at a
                  // glance.
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(size * 0.12),
                    child: _phantasmal(
                      card.phantasmal,
                      SpellCardWidget(
                        spell: card.spell,
                        size: size,
                        interactive: false,
                      ),
                    ),
                  ),
                ),
              );
            }(),
      ],
    );
  }
}

/// The banner shown when a wild-magic effect fires (docs/WILD_MAGIC_PLAN.md
/// §7.6 item 4).
///
/// Wild magic is untelegraphed by design — neither player sees it coming, and
/// nothing on the board explains why it happened. So this reveal is the ONLY
/// place either of them learns it fired at all, which makes it load-bearing
/// rather than decoration: a global effect the player cannot see happen is a
/// bug. It deliberately names the effect and states the consequence in the
/// symmetric voice ("all players"), because the first thing a player needs to
/// understand is that it hit them too.
class _WildMagicBanner extends StatelessWidget {
  const _WildMagicBanner({required this.event, required this.casterLabel});

  final WildMagicEvent event;
  final String casterLabel;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xCC1A1008),
      alignment: Alignment.center,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'WILD MAGIC',
              style: manuscriptCaptionStyle(color: kIlluminationGold),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 10),
            Text(
              event.label.toUpperCase(),
              style: manuscriptHeaderStyle(
                fontSize: 28,
                color: kParchmentColor,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            Text(
              event.description,
              style: const TextStyle(
                fontFamily: 'serif',
                fontSize: 15,
                height: 1.4,
                color: kParchmentColor,
              ),
              textAlign: TextAlign.center,
            ),
            if (event.bracketSteps > 0) ...[
              const SizedBox(height: 8),
              Text(
                'Amplified ×${event.bracketSteps + 1}',
                style: manuscriptCaptionStyle(color: kIlluminationGold),
              ),
            ],
            const SizedBox(height: 14),
            Text(
              'Loosed by $casterLabel — and it spares no one.',
              style: manuscriptCaptionStyle(
                color: kParchmentColor.withValues(alpha: 0.7),
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

/// What to show once TurnLoop.runTurn reports the match is over — see
/// _BattleScreenState._handleMatchEnd. Populated asynchronously (a real duel
/// signs and exchanges a MatchOutcome before this exists); [_matchEnded]
/// alone is what blocks further input in the meantime.
class _MatchEndSummary {
  const _MatchEndSummary({
    required this.isDraw,
    required this.isLocalVictor,
    this.settled = false,
    this.settlementError,
  });

  final bool isDraw;

  /// Meaningless when [isDraw] is true.
  final bool isLocalVictor;

  /// True iff a [MatchOutcomeRecord] was built, mutually validated, and
  /// saved — i.e. this result is provable to a third party (a graduation
  /// battle's settlement, MASTER_APPRENTICE_PLAN.md §7.4). Always false for
  /// solo/practice (nothing to settle with) and for a draw (no victor/loser
  /// pair to sign over).
  final bool settled;

  /// Set iff a real duel's signed-outcome exchange ran but failed to
  /// validate (peer disagreed, bad signature, or the exchange itself
  /// errored/disconnected). The local win/loss/draw result shown to the
  /// player is still whatever this device's own TurnLoop computed —
  /// unsettled just means nobody else can yet prove it.
  final String? settlementError;
}

/// Full-screen scrim shown once [_MatchEndSummary] exists — blocks
/// interaction with the battlefield beneath it (in addition to
/// [_BattleScreenState._matchEnded] already refusing new turns) and reports
/// the result, including whether it was mutually signed
/// (docs/MASTER_APPRENTICE_PLAN.md §4).
class _MatchEndOverlay extends StatelessWidget {
  const _MatchEndOverlay({required this.summary, required this.onLeave});

  final _MatchEndSummary summary;
  final VoidCallback onLeave;

  @override
  Widget build(BuildContext context) {
    final String title;
    final Color titleColor;
    if (summary.isDraw) {
      title = 'DRAW';
      titleColor = kParchmentColor;
    } else if (summary.isLocalVictor) {
      title = 'VICTORY';
      titleColor = kIlluminationGold;
    } else {
      title = 'DEFEAT';
      titleColor = kRubricRed;
    }

    String? subtitle;
    if (!summary.isDraw) {
      if (summary.settled) {
        subtitle = 'Recorded — both wizards signed this outcome.';
      } else if (summary.settlementError != null) {
        subtitle = 'Not settled: ${summary.settlementError}';
      }
    }

    return Container(
      color: const Color(0xCC1A1008),
      alignment: Alignment.center,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              title,
              style: manuscriptHeaderStyle(fontSize: 32, color: titleColor),
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 12),
              Text(
                subtitle,
                textAlign: TextAlign.center,
                style: manuscriptBodyStyle(
                  fontSize: 13,
                  color: kParchmentColor.withValues(alpha: 0.8),
                ),
              ),
            ],
            const SizedBox(height: 28),
            OutlinedButton(
              onPressed: onLeave,
              style: OutlinedButton.styleFrom(foregroundColor: kParchmentColor),
              child: const Text('Leave Battle'),
            ),
          ],
        ),
      ),
    );
  }
}

/// An incantation resolved this turn, parked in the neutral tray outside the
/// grid once its 2s full-card reveal finishes — see
/// _BattleScreenState._playResolvedSpellSequence.
class _ResolvedThumbnail {
  const _ResolvedThumbnail({required this.spell, required this.casterId});

  final SpellAsset spell;
  final String casterId;
}

/// A local Mystery cast's hidden target/delay/nonce, tracked client-side
/// until its fireTurn arrives — see _BattleScreenState._submitTurn.
class _PendingMysterySecret {
  const _PendingMysterySecret({
    required this.id,
    required this.target,
    required this.delay,
    required this.nonce,
    required this.fireTurn,
  });

  /// Matches PendingDelayedSpell.id once the engine creates it.
  final String id;
  final HexCoord target;
  final int delay;
  final Uint8List nonce;

  /// Absolute turn number this must be revealed on.
  final int fireTurn;
}

// ── Action bar ────────────────────────────────────────────────────────────────

class _ActionBar extends StatelessWidget {
  const _ActionBar({
    required this.phase,
    required this.selectedSpell,
    required this.selectedSpellCost,
    required this.availableMana,
    required this.hasTarget,
    required this.movePathLength,
    required this.isBusy,
    required this.pickingMelee,
    required this.pickingFreeMove,
    required this.freeMoveGrant,
    required this.freeMovePathLength,
    required this.freeMoveCost,
    required this.onDash,
    required this.onMeditateMain,
    required this.onCast,
    this.componentsEnabled = false,
    this.selectedSpellCostFloor,
    this.onCastHoldStart,
    this.onCastHoldEnd,
    this.onCastHoldCancel,
    required this.onCancel,
    required this.onMeditateMove,
    required this.onConfirmMove,
    required this.onCancelMove,
    required this.onCancelDirectionPick,
    required this.onDeclineMelee,
    required this.onDeclineFreeMove,
    required this.onConfirmFreeMove,
  });

  final _InputPhase phase;
  final SpellAsset? selectedSpell;

  /// Mana [selectedSpell] costs under the currently-chosen enhancement, or
  /// null when nothing is selected / there's no local avatar to price against.
  final int? selectedSpellCost;

  /// The local caster's mana. With [selectedSpellCost] this decides whether
  /// CAST is live: an unaffordable cast is not a local inconvenience, it makes
  /// the *peer* forfeit the match (TurnLoop._verifyPeerSpellCast,
  /// it fizzles and wastes the turn), so the button must not offer it.
  final int? availableMana;

  final bool hasTarget;
  final int movePathLength;
  final bool isBusy;

  /// Resolution-phase melee prompt (see _BattleScreenState._pickMeleeTarget)
  /// overrides whatever [phase] happens to be — the turn is already mid
  /// -submission by the time this fires.
  final bool pickingMelee;

  /// Post-resolution free-move prompt (see
  /// _BattleScreenState._pickFreeMoveDirection) — same override as
  /// [pickingMelee]; the two are never true at once (different phases).
  final bool pickingFreeMove;

  /// What that prompt is offering — a burst step, a Boost run, or both.
  /// [FreeMoveGrant.none] whenever [pickingFreeMove] is false.
  final FreeMoveGrant freeMoveGrant;

  /// Tiles in the run tapped so far, counting conveyor push-throughs.
  final int freeMovePathLength;

  /// What that run costs in [FreeMoveGrant.boostResource]'s units — 0 while
  /// still inside the free tiles, or whenever there's no Boost to pay for.
  final int freeMoveCost;

  final VoidCallback onDash;
  final VoidCallback onMeditateMain;
  final VoidCallback onCast;

  /// With either spell component in play, CAST becomes a press-and-hold that
  /// doubles as the capture window for both (VOCAL_RECALL_PLAN.md §9.4,
  /// SPELL_COMPONENTS_PLAN.md §2).
  final bool componentsEnabled;

  /// Cheapest [selectedSpell] could end up costing, when the enhancement is
  /// not yet decided (somatic components — the gesture resolves at release).
  /// Null whenever the price is exact, which is every other case.
  ///
  /// [selectedSpellCost] is the DEARER end when this is set, and is what
  /// affordability gates on. Quoting the cheap end and letting the player
  /// commit would put the cost of being wrong on the peer: an unaffordable
  /// cast forfeits THEIR match, not ours.
  final int? selectedSpellCostFloor;
  final VoidCallback? onCastHoldStart;
  final VoidCallback? onCastHoldEnd;
  final VoidCallback? onCastHoldCancel;
  final VoidCallback onCancel;
  final VoidCallback onMeditateMove;
  final VoidCallback onConfirmMove;
  final VoidCallback onCancelMove;
  final VoidCallback onCancelDirectionPick;
  final VoidCallback onDeclineMelee;
  final VoidCallback onDeclineFreeMove;
  final VoidCallback onConfirmFreeMove;

  /// Prompt copy for the free-move window, named for whatever earned it.
  /// A Boost leads with its price because that's the decision being made;
  /// a bare burst step is free and just needs a direction.
  String get _freeMovePrompt {
    final resource = freeMoveGrant.boostResource;
    if (resource == null) {
      return 'Your airy barrier bursts — step free? '
          'Tap a highlighted tile, or stand fast';
    }
    final unit = resource == SpellAffinity.water ? 'mana' : 'life';
    final name = resource == SpellAffinity.water
        ? 'High Liquidity'
        : 'High Mobility';
    if (freeMovePathLength == 0) {
      return freeMoveGrant.burstStep
          ? '$name, and your airy barrier bursts — tap tiles to run '
                '(first step free)'
          : '$name — tap tiles to run, then MOVE';
    }
    final steps = '$freeMovePathLength step${freeMovePathLength == 1 ? '' : 's'}';
    return freeMoveCost == 0
        ? '$steps, free — tap the last to undo'
        : '$steps for $freeMoveCost $unit — tap the last to undo';
  }

  @override
  Widget build(BuildContext context) {
    if (pickingFreeMove) {
      return Container(
        color: const Color(0xFF0F0804),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            _ActionButton(
              label: 'STAND',
              color: kInkMutedColor,
              enabled: true,
              onTap: onDeclineFreeMove,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _freeMovePrompt,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: 'serif',
                  fontSize: 13,
                  color: kParchmentColor.withValues(alpha: 0.90),
                ),
              ),
            ),
            // A bare burst step commits on tap (one tile, nothing to weigh).
            // A Boost run is built up and locked in here instead, because the
            // player is choosing how much to spend, not just which way to go.
            if (freeMoveGrant.boostResource != null) ...[
              const SizedBox(width: 8),
              _ActionButton(
                label: 'MOVE',
                color: const Color(0xFF3A7FCC),
                enabled: freeMovePathLength > 0,
                onTap: onConfirmFreeMove,
              ),
            ],
          ],
        ),
      );
    }

    if (pickingMelee) {
      return Container(
        color: const Color(0xFF0F0804),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            _ActionButton(
              label: 'PASS',
              color: kInkMutedColor,
              enabled: true,
              onTap: onDeclineMelee,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Make a melee attack? Tap a highlighted foe, or pass',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: 'serif',
                  fontSize: 13,
                  color: kParchmentColor.withValues(alpha: 0.90),
                ),
              ),
            ),
          ],
        ),
      );
    }

    if (phase == _InputPhase.pickingDirection) {
      return Container(
        color: const Color(0xFF0F0804),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            _ActionButton(
              label: 'CANCEL',
              color: kInkMutedColor,
              enabled: true,
              onTap: onCancelDirectionPick,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Choose the direction the wind will push — tap a highlighted tile',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: 'serif',
                  fontSize: 13,
                  color: kParchmentColor.withValues(alpha: 0.90),
                ),
              ),
            ),
          ],
        ),
      );
    }

    if (phase == _InputPhase.movement) {
      return Container(
        color: const Color(0xFF0F0804),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            _ActionButton(
              label: 'MEDITATE',
              color: const Color(0xFF2090E0),
              enabled: !isBusy,
              onTap: onMeditateMove,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                movePathLength > 0
                    ? '$movePathLength step${movePathLength == 1 ? '' : 's'}'
                          ' — tap last to undo'
                    : 'Tap an adjacent tile to step, or stand fast',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: 'serif',
                  fontSize: 13,
                  color: movePathLength > 0
                      ? kParchmentColor.withValues(alpha: 0.90)
                      : kInkMutedColor,
                  fontStyle: movePathLength > 0
                      ? FontStyle.normal
                      : FontStyle.italic,
                ),
              ),
            ),
            const SizedBox(width: 8),
            _ActionButton(
              label: 'MOVE',
              color: const Color(0xFF3A7FCC),
              // Always available -- an empty path submits as a free stay
              // (as opposed to MEDITATE, which stays put for +25 mana).
              enabled: !isBusy,
              onTap: onConfirmMove,
            ),
          ],
        ),
      );
    }

    // Action phase
    final selecting = selectedSpell != null;
    final cost = selectedSpellCost;
    final mana = availableMana;
    // Unknown price (no avatar yet) never blocks — fail open here, because the
    // engine's own checks still stand behind it and a wrongly-dead CAST button
    // is unrecoverable for the player.
    final affordable = cost == null || mana == null || cost <= mana;
    return Container(
      color: const Color(0xFF0F0804),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          if (!selecting) ...[
            _ActionButton(
              label: 'MEDITATE',
              color: const Color(0xFF2090E0),
              enabled: !isBusy,
              onTap: onMeditateMain,
            ),
            const SizedBox(width: 6),
            _ActionButton(
              label: 'DASH',
              color: const Color(0xFFD8C840),
              enabled: !isBusy,
              onTap: onDash,
            ),
          ] else
            _ActionButton(
              label: 'CANCEL',
              color: kInkMutedColor,
              enabled: !isBusy,
              onTap: onCancel,
            ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  selecting
                      ? (!affordable
                            ? 'Not enough mana — $cost needed, $mana left'
                            : (hasTarget
                                  ? selectedSpell!.name
                                  : 'Tap a tile to target'))
                      : 'Choose a spell, Dash, or Meditate',
                  textAlign: TextAlign.center,
                  // Capped because this prompt sits in the only flexible slot
                  // of a Row it shares with fixed-width action buttons. On a
                  // narrow phone that slot gets thin, and an uncapped prompt
                  // wrapped far enough to grow the whole action bar past the
                  // battlefield's share of the screen — pushing the spell hand
                  // out of view. Two lines is enough for every string above.
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: 'serif',
                    fontSize: 13,
                    color: !affordable
                        ? const Color(0xFFE05A4A)
                        : (selecting
                              ? kParchmentColor.withValues(alpha: 0.90)
                              : kInkMutedColor),
                    fontStyle: selecting && !hasTarget
                        ? FontStyle.italic
                        : FontStyle.normal,
                  ),
                ),
                if (selecting) ...[
                  const SizedBox(height: 2),
                  Text(
                    selectedSpell!.isSummon
                        ? (summonSummaryFromFormula(selectedSpell!.formula) ??
                              'Void Summon')
                        : formulaEffectLabels(
                            selectedSpell!.formula,
                          ).join('  ·  '),
                    textAlign: TextAlign.center,
                    // Same reasoning as the prompt above, and this one is
                    // formula-derived, so its length is not even bounded by a
                    // fixed set of strings.
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: 'serif',
                      fontSize: 10,
                      letterSpacing: 0.5,
                      color: kIlluminationGold.withValues(alpha: 0.70),
                    ),
                  ),
                  // Live price under the chosen enhancement — this is the
                  // number that has to clear `mana`, and it moves when the
                  // player picks Water/Efficiency, so keep it visible next to
                  // the picker rather than only on the hand card.
                  if (cost != null) ...[
                    const SizedBox(height: 1),
                    Text(
                      // A range while the enhancement is still unresolved —
                      // see [selectedSpellCostFloor]. Collapses to a single
                      // figure when the gesture cannot change the price
                      // (no Water/Efficiency tag on this spell).
                      selectedSpellCostFloor != null &&
                              selectedSpellCostFloor != cost
                          ? '$selectedSpellCostFloor–$cost mana'
                          : '$cost mana',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontFamily: 'serif',
                        fontSize: 10,
                        letterSpacing: 0.5,
                        color: affordable
                            ? const Color(0xFF6FC3FF)
                            : const Color(0xFFE05A4A),
                      ),
                    ),
                  ],
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          // With components on, casting is PRESS AND HOLD: the window opens on
          // press, the caster chants OPENER + the trajectory and gesticulates
          // through it, and release both ends the capture and commits the
          // cast. Same control enrollment uses —
          // hold_to_record_control.dart's header requires exactly one
          // capture-window mechanism, because enrollment and live capture must
          // segment identically or every DTW distance is skewed.
          if (componentsEnabled)
            HoldToRecordButton(
              label: 'CAST',
              enabled: selecting && hasTarget && !isBusy && affordable,
              onHoldStart: onCastHoldStart ?? () {},
              onHoldEnd: onCastHoldEnd ?? () {},
              onHoldCancel: onCastHoldCancel,
            )
          else
            _ActionButton(
              label: 'CAST',
              color: kIlluminationGold,
              enabled: selecting && hasTarget && !isBusy && affordable,
              onTap: onCast,
            ),
        ],
      ),
    );
  }
}

// ── Phase banner ─────────────────────────────────────────────────────────────

/// A thin, always-visible banner naming the current turn phase (Summons /
/// Main / Move / Resolution) — see _BattleScreenState._phaseLabel.
/// DEV FLAG (lib/dev_flags.dart) — shown for the whole match whenever
/// [kAllowProoflessSpells] is on and this is a real duel. Delete with the flag.
///
/// Deliberately loud and deliberately not dismissible: with the flag on, an
/// opponent can cast a spell backed by nothing at all, so no result from this
/// match means anything. It also gives the second device a way to tell at a
/// glance whether it was built with the same flag — if only one banner shows,
/// the strict device will forfeit the first time a test spell is cast.
class _UnverifiedPlayBanner extends StatelessWidget {
  const _UnverifiedPlayBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: const Color(0xFF7A1F1F),
      padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 8),
      child: const Text(
        '⚠ UNVERIFIED PLAY — PROOFLESS SPELLS ACCEPTED',
        textAlign: TextAlign.center,
        style: TextStyle(
          fontFamily: 'serif',
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.5,
          color: Color(0xFFF2E4C9),
        ),
      ),
    );
  }
}

/// Shown when this device has been waiting on a peer frame for longer than the
/// session's stall threshold (see [BattleSession.stalledExchange]).
///
/// Deliberately not a blocking error: the duel is still live, the socket is
/// still open, and the exchange completes the moment the peer's frame lands.
/// The point is only that a frozen board should say what it is waiting for
/// instead of looking like a crashed app — the exchange name is what turns a
/// "it just froze" bug report into a diagnosable one.
class _StalledExchangeBanner extends StatelessWidget {
  const _StalledExchangeBanner({required this.exchange});

  final String exchange;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: const Color(0xFF4A3410),
      padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 12),
      child: Text(
        'WAITING FOR OPPONENT — $exchange',
        textAlign: TextAlign.center,
        style: const TextStyle(
          fontFamily: 'serif',
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.2,
          color: Color(0xFFE8C87A),
        ),
      ),
    );
  }
}

class _PhaseBanner extends StatelessWidget {
  const _PhaseBanner({required this.label});

  final String label;

  static const Map<String, Color> _kPhaseColor = {
    'Summons': Color(0xFF8B6228),
    'Main': Color(0xFFB8860B),
    'Move': Color(0xFF3A7FCC),
    'Resolution': Color(0xFF7A1F1F),
  };

  @override
  Widget build(BuildContext context) {
    final color = _kPhaseColor[label] ?? kIlluminationGold;
    return Container(
      width: double.infinity,
      color: kInkColor,
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Text(
        label.toUpperCase(),
        textAlign: TextAlign.center,
        style: TextStyle(
          fontFamily: 'serif',
          fontSize: 12,
          fontWeight: FontWeight.w700,
          letterSpacing: 2,
          color: color,
        ),
      ),
    );
  }
}

// ── Incantation thumbnail tray ────────────────────────────────────────────────

/// Neutral-space thumbnails for incantations resolved this turn — see
/// _BattleScreenState._playResolvedSpellSequence. Long-tap re-opens the card;
/// cleared at the start of the next turn's reveal sequence.
class _IncantationTray extends StatelessWidget {
  const _IncantationTray({super.key, required this.thumbnails});

  final List<_ResolvedThumbnail> thumbnails;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF120C06),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      height: 60,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: thumbnails.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final t = thumbnails[i];
          return GestureDetector(
            onLongPress: () => showSpellCardFullscreen(context, t.spell),
            child: SpellCardWidget(
              spell: t.spell,
              size: 48,
              interactive: false,
            ),
          );
        },
      ),
    );
  }
}

// ── Somatic cast outcome ─────────────────────────────────────────────────────

/// Why the last hold resolved to the enhancement it did.
///
/// Every value except [applied] resolves to [Gesture.neutral]. They are kept
/// distinct only so the player is told which of several very different
/// problems they have — "move more", "that isn't a gesture I know", and "this
/// spell can't take that enhancement" call for three different corrections,
/// and a single "no enhancement" message teaches none of them.
enum _SomaticVerdict {
  /// No capture ran (component off, sensor unavailable, or hold cancelled).
  notCaptured,

  /// Free-style motion gate failed — the caster was mostly still (§4.1).
  tooStill,

  /// No enrolled reps to match against. The player never attuned.
  notEnrolled,

  /// Motion happened but matched no gesture confidently (§6.3).
  unrecognized,

  /// A gesture was recognized, but this spell has not certified that zone.
  ineligible,

  /// Recognized and certified — the enhancement is on.
  applied,
}

class _SomaticOutcome {
  const _SomaticOutcome(this.gesture, this.verdict, {this.attempted});

  /// What the cast will actually use. [Gesture.neutral] unless
  /// [verdict] is [_SomaticVerdict.applied].
  final Gesture gesture;
  final _SomaticVerdict verdict;

  /// For [_SomaticVerdict.ineligible]: what was recognized before the
  /// eligibility downgrade threw it away, so the message can name it.
  final Gesture? attempted;

  /// Player-facing one-liner, or null when there is nothing worth saying.
  String? get message => switch (verdict) {
        _SomaticVerdict.notCaptured => null,
        _SomaticVerdict.applied =>
          '${kEnhancementLabel[gesture.enhancementZone] ?? 'Enhanced'} — '
              'the gesture held.',
        _SomaticVerdict.tooStill =>
          'Your gesticulation faltered — no enhancement.',
        _SomaticVerdict.notEnrolled =>
          'No attuned gestures. Attune them in Practice to cast enhanced.',
        _SomaticVerdict.unrecognized =>
          'The gesture did not read clearly — no enhancement.',
        _SomaticVerdict.ineligible =>
          'This spell has no supreme ${attempted?.name ?? ''} dominance — '
              'no enhancement.',
      };
}

// ── Cast-time enhancement picker ─────────────────────────────────────────────

class _EnhancementPicker extends StatelessWidget {
  const _EnhancementPicker({
    required this.availableTags,
    required this.selected,
    required this.mysteryDelay,
    required this.onSelect,
    required this.onDelayChanged,
  });

  final Set<String> availableTags;
  final String? selected;
  final int mysteryDelay;
  final ValueChanged<String?> onSelect;
  final ValueChanged<int> onDelayChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF0F0804),
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              _EnhancementChip(
                label: 'NONE',
                color: kInkMutedColor,
                selected: selected == null,
                enabled: true,
                onTap: () => onSelect(null),
              ),
              for (final zone in kEnhancementZones) ...[
                const SizedBox(width: 6),
                Expanded(
                  child: _EnhancementChip(
                    label: kEnhancementLabel[zone]!.toUpperCase(),
                    color: kEnhancementColor[zone]!,
                    selected: selected == zone,
                    enabled: availableTags.contains(zone),
                    onTap: () => onSelect(zone),
                  ),
                ),
              ],
            ],
          ),
          if (selected == 'earth') ...[
            const SizedBox(height: 6),
            Row(
              children: [
                Text(
                  'Delay:',
                  style: TextStyle(
                    fontFamily: 'serif',
                    fontSize: 12,
                    color: kParchmentColor.withValues(alpha: 0.8),
                  ),
                ),
                const SizedBox(width: 8),
                for (var d = 0; d <= 3; d++) ...[
                  _DelayChip(
                    value: d,
                    selected: mysteryDelay == d,
                    onTap: () => onDelayChanged(d),
                  ),
                  const SizedBox(width: 4),
                ],
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Target and delay stay hidden until it fires.',
                    style: TextStyle(
                      fontFamily: 'serif',
                      fontSize: 10,
                      fontStyle: FontStyle.italic,
                      color: kInkMutedColor,
                    ),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 6),
        ],
      ),
    );
  }
}

class _EnhancementChip extends StatelessWidget {
  const _EnhancementChip({
    required this.label,
    required this.color,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final String label;
  final Color color;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final fg = enabled ? color : kInkMutedColor.withValues(alpha: 0.35);
    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(4),
      child: Container(
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
        decoration: BoxDecoration(
          color: selected ? fg.withValues(alpha: 0.20) : Colors.transparent,
          border: Border.all(color: fg),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontFamily: 'serif',
            fontSize: 10,
            letterSpacing: 0.6,
            fontWeight: FontWeight.w600,
            color: fg,
          ),
        ),
      ),
    );
  }
}

class _DelayChip extends StatelessWidget {
  const _DelayChip({
    required this.value,
    required this.selected,
    required this.onTap,
  });

  final int value;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final fg = kEnhancementColor['earth']!;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Container(
        width: 22,
        height: 22,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? fg.withValues(alpha: 0.25) : Colors.transparent,
          border: Border.all(color: fg),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          '$value',
          style: TextStyle(
            fontFamily: 'serif',
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: fg,
          ),
        ),
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.label,
    required this.color,
    required this.enabled,
    required this.onTap,
  });

  final String label;
  final Color color;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final fg = enabled ? color : color.withValues(alpha: 0.30);
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          border: Border.all(color: fg, width: 1.5),
          borderRadius: BorderRadius.circular(3),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontFamily: 'serif',
            fontSize: 12,
            letterSpacing: 1.5,
            fontWeight: FontWeight.w600,
            color: fg,
          ),
        ),
      ),
    );
  }
}

// ── Graveyard (cast + withered spells) ──────────────────────────────────────

/// MTG-graveyard-style browser for one player's cast + withered spells —
/// opened via [_BattleScreenState._showGraveyard] from either the local
/// [_PlayerHud] icon or a targeted opponent's [_OpponentChip] icon.
///
/// Reads [TurnLoop.usedChapterPositions]/[TurnLoop.spellAt] and
/// [TurnLoop.drawScheduleFor]'s `withered` set directly — no snapshot is
/// taken. Since nothing else in this codebase re-renders an already-open
/// `showDialog` route when engine state mutates, this widget polls [loop]
/// on a short timer so a reactivation (which must vanish from the withered
/// list instantly per the design) is reflected while the dialog stays open.
class _GraveyardDialog extends StatefulWidget {
  const _GraveyardDialog({
    required this.loop,
    required this.playerId,
    required this.title,
  });

  final TurnLoop loop;
  final String playerId;
  final String title;

  @override
  State<_GraveyardDialog> createState() => _GraveyardDialogState();
}

class _GraveyardDialogState extends State<_GraveyardDialog> {
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    // Wither/reactivate only ever happens at a resolved-turn boundary, not
    // per-frame, so a short poll is cheap and never misses a change.
    _refreshTimer = Timer.periodic(const Duration(milliseconds: 300), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isLocal = widget.playerId == widget.loop.localPlayerId;
    final cast = widget.loop.usedChapterPositions(widget.playerId).toList()
      ..sort();
    final withered =
        (widget.loop.drawScheduleFor(widget.playerId)?.withered ?? const <int>{})
            .toList()
          ..sort();

    return Dialog(
      backgroundColor: kParchmentColor,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420, maxHeight: 420),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      "${widget.title}'s Graveyard",
                      style: manuscriptHeaderStyle(fontSize: 15),
                    ),
                  ),
                  GestureDetector(
                    onTap: () => Navigator.of(context).pop(),
                    child: const Icon(Icons.close, size: 18, color: kInkColor),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              if (cast.isEmpty && withered.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: Center(
                    child: Text(
                      'Nothing here yet',
                      style: manuscriptCaptionStyle(),
                    ),
                  ),
                )
              else ...[
                Flexible(
                  child: _GraveyardSection(
                    label: 'Cast',
                    positions: cast,
                    loop: widget.loop,
                    playerId: widget.playerId,
                    dimmed: false,
                  ),
                ),
                const SizedBox(height: 10),
                Flexible(
                  child: _GraveyardSection(
                    label: 'Withered',
                    positions: withered,
                    loop: widget.loop,
                    playerId: widget.playerId,
                    dimmed: true,
                  ),
                ),
                if (!isLocal && withered.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      'Withered opponent spells are hidden until cast',
                      style: manuscriptCaptionStyle(
                        color: kInkColor.withValues(alpha: 0.55),
                      ),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _GraveyardSection extends StatelessWidget {
  const _GraveyardSection({
    required this.label,
    required this.positions,
    required this.loop,
    required this.playerId,
    required this.dimmed,
  });

  final String label;
  final List<int> positions;
  final TurnLoop loop;
  final String playerId;

  /// Applied to every tile in this section (the _SpellBook withered-dimming
  /// convention, battle_screen.dart's own `_SpellBook` build method) — the
  /// Withered section is always dimmed, matching how a greyed hand card
  /// reads elsewhere in this screen.
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '$label (${positions.length})',
          style: manuscriptCaptionStyle(
            color: kInkColor.withValues(alpha: 0.75),
          ),
        ),
        const SizedBox(height: 4),
        if (positions.isEmpty)
          Text('—', style: manuscriptCaptionStyle())
        else
          SizedBox(
            height: 78,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: positions.length,
              separatorBuilder: (_, _) => const SizedBox(width: 6),
              itemBuilder: (context, i) {
                final spell = loop.spellAt(playerId, positions[i]);
                final tile = spell == null
                    ? const _UnknownSpellTile(size: 64)
                    : GestureDetector(
                        onTap: () => showSpellCardFullscreen(context, spell),
                        child: SpellCardWidget(
                          spell: spell,
                          size: 64,
                          interactive: false,
                        ),
                      );
                return Opacity(opacity: dimmed ? 0.35 : 1.0, child: tile);
              },
            ),
          ),
      ],
    );
  }
}

/// Face-down placeholder for a graveyard entry whose content is unknown —
/// always true of an opponent's withered (never-cast) positions under the
/// ZK privacy model (see TurnLoop.spellAt's doc comment). Sized to match
/// [SpellCardWidget] so its row stays aligned.
class _UnknownSpellTile extends StatelessWidget {
  const _UnknownSpellTile({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: const Color(0xFF130C04),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: kIlluminationGold.withValues(alpha: 0.6),
          width: 1,
        ),
      ),
      child: Icon(
        Icons.help_outline,
        size: size * 0.4,
        color: kIlluminationGold.withValues(alpha: 0.85),
      ),
    );
  }
}

// ── Watery Scrying Pool reveal ──────────────────────────────────────────────

/// Thumbnail row for a Watery Scrying Pool reveal — the enemy's spells for
/// as long as [TurnLoop.revealedEnemyHand] is non-null this turn. Same small
/// non-interactive thumbnail as [_IncantationTray]; tap opens the full card
/// (no long-tap needed here — these aren't yours to cast).
class _RevealedHandRow extends StatelessWidget {
  const _RevealedHandRow({required this.spells});

  final List<SpellAsset> spells;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: kInkColor.withValues(alpha: 0.90),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      height: 48,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: spells.length,
        separatorBuilder: (_, _) => const SizedBox(width: 6),
        itemBuilder: (context, i) {
          final spell = spells[i];
          return GestureDetector(
            onTap: () => showSpellCardFullscreen(context, spell),
            child: SpellCardWidget(spell: spell, size: 36, interactive: false),
          );
        },
      ),
    );
  }
}

// ── Opponent strip ────────────────────────────────────────────────────────────

class _OpponentHudRow extends StatelessWidget {
  const _OpponentHudRow({
    required this.avatars,
    required this.maxHp,
    this.onOpenGraveyard,
  });

  final List<WizardAvatar> avatars;
  final int maxHp;

  /// Opens the graveyard (cast + withered spells) for the given avatar's
  /// playerId — see _BattleScreenState._showGraveyard. Threaded per-chip so
  /// each opponent's icon opens THEIR graveyard, not a fixed one.
  final void Function(String playerId)? onOpenGraveyard;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: kInkColor.withValues(alpha: 0.90),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      child: Row(
        children: [
          for (int i = 0; i < avatars.length; i++) ...[
            if (i > 0) const SizedBox(width: 12),
            Expanded(
              child: _OpponentChip(
                avatar: avatars[i],
                // Presentation only: an Earth armor raises the pool this
                // wizard started with, so the bar's denominator has to follow
                // or an armored opponent reads as pinned at full until they
                // drop below the innate total. There is no max-HP mechanic
                // behind this — healing stays uncapped (engine v6, slice 5).
                maxHp: maxHp + (avatars[i].armor?.armorHpBonus ?? 0),
                onOpenGraveyard: onOpenGraveyard == null
                    ? null
                    : () => onOpenGraveyard!(avatars[i].playerId),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _OpponentChip extends StatelessWidget {
  const _OpponentChip({
    required this.avatar,
    required this.maxHp,
    this.onOpenGraveyard,
  });

  final WizardAvatar avatar;
  final int maxHp;
  final VoidCallback? onOpenGraveyard;

  @override
  Widget build(BuildContext context) {
    final hpFrac = maxHp > 0 ? (avatar.hp / maxHp).clamp(0.0, 1.0) : 0.0;
    final manaFrac = avatar.maxMana > 0
        ? (avatar.mana / avatar.maxMana).clamp(0.0, 1.0)
        : 0.0;
    final name = avatar.wizardName.isNotEmpty
        ? avatar.wizardName
        : (avatar.playerId.length > 10
              ? '${avatar.playerId.substring(0, 9)}…'
              : avatar.playerId);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Flexible(
              child: Text(
                name,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontFamily: 'serif',
                  fontSize: 10,
                  letterSpacing: 0.5,
                  color: kParchmentColor,
                ),
              ),
            ),
            if (onOpenGraveyard != null) ...[
              const SizedBox(width: 4),
              _GraveyardIconButton(onTap: onOpenGraveyard!),
            ],
          ],
        ),
        const SizedBox(height: 3),
        _ThinBar(
          fraction: hpFrac,
          color: const Color(0xFF8B1E1E),
          label: '${avatar.hp}',
        ),
        const SizedBox(height: 2),
        _ThinBar(
          fraction: manaFrac,
          color: const Color(0xFF2B4D8C),
          label: '${avatar.mana}',
        ),
      ],
    );
  }
}

/// Opponent strip's inspected-creature view: same slot as [_OpponentHudRow],
/// shown instead of it while an enemy minion is tapped (see
/// _updateInspection). Minions have no mana, so this is HP-only.
class _EnemyCreatureHudRow extends StatelessWidget {
  const _EnemyCreatureHudRow({required this.minion});

  final Minion minion;

  @override
  Widget build(BuildContext context) {
    final hpFrac = minion.stats.maxHp > 0
        ? (minion.hp / minion.stats.maxHp).clamp(0.0, 1.0)
        : 0.0;
    final affinityName = minion.affinity.name;
    final label =
        '${affinityName[0].toUpperCase()}${affinityName.substring(1)} Creature';

    return Container(
      color: kInkColor.withValues(alpha: 0.90),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
              fontFamily: 'serif',
              fontSize: 10,
              letterSpacing: 0.5,
              color: BattlefieldPainter.colorForAffinity(minion.affinity),
            ),
          ),
          const SizedBox(height: 3),
          _ThinBar(
            fraction: hpFrac,
            color: const Color(0xFF8B1E1E),
            label: '${minion.hp}',
          ),
        ],
      ),
    );
  }
}

class _ThinBar extends StatelessWidget {
  const _ThinBar({
    required this.fraction,
    required this.color,
    required this.label,
  });

  final double fraction;
  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: fraction,
              backgroundColor: const Color(0xFF2A1A0A),
              valueColor: AlwaysStoppedAnimation<Color>(color),
              minHeight: 6,
            ),
          ),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: const TextStyle(
            fontFamily: 'serif',
            fontSize: 9,
            color: kParchmentColor,
          ),
        ),
      ],
    );
  }
}

// ── Player HP / MP bars ───────────────────────────────────────────────────────

class _PlayerHud extends StatelessWidget {
  const _PlayerHud({
    required this.avatar,
    required this.maxHp,
    this.pendingManaSpend = 0,
    this.pendingHpSpend = 0,
    this.onOpenGraveyard,
  });

  final WizardAvatar avatar;
  final int maxHp;

  /// Mana a Boost run being planned right now would cost — previewed on the MP
  /// bar before the player commits (see _BattleScreenState._freeMoveCost).
  final int pendingManaSpend;

  /// Same, for a Fire Boost's life cost, on the HP bar.
  final int pendingHpSpend;

  /// Opens this wizard's graveyard (cast + withered spells) — see
  /// _BattleScreenState._showGraveyard. Null hides the icon entirely.
  final VoidCallback? onOpenGraveyard;

  @override
  Widget build(BuildContext context) {
    final hpFrac = maxHp > 0 ? (avatar.hp / maxHp).clamp(0.0, 1.0) : 0.0;
    final manaFrac = avatar.maxMana > 0
        ? (avatar.mana / avatar.maxMana).clamp(0.0, 1.0)
        : 0.0;
    // A Fire Boost can never take the wizard below 1 HP — TurnLoop's grant
    // caps it there — so the preview stops there too rather than showing an
    // empty bar the engine would never produce.
    final hpAfter = max(1, avatar.hp - pendingHpSpend);
    final manaAfter = max(0, avatar.mana - pendingManaSpend);

    return Container(
      color: kInkColor,
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
      child: Stack(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _StatBar(
                label: 'HP',
                value: avatar.hp,
                max: maxHp,
                fraction: hpFrac,
                barColor: const Color(0xFF8B1E1E),
                labelColor: const Color(0xFFD48A8A),
                previewValue: pendingHpSpend > 0 ? hpAfter : null,
                previewFraction: maxHp > 0
                    ? (hpAfter / maxHp).clamp(0.0, 1.0)
                    : 0.0,
              ),
              const SizedBox(height: 6),
              _StatBar(
                label: 'MP',
                value: avatar.mana,
                max: avatar.maxMana,
                fraction: manaFrac,
                barColor: const Color(0xFF2B4D8C),
                labelColor: const Color(0xFF8AACED),
                previewValue: pendingManaSpend > 0 ? manaAfter : null,
                previewFraction: avatar.maxMana > 0
                    ? (manaAfter / avatar.maxMana).clamp(0.0, 1.0)
                    : 0.0,
              ),
              if (avatar.activeChainElement != null) ...[
                const SizedBox(height: 4),
                _ChainIndicator(avatar: avatar),
              ],
            ],
          ),
          if (onOpenGraveyard != null)
            Positioned(
              top: 0,
              right: 0,
              child: _GraveyardIconButton(onTap: onOpenGraveyard!),
            ),
        ],
      ),
    );
  }
}

/// Small tappable icon that opens a wizard's graveyard (cast + withered
/// spells) — see _BattleScreenState._showGraveyard/_GraveyardDialog. Styled
/// after [_SummonBadge]'s compact bordered-icon look, sized up slightly
/// (14px vs 10px) since this one needs to be tappable, not just legible.
class _GraveyardIconButton extends StatelessWidget {
  const _GraveyardIconButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: const Color(0xFF130C04),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(
            color: kIlluminationGold.withValues(alpha: 0.6),
            width: 0.5,
          ),
        ),
        child: Icon(
          Icons.auto_stories,
          size: 14,
          color: kIlluminationGold.withValues(alpha: 0.85),
        ),
      ),
    );
  }
}

/// Shows the local wizard's active chain casting element, length, and
/// current cost multiplier (design doc §Chain Discount System) -- otherwise
/// the discount driving the whole mana economy decays invisibly. Only
/// rendered while a chain is active ([WizardAvatar.activeChainElement] is
/// non-null); [WizardAvatar.chainCostMultiplier] with the active element as
/// its own pure affinity gives exactly the multiplier the wizard's next
/// matching cast would receive.
class _ChainIndicator extends StatelessWidget {
  const _ChainIndicator({required this.avatar});

  final WizardAvatar avatar;

  @override
  Widget build(BuildContext context) {
    final element = avatar.activeChainElement!;
    final color = BattlefieldPainter.colorForAffinity(element);
    // chainLength is never negative (see WizardAvatar.chainLengths), so this
    // is always a discount, never a surcharge -- the Air-flavor curse is a
    // separate one-shot chainSurcharge status effect, already surfaced via
    // the ordinary status-badge row.
    final discountPct = ((1.0 - avatar.chainCostMultiplier(element)) * 100)
        .round();
    final name = element.name;
    final label =
        '${name[0].toUpperCase()}${name.substring(1)} ×${avatar.chainLength} (−$discountPct%)';

    return Row(
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: TextStyle(fontFamily: 'serif', fontSize: 10, color: color),
        ),
      ],
    );
  }
}

class _StatBar extends StatelessWidget {
  const _StatBar({
    required this.label,
    required this.value,
    required this.max,
    required this.fraction,
    required this.barColor,
    required this.labelColor,
    this.previewValue,
    this.previewFraction = 0.0,
  });

  final String label;
  final int value;
  final int max;
  final double fraction;
  final Color barColor;
  final Color labelColor;

  /// Where this stat would land if the choice being made right now were
  /// committed (currently: a Boost run's price — see _PlayerHud). Null draws
  /// the ordinary bar. Non-null overlays the projected level in a desaturated
  /// shade of [barColor] and reads out "now → after", so the spend is legible
  /// before it's spent.
  final int? previewValue;
  final double previewFraction;

  @override
  Widget build(BuildContext context) {
    final preview = previewValue;
    return Row(
      children: [
        SizedBox(
          width: 26,
          child: Text(
            label,
            style: TextStyle(
              fontFamily: 'serif',
              fontSize: 11,
              letterSpacing: 1,
              fontWeight: FontWeight.w600,
              color: labelColor,
            ),
          ),
        ),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: preview == null
                ? LinearProgressIndicator(
                    value: fraction,
                    backgroundColor: const Color(0xFF3A2210),
                    valueColor: AlwaysStoppedAnimation<Color>(barColor),
                    minHeight: 14,
                  )
                // Two stacked bars, not one: the full-strength fill is what
                // the wizard would be left with, the washed-out fill behind it
                // is what the run is about to eat.
                : Stack(
                    children: [
                      LinearProgressIndicator(
                        value: fraction,
                        backgroundColor: const Color(0xFF3A2210),
                        valueColor: AlwaysStoppedAnimation<Color>(
                          Color.lerp(barColor, kInkMutedColor, 0.55)!,
                        ),
                        minHeight: 14,
                      ),
                      LinearProgressIndicator(
                        value: previewFraction,
                        backgroundColor: Colors.transparent,
                        valueColor: AlwaysStoppedAnimation<Color>(barColor),
                        minHeight: 14,
                      ),
                    ],
                  ),
          ),
        ),
        const SizedBox(width: 7),
        Text(
          preview == null ? '$value / $max' : '$value → $preview',
          style: TextStyle(
            fontFamily: 'serif',
            fontSize: 10,
            color: labelColor.withValues(alpha: 0.80),
          ),
        ),
      ],
    );
  }
}

// ── Artifact corner tile ──────────────────────────────────────────────────────
//
// Floats over the empty space around the hex map (see the Stack in build()),
// right-angle vertex flush with the true screen corner and hypotenuse facing
// the map center — the shape hugs the corner instead of squaring off a
// rectangle of dead space. Long-press is the activation gesture ahead of the
// artifact-activation rework (docs/ARTIFACT_SYSTEM_PLAN.md) — only Rod of
// Wind has a real activation today, so the other three surface a "not yet"
// toast instead of silently doing nothing.

enum _TileCorner { topLeft, topRight, bottomRight, bottomLeft }

/// Triangle with the right angle at [corner] and the hypotenuse running
/// between the two adjacent box corners — i.e. cutting off the corner that
/// points at the map center. Shared by the clipper (hit-testing) and the
/// painter (fill + active border) so they can never disagree on the shape.
Path _cornerTrianglePath(_TileCorner corner, Size size) {
  final w = size.width;
  final h = size.height;
  final path = Path();
  switch (corner) {
    case _TileCorner.topLeft:
      path
        ..moveTo(0, 0)
        ..lineTo(w, 0)
        ..lineTo(0, h);
    case _TileCorner.topRight:
      path
        ..moveTo(w, 0)
        ..lineTo(w, h)
        ..lineTo(0, 0);
    case _TileCorner.bottomRight:
      path
        ..moveTo(w, h)
        ..lineTo(0, h)
        ..lineTo(w, 0);
    case _TileCorner.bottomLeft:
      path
        ..moveTo(0, h)
        ..lineTo(0, 0)
        ..lineTo(w, h);
  }
  path.close();
  return path;
}

class _CornerTriangleClipper extends CustomClipper<Path> {
  const _CornerTriangleClipper(this.corner);

  final _TileCorner corner;

  @override
  Path getClip(Size size) => _cornerTrianglePath(corner, size);

  @override
  bool shouldReclip(covariant _CornerTriangleClipper old) =>
      old.corner != corner;
}

class _CornerTrianglePainter extends CustomPainter {
  _CornerTrianglePainter({
    required this.corner,
    required this.fill,
    this.borderColor,
  });

  final _TileCorner corner;
  final Color fill;
  final Color? borderColor;

  @override
  void paint(Canvas canvas, Size size) {
    final path = _cornerTrianglePath(corner, size);
    canvas.drawPath(path, Paint()..color = fill);
    final border = borderColor;
    if (border != null) {
      canvas.drawPath(
        path,
        Paint()
          ..color = border
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _CornerTrianglePainter old) =>
      old.corner != corner ||
      old.fill != fill ||
      old.borderColor != borderColor;
}

class _ArtifactCornerTile extends StatelessWidget {
  const _ArtifactCornerTile({
    required this.corner,
    required this.icon,
    required this.color,
    required this.count,
    required this.label,
    this.active = false,
    this.dimmed = false,
    this.onTap,
    this.onLongPress,
  });

  final _TileCorner corner;
  final IconData icon;
  final Color color;
  final int count;
  final String label;

  /// This artifact is the one declared at Phase 0 this turn — outlined.
  final bool active;

  /// This artifact's passive is suppressed this turn (counter charms, on a
  /// turn their owner spent something else) — drawn as if the slot were empty.
  final bool dimmed;

  /// Short tap: read-only help text (_onArtifactCornerTap).
  final VoidCallback? onTap;

  /// Long-press: declare-and-fire this turn's activation
  /// (_onArtifactCornerLongPress) — absent for counter charm, which has none.
  final VoidCallback? onLongPress;

  // Sized so a short label anchored at the right-angle vertex stays clear of
  // the hypotenuse (see the module comment's geometry note above).
  static const double _w = 104;
  static const double _h = 104;

  Alignment get _contentAlign => switch (corner) {
    _TileCorner.topLeft => Alignment.topLeft,
    _TileCorner.topRight => Alignment.topRight,
    _TileCorner.bottomRight => Alignment.bottomRight,
    _TileCorner.bottomLeft => Alignment.bottomLeft,
  };

  bool get _startAligned =>
      corner == _TileCorner.topLeft || corner == _TileCorner.bottomLeft;

  @override
  Widget build(BuildContext context) {
    final hasAny = count > 0 && !dimmed;
    final fg = hasAny ? color : kInkMutedColor.withValues(alpha: 0.35);

    return SizedBox(
      width: _w,
      height: _h,
      child: GestureDetector(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Stack(
          children: [
            Positioned.fill(
              child: ClipPath(
                clipper: _CornerTriangleClipper(corner),
                child: CustomPaint(
                  painter: _CornerTrianglePainter(
                    corner: corner,
                    fill: const Color(0xFF221508).withValues(alpha: 0.78),
                    borderColor: active ? kParchmentColor : null,
                  ),
                ),
              ),
            ),
            Align(
              alignment: _contentAlign,
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Column(
                  crossAxisAlignment: _startAligned
                      ? CrossAxisAlignment.start
                      : CrossAxisAlignment.end,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(icon, size: 16, color: fg),
                        const SizedBox(width: 4),
                        Text(
                          '$count',
                          style: TextStyle(
                            fontFamily: 'serif',
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: fg,
                          ),
                        ),
                      ],
                    ),
                    Text(
                      label,
                      style: TextStyle(
                        fontFamily: 'serif',
                        fontSize: 9,
                        letterSpacing: 0.5,
                        color: fg.withValues(alpha: 0.75),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Spell book ────────────────────────────────────────────────────────────────

class _SpellBook extends StatelessWidget {
  const _SpellBook({
    required this.spells,
    required this.selectedIndex,
    required this.onSelect,
    required this.onView,
    this.isWithered = _neverWithered,
    this.costOf = _noCost,
    this.isUnaffordable = _alwaysAffordable,
    this.deckCount,
  });

  static bool _neverWithered(int index, SpellAsset spell) => false;
  static int? _noCost(int index, SpellAsset spell) => null;
  static bool _alwaysAffordable(int index, SpellAsset spell) => false;

  final List<SpellAsset?> spells;

  /// Index into [spells] of the currently-selected card, not its
  /// commitmentHex/id — a chapter may hold several copies of the same Basic
  /// spell's grid (docs/BASIC_SPELLS_PLAN.md §7), so only the SLOT
  /// distinguishes which copy is selected.
  final int? selectedIndex;
  final void Function(int index, SpellAsset spell) onSelect;
  final void Function(SpellAsset) onView;

  /// §9: a withered hand card renders greyed and refuses taps. Indexed by
  /// slot (like [selectedIndex]) for the same duplicate-safety reason.
  /// Defaults to "never withered" for callers that don't track wither state.
  final bool Function(int index, SpellAsset spell) isWithered;

  /// Mana price to print on each card, or null to print none. Slot-indexed
  /// like [selectedIndex] — cost depends on the caster's live chain/status
  /// state, so it can't be read off [SpellAsset] alone.
  final int? Function(int index, SpellAsset spell) costOf;

  /// Whether the caster can't pay for a card under any enhancement choice.
  /// Such a card renders with a red price and refuses taps: casting it would
  /// empty the local mana bar harmlessly while the *peer* forfeits the match
  /// into a cast that only fizzles. Defaults to "always affordable" for
  /// callers with no avatar to price against.
  final bool Function(int index, SpellAsset spell) isUnaffordable;

  /// Remaining deck size (SPELL_DRAW_WIRING_PLAN.md §5's HUD readout). Null
  /// hides the counter (e.g. before the opening deal has run).
  final int? deckCount;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 112,
      color: const Color(0xFF130C04),
      child: Stack(
        children: [
          spells.isEmpty
              ? Center(
                  child: Text(
                    'No spells in hand',
                    style: manuscriptCaptionStyle(
                      color: kParchmentColor.withValues(alpha: 0.30),
                    ),
                  ),
                )
              : ListView.builder(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 6,
                  ),
                  itemCount: spells.length,
                  itemBuilder: (_, i) {
                    final spell = spells[i];
                    if (spell == null) return const SizedBox(width: 6);
                    final selected = i == selectedIndex;
                    final withered = isWithered(i, spell);
                    final tooCostly = !withered && isUnaffordable(i, spell);
                    final cost = costOf(i, spell);
                    return Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: GestureDetector(
                        // Long-press still opens the card either way — an
                        // uncastable spell is still worth reading.
                        onTap: withered || tooCostly
                            ? null
                            : () => onSelect(i, spell),
                        onLongPress: () => onView(spell),
                        child: Opacity(
                          opacity: withered
                              ? 0.35
                              : (tooCostly ? 0.45 : 1.0),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                decoration: BoxDecoration(
                                  border: selected
                                      ? Border.all(
                                          color: kIlluminationGold,
                                          width: 2,
                                        )
                                      : null,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Stack(
                                  children: [
                                    SpellCardWidget(
                                      spell: spell,
                                      size: 72,
                                      interactive: false,
                                    ),
                                    if (spell.isSummon)
                                      const Positioned(
                                        right: 2,
                                        bottom: 2,
                                        child: _SummonBadge(),
                                      ),
                                    if (cost != null)
                                      Positioned(
                                        left: 2,
                                        top: 2,
                                        child: _ManaCostBadge(
                                          cost: cost,
                                          affordable: !tooCostly,
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 3),
                              SizedBox(
                                width: 72,
                                child: Text(
                                  spell.name.isNotEmpty
                                      ? spell.name
                                      : 'Unnamed',
                                  textAlign: TextAlign.center,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontFamily: 'serif',
                                    fontSize: 9,
                                    letterSpacing: 0.3,
                                    color: selected
                                        ? kIlluminationGold
                                        : kParchmentColor,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
          if (deckCount != null)
            Positioned(
              top: 4,
              right: 8,
              child: Text(
                'Deck: $deckCount',
                style: manuscriptCaptionStyle(
                  color: kParchmentColor.withValues(alpha: 0.55),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The mana price of a hand card, in its top-left corner. Red when the caster
/// can't pay it — the visible half of the affordability gate that keeps a
/// player from casting into a spell that fizzles for want of mana.
class _ManaCostBadge extends StatelessWidget {
  const _ManaCostBadge({required this.cost, required this.affordable});

  final int cost;
  final bool affordable;

  @override
  Widget build(BuildContext context) {
    final color = affordable ? const Color(0xFF6FC3FF) : const Color(0xFFE05A4A);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
      decoration: BoxDecoration(
        color: const Color(0xFF130C04).withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(3),
        border: Border.all(color: color.withValues(alpha: 0.7), width: 0.5),
      ),
      child: Text(
        '$cost',
        style: TextStyle(
          fontFamily: 'serif',
          fontSize: 9,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }
}

/// Small corner marker distinguishing a summon-mode spell card from an
/// incantation one at a glance (design doc "Summons").
class _SummonBadge extends StatelessWidget {
  const _SummonBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: const Color(0xFF130C04),
        borderRadius: BorderRadius.circular(3),
        border: Border.all(
          color: kIlluminationGold.withValues(alpha: 0.6),
          width: 0.5,
        ),
      ),
      child: Icon(
        Icons.pets,
        size: 10,
        color: kIlluminationGold.withValues(alpha: 0.85),
      ),
    );
  }
}

// ── Status effect panel ───────────────────────────────────────────────────────

class _StatusEffectPanel extends StatelessWidget {
  const _StatusEffectPanel({required this.avatar, required this.isLocal});

  final WizardAvatar? avatar;
  final bool isLocal;

  @override
  Widget build(BuildContext context) {
    final effects = (avatar?.activeStatusEffects ?? const [])
        .where((fx) => fx.remainingTurns > 0)
        .toList();
    final barriers = (avatar?.barriers ?? const <SpellAffinity, BarrierState>{})
        .entries
        .where((e) => e.value.isAlive)
        .toList();
    final hasAny = effects.isNotEmpty || barriers.isNotEmpty;

    final opponentName = (avatar?.wizardName.isNotEmpty ?? false)
        ? avatar!.wizardName
        : (avatar?.playerId ?? '?');
    final label = isLocal
        ? 'YOUR STATUS'
        : '$opponentName STATUS'.toUpperCase();

    return Container(
      color: const Color(0xFF160E06),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      child: Row(
        children: [
          Text(
            label,
            style: TextStyle(
              fontFamily: 'serif',
              fontSize: 8,
              letterSpacing: 0.8,
              color: isLocal
                  ? kParchmentColor.withValues(alpha: 0.40)
                  : kIlluminationGold.withValues(alpha: 0.65),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: !hasAny
                ? Text(
                    'none',
                    style: TextStyle(
                      fontFamily: 'serif',
                      fontSize: 9,
                      fontStyle: FontStyle.italic,
                      color: kInkMutedColor,
                    ),
                  )
                : SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (int i = 0; i < barriers.length; i++) ...[
                          if (i > 0) const SizedBox(width: 4),
                          _BarrierChip(
                            affinity: barriers[i].key,
                            barrier: barriers[i].value,
                          ),
                        ],
                        for (int i = 0; i < effects.length; i++) ...[
                          if (barriers.isNotEmpty || i > 0)
                            const SizedBox(width: 4),
                          _StatusChip(fx: effects[i]),
                        ],
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.fx});

  final StatusEffect fx;

  @override
  Widget build(BuildContext context) {
    final name = _kStatusLabel[fx.effectTypeId] ?? fx.effectTypeId;
    final isBuff = _kBuffIds.contains(fx.effectTypeId);
    final base = fx.isDormant
        ? kInkMutedColor
        : (isBuff ? const Color(0xFF3A7A3A) : const Color(0xFF8A3030));
    final alpha = fx.isDormant ? 0.45 : 0.90;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: base.withValues(alpha: 0.18),
        border: Border.all(color: base.withValues(alpha: 0.55), width: 1),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        '$name (${fx.remainingTurns})',
        style: TextStyle(
          fontFamily: 'serif',
          fontSize: 9,
          color: base.withValues(alpha: alpha),
        ),
      ),
    );
  }
}

class _BarrierChip extends StatelessWidget {
  const _BarrierChip({required this.affinity, required this.barrier});

  final SpellAffinity affinity;
  final BarrierState barrier;

  @override
  Widget build(BuildContext context) {
    final name = '${kAffinityLabel[affinity]!} Barrier';
    const base = Color(0xFF6A8A3A); // olive-gold — distinct from status buffs
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: base.withValues(alpha: 0.18),
        border: Border.all(color: base.withValues(alpha: 0.55), width: 1),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        '$name (${barrier.hp}hp·${barrier.remainingTurns}t)',
        style: TextStyle(
          fontFamily: 'serif',
          fontSize: 9,
          color: base.withValues(alpha: 0.90),
        ),
      ),
    );
  }
}
