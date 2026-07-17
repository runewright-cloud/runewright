// SPDX-License-Identifier: GPL-3.0-or-later
//
// battle_screen.dart — in-battle HUD: battlefield grid, player stats,
// artifact counts, and the spell hand for the active chapter.
//
// Layout (portrait):
//   AppBar   — turn counter + leave button
//   Opponent strip — compact HP/mana for each non-local avatar (if any)
//   Battlefield  — LayoutBuilder → BattlefieldPainter (Expanded, tappable)
//   Action bar  — PASS / spell name / CAST
//   Player HP/MP bars
//   Artifact row — 4 icon+count chips
//   Spell book  — horizontal scroll of SpellCardWidgets (tap → select)

import 'dart:async' show Completer, unawaited;
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:flutter/material.dart';

import '../battle/engine/tile_entry_resolver.dart' show predictAvatarMove;
import '../battle/engine/turn_loop.dart';
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
import '../battle/models/pending_delayed_spell.dart' show PendingDelayedSpell;
import '../battle/models/terrain.dart' show ImpassableTile, SlowTile;
import '../battle/models/status_effect_ids.dart';
import '../battle/models/wizard_avatar.dart';
import '../battle/networking/battle_session.dart';
import '../battle/networking/solo_battle_session.dart';
import '../engine/hex_grid.dart';
import '../sorcerer/gesture.dart';
import '../sorcerer/vocal_score.dart';
import '../sorcerer/vocal_scorer.dart';
import '../spells/chapter_asset.dart';
import '../spells/enhancement_zone.dart';
import '../spells/spell_asset.dart';
import '../spells/supreme_tags.dart' show deriveSupremeTags;
import 'battlefield_painter.dart';
import 'manuscript_theme.dart';
import 'spell_card_painter.dart';

enum _InputPhase { action, movement, pickingDirection }

// ── Artifact display table ────────────────────────────────────────────────────

const _kArtifacts = [
  (AccoutrementKind.manaGem, Icons.diamond_outlined, Color(0xFF2B4D8C), 'Gems'),
  (
    AccoutrementKind.bookmark,
    Icons.bookmark_outlined,
    Color(0xFF5588BB),
    'Marks',
  ),
  (
    AccoutrementKind.absorptionRod,
    Icons.shield_outlined,
    Color(0xFF7A6040),
    'Rods',
  ),
  (AccoutrementKind.counterCharm, Icons.block, Color(0xFFB84040), 'Charms'),
];

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
  StatusEffectId.statusDormant: 'Dormant',
  StatusEffectId.haymakerDot: 'Burning',
  StatusEffectId.haymakerSlow: 'Slowed',
  StatusEffectId.haymakerStatusDrain: 'Drained',
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
  });

  final BattleState state;
  final String localPlayerId;
  final ChapterAsset chapter;

  /// Supply a [BattleTurnSession] for network play. Defaults to [SoloBattleSession].
  final BattleTurnSession? session;

  @override
  State<BattleScreen> createState() => _BattleScreenState();
}

class _BattleScreenState extends State<BattleScreen>
    with TickerProviderStateMixin {
  List<SpellAsset?> _spells = [];
  late TurnLoop _loop;
  late AnimationController _pulseController;

  // Cast animation — glowing orb(s) for the spell(s) resolved on the most
  // recent turn. Fixed for one playback of _castAnimController; replaced
  // (and the controller restarted) each time a new turn resolves with casts.
  late AnimationController _castAnimController;
  List<CastAnimation> _castAnimations = const [];
  List<ConveyorChainAnimation> _conveyorChainAnimations = const [];

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
  HexCoord? _targetHex; // spell target (action phase)
  TurnAction? _pendingAction;
  List<HexCoord> _movePath = const []; // movement path (movement phase)
  bool _isBusy = false;

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
  // is processed. Not pruned on death (match-scoped, small); a minion
  // created by a mirror/copy effect rather than a direct cast (e.g.
  // Reflections' summonMirror) has no entry and simply doesn't respond to
  // long-tap.
  final Map<String, SpellAsset> _summonSpellByMinionId = {};

  // Cast-time enhancement choice — zone tag ('fire'/'air'/'water'/'earth')
  // or null for neutral (no enhancement). Eligibility is
  // _selectedSpell.supremeTags; see _EnhancementPicker.
  String? _selectedEnhancement;

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

  // Battlefield geometry — tracked from LayoutBuilder so tap handler can convert
  double _hexSize = 20;
  Offset _fieldCenter = Offset.zero;

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
    _loop = TurnLoop(
      state: widget.state,
      session: widget.session ?? SoloBattleSession(state: widget.state),
      localPlayerId: widget.localPlayerId,
      isSorcererMode: widget.state.config.sorcererMode,
      meleeTargetPicker: _pickMeleeTarget,
      onPhase: _onEnginePhase,
    );
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
    _loadSpells();
    if (widget.state.config.sorcererMode) {
      _initSorcererMode();
    }
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
    _vocalScorer?.dispose();
    super.dispose();
  }

  Future<void> _loadSpells() async {
    final all = await SpellAsset.loadAll();
    if (!mounted) return;
    final byId = {for (final s in all) s.id: s};
    final loaded = widget.chapter.entries.map((e) => byId[e.spellId]).toList();

    // Backfill supremeTags for spells added to a chapter before this
    // eligibility tracking existed, so the cast-time enhancement picker
    // sees correct eligibility even for older chapters — mirrors
    // library_screen.dart's _addToChapter backfill.
    final resolved = <SpellAsset?>[];
    for (final spell in loaded) {
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
    setState(() => _spells = resolved);
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
    final origin = _pendingCastOrigin;
    final affinity = _pendingCastAffinity;
    if (origin != null && affinity != null) {
      orbs.add(
        PendingCastOrb(
          origin: origin,
          color: BattlefieldPainter.colorForAffinity(affinity),
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
          color: BattlefieldPainter.colorForAffinity(pendingAffinity),
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
    return min(byWidth, byHeight).clamp(6.0, 36.0);
  }

  // ── Helpers ─────────────────────────────────────────────────────────────────

  bool _isValidHex(HexCoord hex) {
    final r = widget.state.config.gridRadius;
    return hex.q.abs() <= r && hex.r.abs() <= r && (hex.q + hex.r).abs() <= r;
  }

  void _resetTurn() {
    _phase = _InputPhase.action;
    _selectedSpell = null;
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

  /// Phase banner text — "Summons" / "Main" / "Move" / "Resolution".
  /// Pre-submission phases come straight from [_phase] (this UI already
  /// knows which one it's in); the two mid-submission phases come from
  /// [_submittingPhase], set by [_onEnginePhase].
  String get _phaseLabel {
    if (_pickingMelee) return 'Resolution';
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

  void _selectSpell(SpellAsset spell) {
    if (_isBusy || _phase != _InputPhase.action) return;
    setState(() {
      _selectedSpell = _selectedSpell?.id == spell.id ? null : spell;
      if (_selectedSpell == null) _targetHex = null;
      _selectedEnhancement = null;
      _mysteryDelay = 0;
    });
  }

  /// Confirm the action and advance to the movement phase.
  void _commitAction(TurnAction action) {
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

    // Somatic/gesture seam (lib/sorcerer/gesture.dart) — stubbed off, since
    // no gesture-capture pipeline exists yet. When one does, this is where a
    // captured Gesture would be read and its .enhancementZone folded into
    // the enhancement choice above, exactly parallel to how vocalScore feeds
    // CastingEnhancements.fromSorcererQuality via hasPotentLoadout/
    // hasVelocityLoadout/hasEfficiencyLoadout below.
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

  /// After any battlefield tap, update which avatar's status effects are shown.
  /// Tapping an occupied hex shows that avatar; tapping empty hex reverts to local.
  void _updateInspection(HexCoord hex) {
    WizardAvatar? occupant;
    for (final av in widget.state.avatars) {
      if (widget.state.battlefield.occupancy[av.playerId] == hex) {
        occupant = av;
        break;
      }
    }
    // Only hold an override for non-local avatars.
    final isOpponent =
        occupant != null && occupant.playerId != widget.localPlayerId;
    setState(() => _inspectedAvatar = isOpponent ? occupant : null);
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
      if (tileEffect is ImpassableTile) return;
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
    if (_isBusy) return;
    setState(() {
      _isBusy = true;
      // Summons is the first internal phase runTurn will actually reach;
      // _onEnginePhase corrects this to actionResolve once melee/resolution
      // begins. See _phaseLabel.
      _submittingPhase = TurnPhase.summons;
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
      await _loop.runTurn(input);
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
      final resolved = List<ResolvedSpellEvent>.from(_loop.lastResolvedSpells);
      // Hold every effect created this turn off the field; the reveal sequence
      // un-hides each spell's set (and blooms it) only once that spell's card
      // has finished. See _playResolvedSpellSequence / _bloomSpellEffects.
      final hiddenClouds = <String>{};
      final hiddenTiles = <HexCoord>{};
      final hiddenMinions = <String>{};
      for (final ev in resolved) {
        hiddenClouds.addAll(ev.createdCloudIds);
        hiddenTiles.addAll(ev.createdTileHexes);
        hiddenMinions.addAll(ev.createdMinionIds);
      }
      setState(() {
        _resetTurn();
        _castAnimations = const [];
        _conveyorChainAnimations = chains;
        _hiddenCloudIds = hiddenClouds;
        _hiddenTileHexes = hiddenTiles;
        _hiddenMinionIds = hiddenMinions;
        _effectBloom = null;
      });
      if (resolved.isNotEmpty || chains.isNotEmpty) {
        unawaited(_playResolvedSpellSequence(resolved, castEvents, chains));
      }
    } catch (e) {
      if (!mounted) return;
      // Turn never committed — discard the not-yet-real staged secret rather
      // than leaving a reveal the engine has no matching PendingDelayedSpell
      // for (dueSecrets are left in place; they'll be retried next submit).
      _stagedMysterySecret = null;
      setState(_resetTurn);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Turn error: $e')));
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
  Future<void> _playResolvedSpellSequence(
    List<ResolvedSpellEvent> events,
    List<SpellCastEvent> castEvents,
    List<ConveyorChainAnimation> chains,
  ) async {
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
              color: BattlefieldPainter.colorForAffinity(cast.affinity),
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
      );
      if (!mounted) return;
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
  /// until after the card, so the current tray length *is* its index).
  Offset? _thumbnailTarget(ResolvedSpellEvent ev) {
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
  /// current/max HP) if the tapped hex holds one this client has a recorded
  /// SpellAsset for. No-op everywhere else (empty tile, opponent's
  /// mirror-summoned creature with no recorded cast — see
  /// _summonSpellByMinionId's doc comment).
  void _onLongPressBattlefield(Offset localPos) {
    final hex = pixelToHex(localPos, _fieldCenter, _hexSize);
    final minion = widget.state.minions
        .where((m) => m.isAlive && m.occupiedTiles.contains(hex))
        .firstOrNull;
    if (minion == null) return;
    final spell = _summonSpellByMinionId[minion.id];
    if (spell == null) return;
    showSpellCardFullscreen(context, spell, liveHp: minion.hp);
  }

  // ── Build ───────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final local = _local;
    final config = widget.state.config;
    final foes = _opponents;

    return Scaffold(
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
          // Phase banner — always visible, so it's never ambiguous whether
          // the battle is waiting on the local player's Main/Move decision
          // or playing out Summons/Resolution.
          _PhaseBanner(label: _phaseLabel),

          // Opponent strip
          if (foes.isNotEmpty)
            _OpponentHudRow(avatars: foes, maxHp: config.playerHp),

          // Battlefield — tappable
          Expanded(
            child: LayoutBuilder(
              builder: (ctx, constraints) {
                final size = Size(constraints.maxWidth, constraints.maxHeight);
                final hSize = _hexSizeFromConstraints(size, config.gridRadius);
                final center = Offset(size.width / 2, size.height / 2);
                // Store for tap handler (accessed on next frame — safe because
                // the values only change on resize, not during a turn).
                _hexSize = hSize;
                _fieldCenter = center;
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapUp: (d) => _onTapBattlefield(d.localPosition),
                  onLongPressStart: (d) =>
                      _onLongPressBattlefield(d.localPosition),
                  child: CustomPaint(
                    key: _battlefieldKey,
                    painter: BattlefieldPainter(
                      radius: config.gridRadius,
                      hexSize: hSize,
                      occupancy: widget.state.battlefield.occupancy,
                      localPlayerId: widget.localPlayerId,
                      highlightHex: _targetHex,
                      // Renders the *simulated* path (including any free
                      // conveyor push-throughs), not just the raw tiles
                      // tapped, so the player sees where they'll actually
                      // end up -- see predictAvatarMove.
                      movePath: _local != null
                          ? predictAvatarMove(
                              state: widget.state,
                              origin: _local!.position,
                              declaredPath: _movePath,
                              budget: _localMoveBudget,
                            ).path.skip(1).toList()
                          : _movePath,
                      spellRangeRadius: _selectedSpell != null && _local != null
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
                      conveyorChainAnimations: _conveyorChainAnimations,
                      pendingCastOrbs: _pendingCastOrbs,
                      scryRevealHex: _scryRevealedTile,
                      meleePickHexes: _pickingMelee
                          ? _meleeCandidates
                          : const [],
                      hiddenCloudIds: _hiddenCloudIds,
                      hiddenTileHexes: _hiddenTileHexes,
                      hiddenMinionIds: _hiddenMinionIds,
                      effectBloom: _effectBloom,
                      effectBloomAnimation: _effectBloomController,
                    ),
                    child: const SizedBox.expand(),
                  ),
                );
              },
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
            hasTarget: _targetHex != null,
            movePathLength: _movePath.length,
            isBusy: _isBusy || _isCapturingVoice,
            pickingMelee: _pickingMelee,
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

          // Artifact counts
          _ArtifactRow(avatar: local),

          // Spell hand
          _SpellBook(
            spells: _spells,
            selectedId: _selectedSpell?.id,
            onSelect: _selectSpell,
            onView: (spell) => showSpellCardFullscreen(context, spell),
          ),
        ],
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
    required this.hasTarget,
    required this.movePathLength,
    required this.isBusy,
    required this.pickingMelee,
    required this.onDash,
    required this.onMeditateMain,
    required this.onCast,
    required this.onCancel,
    required this.onMeditateMove,
    required this.onConfirmMove,
    required this.onCancelMove,
    required this.onCancelDirectionPick,
    required this.onDeclineMelee,
  });

  final _InputPhase phase;
  final SpellAsset? selectedSpell;
  final bool hasTarget;
  final int movePathLength;
  final bool isBusy;

  /// Resolution-phase melee prompt (see _BattleScreenState._pickMeleeTarget)
  /// overrides whatever [phase] happens to be — the turn is already mid
  /// -submission by the time this fires.
  final bool pickingMelee;

  final VoidCallback onDash;
  final VoidCallback onMeditateMain;
  final VoidCallback onCast;
  final VoidCallback onCancel;
  final VoidCallback onMeditateMove;
  final VoidCallback onConfirmMove;
  final VoidCallback onCancelMove;
  final VoidCallback onCancelDirectionPick;
  final VoidCallback onDeclineMelee;

  @override
  Widget build(BuildContext context) {
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
                      ? (hasTarget
                            ? selectedSpell!.name
                            : 'Tap a tile to target')
                      : 'Choose a spell, Dash, or Meditate',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: 'serif',
                    fontSize: 13,
                    color: selecting
                        ? kParchmentColor.withValues(alpha: 0.90)
                        : kInkMutedColor,
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
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          _ActionButton(
            label: 'CAST',
            color: kIlluminationGold,
            enabled: selecting && hasTarget && !isBusy,
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
    final name = avatar.playerId.length > 10
        ? '${avatar.playerId.substring(0, 9)}…'
        : avatar.playerId;

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
        ],
      ),
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

// ── Artifact row ──────────────────────────────────────────────────────────────

class _ArtifactRow extends StatelessWidget {
  const _ArtifactRow({required this.avatar});

  final WizardAvatar? avatar;

  int _count(AccoutrementKind kind) =>
      avatar?.accoutrements.where((a) => a.kind == kind).length ?? 0;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF221508),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          for (final entry in _kArtifacts)
            _ArtifactChip(
              icon: entry.$2,
              color: entry.$3,
              count: _count(entry.$1),
              label: entry.$4,
            ),
        ],
      ),
    );
  }
}

class _ArtifactChip extends StatelessWidget {
  const _ArtifactChip({
    required this.icon,
    required this.color,
    required this.count,
    required this.label,
  });

  final IconData icon;
  final Color color;
  final int count;
  final String label;

  @override
  Widget build(BuildContext context) {
    final active = count > 0;
    final fg = active ? color : kInkMutedColor.withValues(alpha: 0.35);

    return Column(
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
    );
  }
}

// ── Spell book ────────────────────────────────────────────────────────────────

class _SpellBook extends StatelessWidget {
  const _SpellBook({
    required this.spells,
    required this.selectedId,
    required this.onSelect,
    required this.onView,
  });

  final List<SpellAsset?> spells;
  final String? selectedId;
  final void Function(SpellAsset) onSelect;
  final void Function(SpellAsset) onView;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 112,
      color: const Color(0xFF130C04),
      child: spells.isEmpty
          ? Center(
              child: Text(
                'No spells in chapter',
                style: manuscriptCaptionStyle(
                  color: kParchmentColor.withValues(alpha: 0.30),
                ),
              ),
            )
          : ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              itemCount: spells.length,
              itemBuilder: (_, i) {
                final spell = spells[i];
                if (spell == null) return const SizedBox(width: 6);
                final selected = spell.id == selectedId;
                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: GestureDetector(
                    onTap: () => onSelect(spell),
                    onLongPress: () => onView(spell),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          decoration: BoxDecoration(
                            border: selected
                                ? Border.all(color: kIlluminationGold, width: 2)
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
                            ],
                          ),
                        ),
                        const SizedBox(height: 3),
                        SizedBox(
                          width: 72,
                          child: Text(
                            spell.name.isNotEmpty ? spell.name : 'Unnamed',
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
                );
              },
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

    final label = isLocal
        ? 'YOUR STATUS'
        : '${avatar?.playerId ?? '?'} STATUS'.toUpperCase();

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
