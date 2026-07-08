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

import 'dart:math';

import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:flutter/material.dart';

import '../battle/engine/turn_loop.dart';
import '../battle/models/battle_state.dart';
import '../battle/models/barrier.dart';
import '../battle/models/casting_enhancements.dart';
import '../battle/models/effect_kind.dart'
    show SpellAffinity, formulaEffectLabels, kAffinityLabel;
import '../battle/models/hex_battlefield.dart' show hexDistance;
import '../battle/models/terrain.dart' show ImpassableTile, SlowTile;
import '../battle/models/status_effect_ids.dart';
import '../battle/models/wizard_avatar.dart';
import '../battle/networking/battle_session.dart';
import '../battle/networking/solo_battle_session.dart';
import '../engine/hex_grid.dart';
import '../sorcerer/vocal_score.dart';
import '../sorcerer/vocal_scorer.dart';
import '../spells/chapter_asset.dart';
import '../spells/spell_asset.dart';
import 'battlefield_painter.dart';
import 'manuscript_theme.dart';
import 'spell_card_painter.dart';
import 'spell_view_screen.dart';

enum _InputPhase { action, movement }

// ── Artifact display table ────────────────────────────────────────────────────

const _kArtifacts = [
  (AccoutrementKind.manaGem,       Icons.diamond_outlined,  Color(0xFF2B4D8C), 'Gems'),
  (AccoutrementKind.bookmark,      Icons.bookmark_outlined, Color(0xFF5588BB), 'Marks'),
  (AccoutrementKind.absorptionRod, Icons.shield_outlined,   Color(0xFF7A6040), 'Rods'),
  (AccoutrementKind.counterCharm,  Icons.block,             Color(0xFFB84040), 'Charms'),
];

// ── Status effect display tables ─────────────────────────────────────────────

const Map<String, String> _kStatusLabel = {
  StatusEffectId.speedUp:               'Speed+',
  StatusEffectId.speedDown:             'Speed−',
  StatusEffectId.highMobility:          'High Mob.',
  StatusEffectId.highLiquidity:         'High Liq.',
  StatusEffectId.rangeUp:               'Range+',
  StatusEffectId.rangeDown:             'Range−',
  StatusEffectId.penetrating:           'Piercing',
  StatusEffectId.turbulent:             'Turbulent',
  StatusEffectId.sluggish:              'Sluggish',
  StatusEffectId.quick:                 'Quick',
  StatusEffectId.nextSpellCostDouble:   '2× Cost',
  StatusEffectId.blind:                 'Blind',
  StatusEffectId.chainFast:             'Chain+',
  StatusEffectId.chainSlow:             'Chain−',
  StatusEffectId.statusDormant:         'Dormant',
  StatusEffectId.haymakerDot:           'Burning',
  StatusEffectId.haymakerSlow:          'Slowed',
  StatusEffectId.haymakerStatusDrain:   'Drained',
  StatusEffectId.haymakerDistanceBonus: 'Charging',
  StatusEffectId.revealCounterCharms:   'See Charms',
  StatusEffectId.revealSpells:          'See Spells',
  StatusEffectId.revealTargetTile:      'See Target',
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

  // Turn interaction state — two phases: action then movement.
  _InputPhase      _phase         = _InputPhase.action;
  SpellAsset?      _selectedSpell;
  HexCoord?        _targetHex;    // spell target (action phase)
  TurnAction?      _pendingAction;
  List<HexCoord>   _movePath      = const []; // movement path (movement phase)
  bool             _isBusy        = false;

  // Status-effect inspection: null = show local player; non-null = show opponent.
  WizardAvatar?    _inspectedAvatar;

  // Battlefield geometry — tracked from LayoutBuilder so tap handler can convert
  double _hexSize   = 20;
  Offset _fieldCenter = Offset.zero;

  // ── Sorcerer mode ──────────────────────────────────────────────────────────
  VocalScorer?  _vocalScorer;
  double        _ambientFloorRms = 0.0;
  bool          _isCapturingVoice = false;
  VocalWord?    _capturingWord;

  /// Capture window for one incantation. Fixed for this pass — see
  /// VocalScorer's lifecycle doc (vocal_scorer.dart) for the begin/end contract.
  static const _voiceCaptureWindow = Duration(milliseconds: 2500);

  @override
  void initState() {
    super.initState();
    _loop = TurnLoop(
      state: widget.state,
      session: widget.session ?? SoloBattleSession(),
      localPlayerId: widget.localPlayerId,
      isSorcererMode: widget.state.config.sorcererMode,
    );
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat();
    _castAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
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
    _vocalScorer?.dispose();
    super.dispose();
  }

  Future<void> _loadSpells() async {
    final all = await SpellAsset.loadAll();
    if (!mounted) return;
    final byId = {for (final s in all) s.id: s};
    setState(() {
      _spells = widget.chapter.entries.map((e) => byId[e.spellId]).toList();
    });
  }

  WizardAvatar? get _local => widget.state.avatars
      .cast<WizardAvatar?>()
      .firstWhere(
        (a) => a?.playerId == widget.localPlayerId,
        orElse: () => null,
      );

  List<WizardAvatar> get _opponents => widget.state.avatars
      .where((a) => a.playerId != widget.localPlayerId)
      .toList();

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
    final byWidth  = available.width  / (3 * radius + 2);
    final byHeight = available.height / (sqrt(3) * (2 * radius + 1));
    return min(byWidth, byHeight).clamp(6.0, 36.0);
  }

  // ── Helpers ─────────────────────────────────────────────────────────────────

  bool _isValidHex(HexCoord hex) {
    final r = widget.state.config.gridRadius;
    return hex.q.abs() <= r && hex.r.abs() <= r && (hex.q + hex.r).abs() <= r;
  }

  void _resetTurn() {
    _phase          = _InputPhase.action;
    _selectedSpell  = null;
    _targetHex      = null;
    _pendingAction  = null;
    _movePath       = const [];
    _isBusy         = false;
  }

  // ── Action phase ─────────────────────────────────────────────────────────────

  void _selectSpell(SpellAsset spell) {
    if (_isBusy || _phase != _InputPhase.action) return;
    setState(() {
      _selectedSpell = _selectedSpell?.id == spell.id ? null : spell;
      if (_selectedSpell == null) _targetHex = null;
    });
  }

  /// Confirm the action and advance to the movement phase.
  void _commitAction(TurnAction action) {
    setState(() {
      _pendingAction = action;
      _phase         = _InputPhase.movement;
      _movePath      = const [];
    });
  }

  void _onPass() => _commitAction(PassAction());

  Future<void> _onCast() async {
    final spell  = _selectedSpell;
    final target = _targetHex;
    if (spell == null || target == null) return;

    final scorer = _vocalScorer;
    final word = spell.formula.isNotEmpty
        ? VocalWord.fromAffinityZone(spell.formula.first)
        : null;
    if (!widget.state.config.sorcererMode || scorer == null || word == null) {
      // Wizard mode, or sorcerer mode before calibration finishes, or a
      // formula with no recognised primary affinity (e.g. wild magic) — cast
      // with no vocal component rather than block the player.
      _commitAction(SpellCastAction(spell: spell, targetHex: target));
      return;
    }

    setState(() {
      _isCapturingVoice = true;
      _capturingWord    = word;
    });
    await scorer.beginCapture(word);
    await Future<void>.delayed(_voiceCaptureWindow);
    final vocalScore = await scorer.endCapture(ambientFloorRms: _ambientFloorRms);
    if (!mounted) return;
    setState(() {
      _isCapturingVoice = false;
      _capturingWord    = null;
    });

    if (kDebugMode) {
      // Mirrors exactly what TurnLoop will independently (re)compute from
      // this same VocalScore at commit time and at resolution — see
      // CastingEnhancements.fromSorcererQuality's determinism note.
      final enhancements = CastingEnhancements.fromSorcererQuality(
        vocalScore: vocalScore,
        hasPotentLoadout: false,
        hasVelocityLoadout: false,
      );
      final q = (vocalScore.pronunciationU8 + vocalScore.volumeU8) / (2 * 254.0);
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

    _commitAction(SpellCastAction(spell: spell, targetHex: target, vocalScore: vocalScore));
  }

  // ── Movement phase ────────────────────────────────────────────────────────────

  void _onStay() => _submitTurn(_pendingAction!, movePath: const []);

  void _onConfirmMove() {
    if (_movePath.isEmpty) return;
    _submitTurn(_pendingAction!, movePath: _movePath);
  }

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
    final isOpponent = occupant != null && occupant.playerId != widget.localPlayerId;
    setState(() => _inspectedAvatar = isOpponent ? occupant : null);
  }

  /// Clouds (Water-Fire) base effect: entities in a cloud's radius may only
  /// target/be targeted by adjacent entities. Returns 1 if [caster] is inside
  /// any cloud (or carries the lingering Earth-flavor restriction status), or
  /// if [hex] is inside any cloud; otherwise [caster]'s normal spell range.
  int _maxCastRange(WizardAvatar caster, HexCoord hex) {
    final casterBound = caster.activeStatusEffects
            .any((fx) => fx.effectTypeId == StatusEffectId.cloudBoundTargeting) ||
        widget.state.clouds.any((c) => hexDistance(caster.position, c.position) <= c.radius);
    final hexBound = widget.state.clouds.any((c) => hexDistance(hex, c.position) <= c.radius);
    return (casterBound || hexBound) ? 1 : caster.effectiveSpellRange;
  }

  // ── Battlefield tap ───────────────────────────────────────────────────────────

  void _onTapBattlefield(Offset localPos) {
    if (_isBusy) return;
    final hex = pixelToHex(localPos, _fieldCenter, _hexSize);
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
      final tip = _movePath.isEmpty ? origin : _movePath.last;

      // Tap the last step → undo it.
      if (_movePath.isNotEmpty && hex == _movePath.last) {
        setState(() => _movePath = _movePath.sublist(0, _movePath.length - 1));
        return;
      }
      // Tap origin while path is non-empty → clear path.
      if (hex == origin && _movePath.isNotEmpty) {
        setState(() => _movePath = const []);
        return;
      }
      // Next step must be adjacent to the current tip.
      if (hexDistance(tip, hex) != 1) return;
      // Must not be impassable.
      final tileEffect = widget.state.tileEffects[hex];
      if (tileEffect is ImpassableTile) return;
      // Must fit within remaining move budget.
      final budget = local.effectiveMoveSpeed;
      var spent = 0;
      for (final h in _movePath) {
        final e = widget.state.tileEffects[h];
        spent += 1 + (e is SlowTile ? e.extraMoveCost : 0);
      }
      final stepCost = 1 + (tileEffect is SlowTile ? tileEffect.extraMoveCost : 0);
      if (spent + stepCost > budget) return;

      setState(() => _movePath = [..._movePath, hex]);
    }

    // Always update inspection regardless of phase or action outcome.
    _updateInspection(hex);
  }

  // ── Turn submission ───────────────────────────────────────────────────────────

  Future<void> _submitTurn(TurnAction action, {List<HexCoord> movePath = const []}) async {
    if (_isBusy) return;
    setState(() => _isBusy = true);

    final input = TurnInput(action: action, movePath: movePath);

    try {
      await _loop.runTurn(input);
      if (!mounted) return;
      final casts = _loop.lastCastEvents
          .map((e) => CastAnimation(
                fromHex: e.fromHex,
                toHex:   e.toHex,
                color:   BattlefieldPainter.colorForAffinity(e.affinity),
              ))
          .toList();
      setState(() {
        _resetTurn();
        _castAnimations = casts;
      });
      if (casts.isNotEmpty) _castAnimController.forward(from: 0);
    } catch (e) {
      if (!mounted) return;
      setState(_resetTurn);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Turn error: $e')),
      );
    }
  }

  // ── Build ───────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final local  = _local;
    final config = widget.state.config;
    final foes   = _opponents;

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
          widget.state.turnNumber == 0 ? 'BATTLE' : 'TURN ${widget.state.turnNumber}',
          style: manuscriptHeaderStyle(fontSize: 18, color: kParchmentColor),
        ),
      ),
      body: Column(
        children: [
          // Opponent strip
          if (foes.isNotEmpty)
            _OpponentHudRow(avatars: foes, maxHp: config.playerHp),

          // Battlefield — tappable
          Expanded(
            child: LayoutBuilder(
              builder: (ctx, constraints) {
                final size  = Size(constraints.maxWidth, constraints.maxHeight);
                final hSize = _hexSizeFromConstraints(size, config.gridRadius);
                final center = Offset(size.width / 2, size.height / 2);
                // Store for tap handler (accessed on next frame — safe because
                // the values only change on resize, not during a turn).
                _hexSize    = hSize;
                _fieldCenter = center;
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapUp: (d) => _onTapBattlefield(d.localPosition),
                  child: CustomPaint(
                    painter: BattlefieldPainter(
                      radius:           config.gridRadius,
                      hexSize:          hSize,
                      occupancy:        widget.state.battlefield.occupancy,
                      localPlayerId:    widget.localPlayerId,
                      highlightHex:     _targetHex,
                      movePath:         _movePath,
                      spellRangeRadius: _selectedSpell != null && _local != null
                          ? _maxCastRange(_local!, _local!.position) : 0,
                      casterPos:        _local?.position,
                      minions:          widget.state.minions.where((m) => m.isAlive).toList(),
                      localTeamId:      _local?.teamId,
                      barrierRings:     _barrierRings(),
                      pulseAnimation:   _pulseController,
                      castAnimations:   _castAnimations,
                      castAnimation:    _castAnimController,
                    ),
                    child: const SizedBox.expand(),
                  ),
                );
              },
            ),
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
                style: manuscriptHeaderStyle(fontSize: 16, color: kParchmentColor),
              ),
            ),

          // Action bar
          _ActionBar(
            phase:          _phase,
            selectedSpell:  _selectedSpell,
            hasTarget:      _targetHex != null,
            movePathLength: _movePath.length,
            isBusy:         _isBusy || _isCapturingVoice,
            onPass:         _onPass,
            onCast:         _onCast,
            onCancel:       () => setState(() {
              _selectedSpell = null;
              _targetHex     = null;
            }),
            onStay:        _onStay,
            onConfirmMove: _onConfirmMove,
            onCancelMove:  () => setState(() => _movePath = const []),
          ),

          // Player HP / MP bars
          if (local != null)
            _PlayerHud(avatar: local, maxHp: config.playerHp),

          // Status effects — local player by default; opponent when inspecting
          _StatusEffectPanel(
            avatar:     _inspectedAvatar ?? local,
            isLocal:    _inspectedAvatar == null,
          ),

          // Artifact counts
          _ArtifactRow(avatar: local),

          // Spell hand
          _SpellBook(
            spells:    _spells,
            selectedId: _selectedSpell?.id,
            onSelect:  _selectSpell,
            onView:    (spell) => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => SpellViewScreen(spell: spell)),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Action bar ────────────────────────────────────────────────────────────────

class _ActionBar extends StatelessWidget {
  const _ActionBar({
    required this.phase,
    required this.selectedSpell,
    required this.hasTarget,
    required this.movePathLength,
    required this.isBusy,
    required this.onPass,
    required this.onCast,
    required this.onCancel,
    required this.onStay,
    required this.onConfirmMove,
    required this.onCancelMove,
  });

  final _InputPhase phase;
  final SpellAsset? selectedSpell;
  final bool hasTarget;
  final int movePathLength;
  final bool isBusy;
  final VoidCallback onPass;
  final VoidCallback onCast;
  final VoidCallback onCancel;
  final VoidCallback onStay;
  final VoidCallback onConfirmMove;
  final VoidCallback onCancelMove;

  @override
  Widget build(BuildContext context) {
    if (phase == _InputPhase.movement) {
      return Container(
        color: const Color(0xFF0F0804),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            _ActionButton(
              label: 'STAY',
              color: kInkMutedColor,
              enabled: !isBusy,
              onTap: onStay,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                movePathLength > 0
                    ? '$movePathLength step${movePathLength == 1 ? '' : 's'}'
                        ' — tap last to undo'
                    : 'Tap an adjacent tile to step',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: 'serif',
                  fontSize: 13,
                  color: movePathLength > 0
                      ? kParchmentColor.withValues(alpha: 0.90)
                      : kInkMutedColor,
                  fontStyle:
                      movePathLength > 0 ? FontStyle.normal : FontStyle.italic,
                ),
              ),
            ),
            const SizedBox(width: 8),
            _ActionButton(
              label: 'MOVE',
              color: const Color(0xFF3A7FCC),
              enabled: movePathLength > 0 && !isBusy,
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
          if (!selecting)
            _ActionButton(
              label: 'PASS',
              color: kInkMutedColor,
              enabled: !isBusy,
              onTap: onPass,
            )
          else
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
                      ? (hasTarget ? selectedSpell!.name : 'Tap a tile to target')
                      : 'Choose a spell or pass',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: 'serif',
                    fontSize: 13,
                    color: selecting
                        ? kParchmentColor.withValues(alpha: 0.90)
                        : kInkMutedColor,
                    fontStyle: selecting && !hasTarget ? FontStyle.italic : FontStyle.normal,
                  ),
                ),
                if (selecting) ...[
                  const SizedBox(height: 2),
                  Text(
                    formulaEffectLabels(selectedSpell!.formula).join('  ·  '),
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
            Expanded(child: _OpponentChip(avatar: avatars[i], maxHp: maxHp)),
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
    final hpFrac   = maxHp > 0 ? (avatar.hp / maxHp).clamp(0.0, 1.0) : 0.0;
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
        _ThinBar(fraction: hpFrac,   color: const Color(0xFF8B1E1E), label: '${avatar.hp}'),
        const SizedBox(height: 2),
        _ThinBar(fraction: manaFrac, color: const Color(0xFF2B4D8C), label: '${avatar.mana}'),
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
    final hpFrac   = maxHp > 0 ? (avatar.hp / maxHp).clamp(0.0, 1.0) : 0.0;
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
              icon:  entry.$2,
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
    final fg     = active ? color : kInkMutedColor.withValues(alpha: 0.35);

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
                          child: SpellCardWidget(spell: spell, size: 72),
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
                              barrier: barriers[i].value),
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
    final name   = _kStatusLabel[fx.effectTypeId] ?? fx.effectTypeId;
    final isBuff = _kBuffIds.contains(fx.effectTypeId);
    final base   = fx.isDormant
        ? kInkMutedColor
        : (isBuff ? const Color(0xFF3A7A3A) : const Color(0xFF8A3030));
    final alpha  = fx.isDormant ? 0.45 : 0.90;

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
