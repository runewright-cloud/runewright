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

import 'dart:async' show Completer, unawaited;
import 'dart:convert' show base64Encode;
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui show Image;

import 'package:cryptography/cryptography.dart' show Sha256;
import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../battle/engine/tile_entry_resolver.dart' show predictAvatarMove;
import '../battle/engine/turn_loop.dart';
import '../battle/engine/wild_magic_applicator.dart' show WildMagicEvent;
import '../battle/models/battle_state.dart';
import '../battle/models/barrier.dart';
import '../battle/models/casting_enhancements.dart';
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
import '../sorcerer/gesture.dart';
import '../sorcerer/vocal_score.dart';
import '../sorcerer/vocal_scorer.dart';
import '../spells/chapter_asset.dart';
import '../spells/enhancement_zone.dart';
import '../spells/sighting_asset.dart';
import '../spells/spell_asset.dart';
import '../spells/spell_permission.dart';
import '../spells/supreme_tags.dart' show deriveSupremeTags;
import '../dev_flags.dart' show kAllowProoflessSpells;
import 'avatars/avatar_sprites.dart' show AvatarAssignment, AvatarAtlas;
import 'scenery/scenery_map.dart';
import 'scenery/scenery_painter.dart';
import 'battlefield_painter.dart';
import 'manuscript_theme.dart';
import 'spell_card_painter.dart';

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
// absorptionRod/deflectionTotem are deliberately excluded: they're summon-only
// (never in a loadout — accoutrement_loadout.dart never emits absorptionRod)
// and out of scope per ARTIFACT_SYSTEM_PLAN.md §1.

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
  StatusEffectId.highMobility: 'High Mob.',
  StatusEffectId.highLiquidity: 'High Liq.',
  StatusEffectId.rangeUp: 'Range+',
  StatusEffectId.rangeDown: 'Range−',
  StatusEffectId.penetrating: 'Piercing',
  StatusEffectId.turbulent: 'Turbulent',
  StatusEffectId.sluggish: 'Sluggish',
  StatusEffectId.quick: 'Quick',
  StatusEffectId.nextSpellCostDouble: '2× Cost',
  StatusEffectId.blind: 'Blind',
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
};

// Buff IDs render in green; everything else renders in red.
const _kBuffIds = {
  StatusEffectId.speedUp,
  StatusEffectId.highMobility,
  StatusEffectId.highLiquidity,
  StatusEffectId.rangeUp,
  StatusEffectId.penetrating,
  StatusEffectId.quick,
  StatusEffectId.chainFast,
  StatusEffectId.haymakerDistanceBonus,
  StatusEffectId.revealCounterCharms,
  StatusEffectId.revealSpells,
  StatusEffectId.revealTargetTile,
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

  @override
  State<BattleScreen> createState() => _BattleScreenState();
}

class _BattleScreenState extends State<BattleScreen>
    with TickerProviderStateMixin {
  List<SpellAsset?> _spells = [];
  late TurnLoop _loop;
  late AnimationController _pulseController;

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

  /// Decoded wizard sprite sheet, or null until it lands (or if it failed) —
  /// the painter falls back to the placeholder disc tokens either way.
  ui.Image? _avatarAtlas;

  /// Which sprite each wizard wears. Const-default today: every wizard gets a
  /// deterministic Hero from their playerId, identically on both devices. The
  /// avatar picker fills this in later — see AvatarAssignment.explicit for the
  /// one constraint that work has to respect.
  final AvatarAssignment _avatarAssignment = const AvatarAssignment();

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

  // Post-resolution Airy Barrier burst prompt: set by _pickFreeMoveDirection
  // (TurnLoop's freeMoveDirectionPicker callback, invoked after every spell
  // for the turn has resolved). Same shape and the same _isBusy caveat as the
  // melee prompt above.
  bool _pickingFreeMove = false;
  List<HexCoord> _freeMoveCandidates = const [];
  Completer<HexCoord?>? _freeMovePickCompleter;

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
    AccoutrementKind.absorptionRod ||
    AccoutrementKind.deflectionTotem =>
      'Absorption Rod — halves the duration of timed effects from an '
          'incoming spell, then is consumed. No activation.',
  };

  static String _artifactLabel(AccoutrementKind kind) => switch (kind) {
    AccoutrementKind.manaGem => 'Mana Gem',
    AccoutrementKind.counterCharm => 'Counter Charm',
    AccoutrementKind.bookmark => 'Bookmark',
    AccoutrementKind.rodOfSpreading => 'Rod of Wind',
    AccoutrementKind.absorptionRod => 'Absorption Rod',
    AccoutrementKind.deflectionTotem => 'Deflection Totem',
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

  // ── Sorcerer mode ──────────────────────────────────────────────────────────
  VocalScorer? _vocalScorer;
  double _ambientFloorRms = 0.0;
  bool _isCapturingVoice = false;
  VocalWord? _capturingWord;

  /// Capture window for one incantation. Fixed for this pass — see
  /// VocalScorer's lifecycle doc (vocal_scorer.dart) for the begin/end contract.
  static const _voiceCaptureWindow = Duration(milliseconds: 2500);

  @override
  void initState() {
    super.initState();
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
    _initScenery();
    unawaited(_loadAvatarAtlas());
    _loadSpells();
    if (widget.state.config.sorcererMode) {
      _initSorcererMode();
    }
    _initTurnLoop();
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
    Uint8List? vkBytes;
    Future<List<int>> Function(List<int>)? signMessage;

    if (isRealDuel) {
      try {
        final tier = widget.state.config.tier;
        final vkData = await rootBundle.load(
          'assets/circuits/ca_v2_4_tier$tier.vk',
        );
        vkBytes = vkData.buffer.asUint8List();
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
    _loop = TurnLoop(
      state: widget.state,
      session: session ?? SoloBattleSession(state: widget.state),
      localPlayerId: widget.localPlayerId,
      matchId: widget.matchId,
      tier: widget.state.config.tier,
      verifyProof: verifyProof,
      vkBytes: vkBytes,
      peerBookRoot: widget.peerBookRoot,
      peerBookLeafCount: widget.peerBookLeafCount,
      peerOwnerPubkeyHex: widget.peerOwnerPubkeyHex,
      peerPermissions: widget.peerPermissions ?? const [],
      signMessage: signMessage,
      peerRawPubkey: widget.peerRawPubkey,
      isSorcererMode: widget.state.config.sorcererMode,
      meleeTargetPicker: _pickMeleeTarget,
      freeMoveDirectionPicker: _pickFreeMoveDirection,
      artifactActivationPicker: _pickArtifactActivation,
      onMovementResolved: _playAvatarWalks,
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
  }

  /// Builds the active VocalScorer and runs the once-per-match ambient
  /// noise-floor calibration (3 s of silence). No reference templates are
  /// bundled yet — see ReferenceMatchVocalScorer's energy fallback — so
  /// pronunciation scoring is loudness-based until templates are recorded
  /// via ReferenceMatchVocalScorer.recordTemplate() and wired in here.
  Future<void> _initSorcererMode() async {
    _vocalScorer = VocalScorerFactory.create();
    final floor = await AmbientCalibrator.measure();
    if (!mounted) return;
    setState(() => _ambientFloorRms = floor);
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _castAnimController.dispose();
    _effectBloomController.dispose();
    _moveAnimController.dispose();
    _vocalScorer?.dispose();
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

  /// TurnLoop's [FreeMoveDirectionPicker]: an Airy Barrier burst this turn
  /// earned the local wizard one reactive step. Highlights the legal adjacent
  /// tiles and waits for the player to tap one (see _onTapBattlefield's
  /// _pickingFreeMove branch) or to pass (_ActionBar's onDeclineFreeMove).
  /// Only ever called when [candidates] is non-empty.
  ///
  /// Lifts the resolution hold-back for the duration of the prompt and puts it
  /// back afterwards. This is the one moment in the turn where the player makes
  /// a *decision* against a board that's still mid-reveal — Phase 5.5 runs
  /// after this turn's spells have already created their lava, ice and clouds —
  /// and asking someone to step somewhere while hiding what's on the tile is a
  /// worse bug than the pop-in the hold-back exists to prevent. Restoring the
  /// snapshot re-hides them, so they still bloom out of their cast tiles with
  /// their cards. See [ResolutionBaseline].
  Future<HexCoord?> _pickFreeMoveDirection(List<HexCoord> candidates) async {
    if (!mounted) return null;
    final completer = Completer<HexCoord?>();
    final heldBack = _resolutionBaseline;
    setState(() {
      _pickingFreeMove = true;
      _freeMoveCandidates = candidates;
      _freeMovePickCompleter = completer;
      _resolutionBaseline = null;
    });
    final result = await completer.future;
    if (mounted) {
      setState(() {
        _pickingFreeMove = false;
        _freeMoveCandidates = const [];
        _freeMovePickCompleter = null;
        _resolutionBaseline = heldBack;
      });
    }
    return result;
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
  // `insufficient_mana_for_spell` and forfeits the match. That asymmetry is
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
    if (_spellNeedsConveyorDirection(spell)) {
      conveyorDirection = await _pickConveyorDirection(target);
      if (conveyorDirection == null) return; // player cancelled
      if (!mounted) return;
    }

    final isPotent = _selectedEnhancement == 'fire';
    final isVelocity = _selectedEnhancement == 'air';
    final isEfficiency = _selectedEnhancement == 'water';

    final scorer = _vocalScorer;
    final word = spell.formula.isNotEmpty
        ? VocalWord.fromAffinityZone(spell.formula.first)
        : null;
    if (!widget.state.config.sorcererMode || scorer == null || word == null) {
      // Wizard mode, or sorcerer mode before calibration finishes, or a
      // formula with no recognised primary affinity (e.g. wild magic) — cast
      // with no vocal component rather than block the player.
      _commitAction(
        SpellCastAction(
          spell: spell,
          targetHex: target,
          isPotent: isPotent,
          isVelocity: isVelocity,
          isEfficiency: isEfficiency,
          conveyorDirection: conveyorDirection,
          handIndex: _selectedHandIndex,
        ),
      );
      return;
    }

    setState(() {
      _isCapturingVoice = true;
      _capturingWord = word;
    });
    await scorer.beginCapture(word);
    await Future<void>.delayed(_voiceCaptureWindow);
    final vocalScore = await scorer.endCapture(
      ambientFloorRms: _ambientFloorRms,
    );
    if (!mounted) return;
    setState(() {
      _isCapturingVoice = false;
      _capturingWord = null;
    });

    // Somatic/gesture seam (lib/sorcerer/gesture.dart) — stubbed off.
    // GestureCapture/GestureClassifier/GestureEnrollment now exist
    // (docs/SOMATIC_GESTURE_PLAN.md) and are exercised from
    // practice_screen.dart's Gesture tab, but kSomaticCaptureEnabled stays
    // false until a real-device confusion-matrix pass (test/sorcerer/)
    // clears — a fixture harness calibrates, it doesn't validate hardware.
    // When it flips: capture here with the same HoldToRecordButton window
    // used by enrollment (SOMATIC_GESTURE_PLAN.md §7 — segmentation must
    // match), classify, and IF the resolved gesture's zone is not in
    // spell.supremeTags (the same certified-eligibility check the wizard-
    // mode enhancement picker already gates on, §1651 above), downgrade to
    // neutral client-side before folding .enhancementZone into the
    // enhancement choice above — exactly parallel to how vocalScore feeds
    // CastingEnhancements.fromSorcererQuality via hasPotentLoadout/
    // hasVelocityLoadout/hasEfficiencyLoadout below. The peer-side forfeit
    // gate for an unbacked claim (turn_loop.dart's
    // TrajectoryParser.certifiedSupremeTags check) stays as the backstop —
    // do not weaken it to a silent downgrade.
    if (kSomaticCaptureEnabled) {
      // TODO(somatic): capture a Gesture, map via .enhancementZone, fold in.
    }

    if (kDebugMode) {
      // Mirrors exactly what TurnLoop will independently (re)compute from
      // this same VocalScore at commit time and at resolution — see
      // CastingEnhancements.fromSorcererQuality's determinism note.
      final enhancements = CastingEnhancements.fromSorcererQuality(
        vocalScore: vocalScore,
        hasPotentLoadout: isPotent,
        hasVelocityLoadout: isVelocity,
        hasEfficiencyLoadout: isEfficiency,
      );
      final q =
          (vocalScore.pronunciationU8 + vocalScore.volumeU8) / (2 * 254.0);
      debugPrint(
        '[sorcerer] word=${word.name} '
        'rawPronunciation=${vocalScore.pronunciation.toStringAsFixed(4)} '
        'rawVolume=${vocalScore.volume.toStringAsFixed(4)} '
        'u8=(${vocalScore.pronunciationU8}, ${vocalScore.volumeU8}) '
        'Q=${q.toStringAsFixed(4)} '
        'manaCostMultiplier=${enhancements.manaCostMultiplier.toStringAsFixed(3)} '
        'enhancementEnabled=${enhancements.enhancementEnabled} '
        'fizzle=${enhancements.fizzle}',
      );
    }

    _commitAction(
      SpellCastAction(
        spell: spell,
        targetHex: target,
        isPotent: isPotent,
        isVelocity: isVelocity,
        isEfficiency: isEfficiency,
        vocalScore: vocalScore,
        conveyorDirection: conveyorDirection,
        handIndex: _selectedHandIndex,
      ),
    );
  }

  /// Whether casting [spell] will resolve to an Air-flavor tileModification
  /// effect (always a ConveyorTile for that pairing) -- pure/cheap, needs
  /// only the spell's own formula (see effect_kind.dart formulaEffects).
  bool _spellNeedsConveyorDirection(SpellAsset spell) =>
      formulaEffects(spell.formula).any(
        (e) =>
            e.kind == EffectKind.tileModification &&
            e.affinity == SpellAffinity.air,
      );

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

    final scorer = _vocalScorer;
    final word = spell.formula.isNotEmpty
        ? VocalWord.fromAffinityZone(spell.formula.first)
        : null;
    if (!widget.state.config.sorcererMode || scorer == null || word == null) {
      _commitAction(
        MysterySpellCastAction(
          spell: spell,
          mysteryCommitment: commitment,
          immediateTarget: isImmediate ? target : null,
          immediateNonce: isImmediate ? nonce : null,
          handIndex: _selectedHandIndex,
        ),
      );
      return;
    }

    setState(() {
      _isCapturingVoice = true;
      _capturingWord = word;
    });
    await scorer.beginCapture(word);
    await Future<void>.delayed(_voiceCaptureWindow);
    final vocalScore = await scorer.endCapture(
      ambientFloorRms: _ambientFloorRms,
    );
    if (!mounted) return;
    setState(() {
      _isCapturingVoice = false;
      _capturingWord = null;
    });

    _commitAction(
      MysterySpellCastAction(
        spell: spell,
        mysteryCommitment: commitment,
        immediateTarget: isImmediate ? target : null,
        immediateNonce: isImmediate ? nonce : null,
        vocalScore: vocalScore,
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
  int _maxCastRange(WizardAvatar caster, HexCoord hex) {
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
    return (casterBound || hexBound) ? 1 : caster.effectiveSpellRange;
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

    // Same reasoning as the melee branch: the Airy Barrier burst prompt also
    // fires from inside the in-flight runTurn() call — see
    // _pickFreeMoveDirection.
    if (_pickingFreeMove) {
      if (_freeMoveCandidates.contains(hex)) {
        _freeMovePickCompleter?.complete(hex);
      }
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
      if (hexDistance(local.position, hex) > _maxCastRange(local, hex)) return;
      setState(() => _targetHex = hex);
    } else {
      final local = _local;
      if (local == null) return;
      final origin = local.position;
      // Simulates TurnLoop._walkAvatar's real walk -- including any conveyor
      // pushes along the way -- so the tap target the player sees matches
      // what will actually happen when the turn resolves. See
      // predictAvatarMove's doc comment for why this can't predict past a
      // closed conveyor loop (needs post-entropy RNG not known yet).
      final prediction = predictAvatarMove(
        state: widget.state,
        origin: origin,
        declaredPath: _movePath,
        budget: _localMoveBudget,
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
    final casterLabel = event.casterId == widget.localPlayerId
        ? 'your own rune'
        : "your opponent's rune";
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

  /// Full-screen, non-dismissable failure state — the only thing this screen
  /// renders once a duel is unsafe to play (verifier init failed, or lockstep
  /// broke mid-turn). Deliberately a dead end with one way out: there is no
  /// "continue anyway" for a match whose two devices disagree.
  Widget _blockingError(String message) => Scaffold(
    backgroundColor: const Color(0xFF1A1008),
    body: Center(
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
  );

  @override
  Widget build(BuildContext context) {
    // Stage 2 fail-closed gate (see _initTurnLoop): never render the
    // interactive battle UI before _loop exists, and never silently
    // proceed if verifier init failed.
    final initError = _verifierInitError;
    if (initError != null) {
      return _blockingError(
        'Could not prepare this duel for play:\n$initError',
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
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          widget.state.turnNumber == 0
              ? 'BATTLE'
              : 'TURN ${widget.state.turnNumber}',
          style: manuscriptHeaderStyle(fontSize: 18, color: kParchmentColor),
        ),
      ),
      body: Column(
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
            _OpponentHudRow(avatars: foes, maxHp: config.playerHp),

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
                                        ).path.skip(1).toList()
                                      : _movePath,
                                  spellRangeRadius:
                                      _selectedSpell != null && _local != null
                                      ? _maxCastRange(_local!, _local!.position)
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
                                  moveAnimation: _moveAnimController,
                                  avatarAtlas: _avatarAtlas,
                                  avatarAssignment: _avatarAssignment,
                                  tileEffects: widget.state.tileEffects,
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
                                  freeMovePickHexes: _pickingFreeMove
                                      ? _freeMoveCandidates
                                      : const [],
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
          if (_phase == _InputPhase.action &&
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

          // Phase-0 read-out is corner-tile-only now (2026-07-31): "mine" is
          // the outlined tile, "charms down" is the dimmed counter-charm
          // tile, and the opponent's declaration is a one-shot toast fired
          // from _beginArtifactPhaseForTurn the moment it's revealed, rather
          // than a banner that lingers for the rest of the turn.

          // Sorcerer mode: vocal capture indicator
          if (_isCapturingVoice && _capturingWord != null)
            Container(
              width: double.infinity,
              color: const Color(0xFF6B1F1F),
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'SPEAK NOW: ${_capturingWord!.name.toUpperCase()}',
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
            availableMana: _local?.mana,
            hasTarget: _targetHex != null,
            movePathLength: _movePath.length,
            isBusy: _isBusy || _isCapturingVoice,
            pickingMelee: _pickingMelee,
            pickingFreeMove: _pickingFreeMove,
            onDash: _onDash,
            onMeditateMain: _onMeditateMain,
            onCast: _onCast,
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
          ),

          // Incantation thumbnail tray — neutral space outside the grid for
          // spells resolved this turn; long-tap re-opens the full card.
          if (_incantationTray.isNotEmpty || _revealReservesTray)
            _IncantationTray(
              key: _incantationTrayKey,
              thumbnails: _incantationTray,
            ),

          // Player HP / MP bars
          if (local != null) _PlayerHud(avatar: local, maxHp: config.playerHp),

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
    );

    final summary = _matchEndSummary;
    if (summary == null) return scaffold;
    return Stack(
      children: [
        scaffold,
        _MatchEndOverlay(
          summary: summary,
          onLeave: () => Navigator.of(context).pop(),
        ),
      ],
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

/// Renders each live summon's card art as a tiny thumbnail on its battlefield
/// tile, in place of the plain affinity-letter token painted underneath by
/// [BattlefieldPainter]. Purely decorative — sits under an [IgnorePointer] so
/// the existing long-press hit-testing (`_onLongPressBattlefield`, which
/// already opens the full card via [showSpellCardFullscreen]) is unaffected.
///
/// Only minions [_cardForMinion] resolves a card for get a thumbnail;
/// everything else falls back to the painter's plain token.
class _MinionArtOverlay extends StatelessWidget {
  const _MinionArtOverlay({
    required this.minions,
    required this.spellByMinionId,
    required this.localTeamId,
    required this.center,
    required this.hexSize,
  });

  final List<Minion> minions;
  final Map<String, SpellAsset> spellByMinionId;
  final String? localTeamId;
  final Offset center;
  final double hexSize;

  @override
  Widget build(BuildContext context) {
    final size = hexSize * 0.62;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        for (final m in minions)
          if (_cardForMinion(m, spellByMinionId) case final card?)
            Positioned(
              left: hexToPixel(m.position, center, hexSize).dx - size / 2,
              top: hexToPixel(m.position, center, hexSize).dy - size / 2,
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
                // The tint stops at the art: the gold/red border stays true so
                // a phantasmal creature's side is still readable at a glance.
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
            ),
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
    required this.onDash,
    required this.onMeditateMain,
    required this.onCast,
    required this.onCancel,
    required this.onMeditateMove,
    required this.onConfirmMove,
    required this.onCancelMove,
    required this.onCancelDirectionPick,
    required this.onDeclineMelee,
    required this.onDeclineFreeMove,
  });

  final _InputPhase phase;
  final SpellAsset? selectedSpell;

  /// Mana [selectedSpell] costs under the currently-chosen enhancement, or
  /// null when nothing is selected / there's no local avatar to price against.
  final int? selectedSpellCost;

  /// The local caster's mana. With [selectedSpellCost] this decides whether
  /// CAST is live: an unaffordable cast is not a local inconvenience, it makes
  /// the *peer* forfeit the match (TurnLoop._verifyPeerSpellCast,
  /// `insufficient_mana_for_spell`), so the button must not offer it.
  final int? availableMana;

  final bool hasTarget;
  final int movePathLength;
  final bool isBusy;

  /// Resolution-phase melee prompt (see _BattleScreenState._pickMeleeTarget)
  /// overrides whatever [phase] happens to be — the turn is already mid
  /// -submission by the time this fires.
  final bool pickingMelee;

  /// Post-resolution Airy Barrier burst prompt (see
  /// _BattleScreenState._pickFreeMoveDirection) — same override as
  /// [pickingMelee]; the two are never true at once (different phases).
  final bool pickingFreeMove;

  final VoidCallback onDash;
  final VoidCallback onMeditateMain;
  final VoidCallback onCast;
  final VoidCallback onCancel;
  final VoidCallback onMeditateMove;
  final VoidCallback onConfirmMove;
  final VoidCallback onCancelMove;
  final VoidCallback onCancelDirectionPick;
  final VoidCallback onDeclineMelee;
  final VoidCallback onDeclineFreeMove;

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
                'Your airy barrier bursts — step free? '
                'Tap a highlighted tile, or stand fast',
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
                      '$cost mana',
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
  const _OpponentHudRow({required this.avatars, required this.maxHp});

  final List<WizardAvatar> avatars;
  final int maxHp;

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
              child: _OpponentChip(avatar: avatars[i], maxHp: maxHp),
            ),
          ],
        ],
      ),
    );
  }
}

class _OpponentChip extends StatelessWidget {
  const _OpponentChip({required this.avatar, required this.maxHp});

  final WizardAvatar avatar;
  final int maxHp;

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
        Text(
          name,
          style: const TextStyle(
            fontFamily: 'serif',
            fontSize: 10,
            letterSpacing: 0.5,
            color: kParchmentColor,
          ),
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
  const _PlayerHud({required this.avatar, required this.maxHp});

  final WizardAvatar avatar;
  final int maxHp;

  @override
  Widget build(BuildContext context) {
    final hpFrac = maxHp > 0 ? (avatar.hp / maxHp).clamp(0.0, 1.0) : 0.0;
    final manaFrac = avatar.maxMana > 0
        ? (avatar.mana / avatar.maxMana).clamp(0.0, 1.0)
        : 0.0;

    return Container(
      color: kInkColor,
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _StatBar(
            label: 'HP',
            value: avatar.hp,
            max: maxHp,
            fraction: hpFrac,
            barColor: const Color(0xFF8B1E1E),
            labelColor: const Color(0xFFD48A8A),
          ),
          const SizedBox(height: 6),
          _StatBar(
            label: 'MP',
            value: avatar.mana,
            max: avatar.maxMana,
            fraction: manaFrac,
            barColor: const Color(0xFF2B4D8C),
            labelColor: const Color(0xFF8AACED),
          ),
          if (avatar.activeChainElement != null) ...[
            const SizedBox(height: 4),
            _ChainIndicator(avatar: avatar),
          ],
        ],
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
  });

  final String label;
  final int value;
  final int max;
  final double fraction;
  final Color barColor;
  final Color labelColor;

  @override
  Widget build(BuildContext context) {
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
            child: LinearProgressIndicator(
              value: fraction,
              backgroundColor: const Color(0xFF3A2210),
              valueColor: AlwaysStoppedAnimation<Color>(barColor),
              minHeight: 14,
            ),
          ),
        ),
        const SizedBox(width: 7),
        Text(
          '$value / $max',
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
  /// over `insufficient_mana_for_spell`. Defaults to "always affordable" for
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
/// player from casting into the peer's `insufficient_mana_for_spell` forfeit.
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
