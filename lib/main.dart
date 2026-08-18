import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/gestures.dart' show DragStartBehavior, PointerDeviceKind;
import 'package:flutter/material.dart' hide Element;
import 'package:flutter/services.dart' show rootBundle;
import 'engine/border_zone.dart';
import 'engine/ca_rules.dart';
import 'engine/ca_run.dart' show activeZoneFor, advanceDominance, gridGeometry, isSupreme;
import 'engine/element.dart';
import 'engine/formula.dart';
import 'engine/hex_grid.dart';
import 'engine/stepper.dart';
import 'battle/models/creature_spec.dart'
    show CreatureSpec, SummonAbility, summonSummaryLabel;
import 'battle/models/effect_kind.dart' show formulaTripletKind;
import 'audio/spell_sound_player.dart' show SpellSoundPlayer;
import 'audio/spell_sound_settings.dart' show SpellSoundSettings;
import 'identity/identity.dart';
import 'spells/inscribe.dart';
import 'spells/recipe_book.dart';
import 'spells/spell_art_import.dart'
    show SpellArtBytes, SpellArtImportException, importSpellArt;
import 'spells/spell_art_io.dart' show pickSpellArtFile;
import 'spells/spell_art_pack.dart' show kPainterlyPack;
import 'spells/spell_art_store.dart' show SpellArtStore;
import 'spells/spell_asset.dart';
import 'spells/spell_sound_import.dart'
    show SpellSoundBytes, SpellSoundImportException, importSpellSound;
import 'spells/spell_sound_io.dart' show pickSpellSoundFile;
import 'spells/spell_sound_pack.dart' show kSpellSoundPack, loadPackSound;
import 'spells/spell_sound_store.dart' show SpellSoundStore;
import 'ui/formula_bar.dart';
import 'ui/hex_grid_painter.dart';
import 'ui/app_root.dart';
import 'ui/recipes_screen.dart';
import 'ui/manuscript_theme.dart';
import 'ui/spell_art_pack_screen.dart' show pickSpellArtPackIcon, suggestedElementFor;
import 'ui/spell_card_painter.dart' show SpellCardWidget;
import 'ui/spell_sound_pack_screen.dart' show pickSpellSoundPackClip;
import 'src/rust/frb_generated.dart';

// M2 spike: async main to init the Rust FFI bridge.
// Revert to: void main() => runApp(const RuneDuelApp());
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  runApp(const RuneDuelApp());
}

// Desktop dev builds (`flutter run -d linux`) otherwise can't drag-scroll
// horizontal lists like the battle spell tray -- MaterialScrollBehavior's
// default dragDevices excludes mouse/trackpad, touch-only.
class _AppScrollBehavior extends MaterialScrollBehavior {
  @override
  Set<PointerDeviceKind> get dragDevices => {
        PointerDeviceKind.touch,
        PointerDeviceKind.mouse,
        PointerDeviceKind.trackpad,
        PointerDeviceKind.stylus,
        PointerDeviceKind.unknown,
      };
}

class RuneDuelApp extends StatelessWidget {
  const RuneDuelApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Runewright',
      debugShowCheckedModeBanner: false,
      scrollBehavior: _AppScrollBehavior(),
      theme: ThemeData.light().copyWith(
        scaffoldBackgroundColor: const Color(0xFFF5F0E8),
        colorScheme: const ColorScheme.light(
          primary: Color(0xFF2C1810),
          surface: Color(0xFFF5F0E8),
        ),
      ),
      // Step 1: first-boot identity bootstrap. AppRoot checks for an
      // existing Runekey and routes to MenuScreen or onboarding
      // (docs/step1_identity_onboarding_brief.md). The M2/M3/M4 diagnostic
      // screens (SpikeScreen, GateScreen) are still in ui/ if needed for
      // debugging -- the M4 two-device gate harness passed ACCEPTED on
      // real hardware on both sides (docs/M4_findings.md M4.6); swap this
      // back temporarily if it needs re-running.
      home: const AppRoot(),
    );
  }
}

class GameScreen extends StatefulWidget {
  const GameScreen({super.key, this.loadedSpell});

  /// When non-null, the screen opens with this spell's simulation replayed to
  /// its inscription state (T steps from the initial grid). Revert returns to
  /// the initial grid so the player can modify and re-inscribe.
  final SpellAsset? loadedSpell;

  @override
  State<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends State<GameScreen>
    with TickerProviderStateMixin {
  static const _innerRadius = 8;
  static const _radius = 12; // inscribable 0-8, buffer 9-11, border 12

  // Single source of truth for auto-run pacing: the ink growth/shrink
  // animation is pinned to half a step, so changing this alone keeps them
  // in sync.
  static const _stepMillis = 1000;
  static const _stepInterval = Duration(milliseconds: _stepMillis);
  static const _growthDuration = Duration(milliseconds: _stepMillis ~/ 2);

  late HexGrid _grid;
  late CARules _rules;
  final _paintKey = GlobalKey();
  bool _running = false;
  bool _inscribing = false;
  Timer? _timer;
  HexGrid? _initialGrid;
  // Grid state from just before the most recent step, retained only so the
  // painter can animate lines/dots growing or shrinking into `_grid`. Null
  // whenever the change wasn't a step (manual edit, revert, reset, load).
  HexGrid? _previousGrid;
  final _formulaTracker = FormulaTracker();
  final _supremeElements = <String>{};

  // Name/art/sound picked from the Preview screen, ahead of inscription --
  // see _SpellDraft's header comment. Carried into _inscribe() so those
  // picks "transfer" onto the SpellAsset it creates.
  _SpellDraft _draft = const _SpellDraft();

  // Rune Craft mode: whether the next inscription reads this grid's element
  // sequence as an incantation effect (default) or a summoned creature (see
  // CreatureSpec.fromElements) -- design doc "Summons". Personality (design
  // doc "Personalities") is no longer chosen here -- it's picked per-chapter
  // when the summon is added to a Chapter, not at inscribe time (see
  // library_screen.dart's _pickSummonPersonality).
  bool _isSummonMode = false;

  // How many of _formulaTracker.formulas we've already reported to the
  // RecipeBook -- lets _recordNewFormulas() process only newly-completed
  // groups instead of re-marking everything on every step.
  int _recordedFormulaCount = 0;

  // Summon abilities already reported to the RecipeBook this session (see
  // _recordNewAbilities) -- abilities are pattern-matched over the whole
  // sequence so far, not the last-committed group, so a plain set diff
  // (rather than a count) avoids re-marking an ability every step once found.
  final _recordedAbilities = <SummonAbility>{};

  late AnimationController _flickerCtrl;
  late AnimationController _growthCtrl;
  late Animation<double> _growth;
  Set<HexCoord> _activatedCells = {};

  // Tracks the previous touch point during a drag-to-draw gesture on the
  // grid, so onPanUpdate can interpolate between samples and activate every
  // cell the finger crossed rather than just the ones landed on exactly.
  Offset? _lastDragPosition;

  @override
  void initState() {
    super.initState();
    _flickerCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 750),
    );
    _flickerCtrl.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        setState(() => _activatedCells = {});
      }
    });
    _growthCtrl = AnimationController(
      vsync: this,
      duration: _growthDuration,
    );
    _growth = CurvedAnimation(parent: _growthCtrl, curve: Curves.easeOutCubic);
    final spell = widget.loadedSpell;
    if (spell != null) {
      _isSummonMode = spell.isSummon;
      _initialGrid = HexGrid.fromPackedState(spell.initialGrid, _radius);
      _grid = _initialGrid!.copy();
      _rules = CARules.neutral;
      for (int gen = 0; gen < spell.t; gen++) {
        final next = CAStep.step(_grid, _rules);
        final dom = advanceDominance(_rules, next);
        if (dom.isSupreme) {
          final zone = FormulaTracker.zoneFor(dom.dominant);
          if (zone != null) _supremeElements.add(zone.name);
        }
        _formulaTracker.step(
          FormulaTracker.zoneFor(dom.dominant),
          supremeDominant: dom.isSupreme,
        );
        _grid = next;
        _rules = dom.rule;
      }
      _recordNewFormulas();
      _recordNewAbilities();
    } else {
      _grid = HexGrid(_radius);
      _rules = CARules.neutral;
    }
  }

  double _hexSize(Size available) {
    const padding = 16.0;
    final byWidth = (available.width - padding) / (3 * _radius + 2);
    final byHeight = (available.height - padding) / (sqrt(3) * (2 * _radius + 1));
    return min(byWidth, byHeight).clamp(6.0, 40.0);
  }

  static bool _isOuter(HexCoord coord) =>
      [coord.q.abs(), coord.r.abs(), (coord.q + coord.r).abs()].reduce(max) >
      _innerRadius;

  // activeZone not needed for hit-testing.
  HexCoord? _hitTest(Offset localPosition, Size size) {
    final painter = HexGridPainter(
      grid: _grid,
      hexSize: _hexSize(size),
      innerRadius: _innerRadius,
    );
    return painter.pixelToHex(localPosition, size);
  }

  void _onTap(TapUpDetails details) {
    final box = _paintKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final coord = _hitTest(details.localPosition, box.size);
    if (coord == null) return;
    if (_isOuter(coord)) return;
    if (_grid.stepCount != 0) return;
    // Mutating a fresh copy (rather than `_grid.cells` in place) gives this
    // edit new HexGrid identity, matching every other grid mutation in this
    // file (step/reset/revert) — HexGridPainter.shouldRepaint relies on that
    // identity change to know the grid actually changed.
    setState(() {
      final next = _grid.copy();
      next.cells[coord] = next.cells[coord] == Element.dead
          ? Element.alive
          : Element.dead;
      _grid = next;
    });
  }

  void _onPanStart(DragStartDetails details) {
    _lastDragPosition = details.localPosition;
    _activateAlongPath(details.localPosition, details.localPosition);
  }

  void _onPanUpdate(DragUpdateDetails details) {
    final start = _lastDragPosition ?? details.localPosition;
    _activateAlongPath(start, details.localPosition);
    _lastDragPosition = details.localPosition;
  }

  void _onPanEnd(DragEndDetails details) {
    _lastDragPosition = null;
  }

  // Draw-to-activate: unlike a single tap (which toggles), dragging always
  // switches touched cells to alive, and samples along the segment between
  // the last and current touch point so a fast swipe doesn't leave gaps
  // between the hexes it visibly crossed.
  void _activateAlongPath(Offset start, Offset end) {
    if (_grid.stepCount != 0) return;
    final box = _paintKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final size = box.size;
    final hexSize = _hexSize(size);
    final distance = (end - start).distance;
    final steps = max(1, (distance / (hexSize / 3)).ceil());
    final touched = <HexCoord>{};
    for (var i = 0; i <= steps; i++) {
      final point = Offset.lerp(start, end, i / steps)!;
      final coord = _hitTest(point, size);
      if (coord != null && !_isOuter(coord)) touched.add(coord);
    }
    final toActivate = touched.where((c) => _grid.cells[c] != Element.alive);
    if (toActivate.isEmpty) return;
    // See _onTap: mutate a fresh copy so the grid gets new identity.
    setState(() {
      final next = _grid.copy();
      for (final coord in toActivate) {
        next.cells[coord] = Element.alive;
      }
      _grid = next;
    });
  }

  bool _gridsEqual(HexGrid a, HexGrid b) {
    for (final entry in a.cells.entries) {
      if (b.cells[entry.key] != entry.value) return false;
    }
    return true;
  }

  void _stepOnce() {
    // Hard stop at the largest inscribable tier: stepping past T=48 can
    // never be inscribed (kMaxInscribableSteps / tier_max), so the stepper
    // itself refuses rather than letting the grid wander past what Inscribe
    // will ever accept.
    if (_grid.stepCount >= kMaxInscribableSteps) return;
    _initialGrid ??= _grid.copy();
    final next = CAStep.step(_grid, _rules);
    final dominance = advanceDominance(_rules, next);
    final previous = _grid;
    setState(() {
      _previousGrid = previous;
      _grid = next;
      _rules = dominance.rule;
      if (dominance.isSupreme) {
        final zone = FormulaTracker.zoneFor(dominance.dominant);
        if (zone != null) _supremeElements.add(zone.name);
      }
      _formulaTracker.step(
        FormulaTracker.zoneFor(dominance.dominant),
        supremeDominant: dominance.isSupreme,
      );
      if (next.lastActivatedBorderCells.isNotEmpty) {
        _activatedCells = next.lastActivatedBorderCells;
      }
    });
    _recordNewFormulas();
    _recordNewAbilities();
    _triggerFlicker(next);
    _growthCtrl.forward(from: 0.0);
  }

  void _toggleRun() {
    if (_running) {
      _timer?.cancel();
      setState(() => _running = false);
    } else {
      // Same hard stop as _stepOnce: never run past the largest inscribable
      // tier.
      if (_grid.stepCount >= kMaxInscribableSteps) return;
      _initialGrid ??= _grid.copy();
      setState(() => _running = true);
      _timer = Timer.periodic(_stepInterval, (_) {
        final next = CAStep.step(_grid, _rules);
        if (_gridsEqual(_grid, next) || next.stepCount >= kMaxInscribableSteps) {
          _timer?.cancel();
          setState(() => _running = false);
          if (_gridsEqual(_grid, next)) return;
        }
        final dominance = advanceDominance(_rules, next);
        final previous = _grid;
        setState(() {
          _previousGrid = previous;
          _grid = next;
          _rules = dominance.rule;
          if (dominance.isSupreme) {
            final zone = FormulaTracker.zoneFor(dominance.dominant);
            if (zone != null) _supremeElements.add(zone.name);
          }
          _formulaTracker.step(
            FormulaTracker.zoneFor(dominance.dominant),
            supremeDominant: dominance.isSupreme,
          );
          if (next.lastActivatedBorderCells.isNotEmpty) {
            _activatedCells = next.lastActivatedBorderCells;
          }
        });
        _recordNewFormulas();
        _recordNewAbilities();
        _triggerFlicker(next);
        _growthCtrl.forward(from: 0.0);
      });
    }
  }

  void _revert() {
    if (_initialGrid == null) return;
    _timer?.cancel();
    _flickerCtrl.stop();
    _growthCtrl.stop();
    setState(() {
      _grid = _initialGrid!.copy();
      _previousGrid = null;
      _rules = CARules.neutral;
      _running = false;
      _activatedCells = {};
      _formulaTracker.reset();
      _recordedFormulaCount = 0;
      _recordedAbilities.clear();
      _supremeElements.clear();
    });
  }

  void _reset() {
    _timer?.cancel();
    _flickerCtrl.stop();
    _growthCtrl.stop();
    setState(() {
      _grid = HexGrid(_radius);
      _previousGrid = null;
      _rules = CARules.neutral;
      _running = false;
      _initialGrid = null;
      _activatedCells = {};
      _formulaTracker.reset();
      _recordedFormulaCount = 0;
      _recordedAbilities.clear();
      _supremeElements.clear();
      _isSummonMode = false;
      _draft = const _SpellDraft();
    });
  }

  // Diffs _formulaTracker.formulas against _recordedFormulaCount and marks
  // any newly-completed groups as discovered in the RecipeBook -- called
  // after every _formulaTracker.step(), so a formula is recorded the moment
  // it completes, live during play, whether or not the spell is ever
  // inscribed.
  void _recordNewFormulas() {
    final formulas = _formulaTracker.formulas;
    if (formulas.length <= _recordedFormulaCount) return;
    final newKeys = <String>[];
    for (var i = _recordedFormulaCount; i < formulas.length; i++) {
      final (affinity, kind) = formulaTripletKind(formulas[i]);
      newKeys.add(recipeKey(affinity, kind));
    }
    _recordedFormulaCount = formulas.length;
    RecipeBook.markDiscovered(newKeys);
  }

  // Summon-mode counterpart to _recordNewFormulas: re-derives the creature
  // spec from the full committed sequence and marks any not-yet-seen
  // abilities as discovered. Only meaningful in Summon mode -- incantation
  // play never touches _recordedAbilities.
  void _recordNewAbilities() {
    if (!_isSummonMode) return;
    final spec = CreatureSpec.fromElements(_formulaTracker.committed);
    if (spec == null) return;
    final newAbilities = spec.abilities.difference(_recordedAbilities);
    if (newAbilities.isEmpty) return;
    _recordedAbilities.addAll(newAbilities);
    RecipeBook.markDiscovered(newAbilities.map(summonAbilityKey));
  }

  void _triggerFlicker(HexGrid next) {
    if (next.lastActivatedBorderCells.isNotEmpty) {
      _flickerCtrl.forward(from: 0.0);
    }
  }

  @override
  void dispose() {
    _flickerCtrl.dispose();
    _growthCtrl.dispose();
    _timer?.cancel();
    super.dispose();
  }

  /// The bottom bar's live "Mana Cost" readout during play -- just
  /// [_computeManaCost] over the grid/formula state as they stand right now.
  int get _manaCost => _computeManaCost(_initialGrid ?? _grid, _grid.stepCount);

  /// The mana cost [initialGrid] simulated for [steps] generations will
  /// actually be inscribed at -- shared by the live [_manaCost] readout,
  /// _inscribe(), and the Preview screen, so none of them ever quote a
  /// different number for the same spell.
  ///
  /// Base cost: 5 mana per line segment, 1 mana per isolated dot. Segments
  /// are maximal runs of ≥2 contiguous inscribable active cells per axis (3
  /// axes); dots are inscribable active cells with no active inscribable
  /// neighbours. Both are pure functions of the T=0 grid. Each step
  /// multiplies cost by 1.05 (growth rate); each *complete* formula effect
  /// (entries 4, 7, 10, …) multiplies cost by 1.5 -- a residual (in-progress,
  /// not-yet-complete) activation buys nothing, so effectCount is
  /// `formulas.length - 1`, not a raw activation count. This must match
  /// DeterministicResolution.wireBaseManaCost /
  /// PeerCastVerifier.certifiedBaseManaCost, which are what
  /// actually charge the caster and the opponent at cast time -- an earlier
  /// `(committed.length - 1) ~/ 3` form over-counted on any residual, so the
  /// live readout advertised a price ~1.5x what the duel deducted (and,
  /// worse, the two devices deducted different amounts; see M4_findings
  /// 2026-07-29).
  int _computeManaCost(HexGrid initialGrid, int steps) {
    final geo = gridGeometry(initialGrid);
    final effectCount = max(0, _formulaTracker.formulas.length - 1);
    return ((5 * geo.segmentCount + geo.dotCount) *
            pow(1.05, steps) *
            pow(1.5, effectCount))
        .round();
  }

  bool get _canInscribe =>
      !_running &&
      !_inscribing &&
      _initialGrid != null &&
      _grid.stepCount >= 1 &&
      _grid.stepCount <= kMaxInscribableSteps;

  /// Opens the full-screen preview of the spell card the current formula/
  /// mana cost/name would generate, with buttons to pick this spell's card
  /// art and resolution sound ahead of inscription. Available at any point
  /// during design, not just once inscribable -- picking art/sound doesn't
  /// depend on having stepped the grid at all.
  Future<void> _openPreview() async {
    final initialGrid = _initialGrid ?? _grid;
    final steps = _grid.stepCount;
    final geo = gridGeometry(initialGrid);
    final result = await Navigator.push<_SpellDraft>(
      context,
      MaterialPageRoute(
        builder: (_) => _SpellPreviewScreen(
          draft: _draft,
          formula: _formulaTracker.committed.map((z) => z.name).toList(),
          supremeTags: _supremeElements.toList(),
          isSummon: _isSummonMode,
          steps: steps,
          tier: tierForSteps(steps) ?? kInscribeTiers.first,
          manaCost: _computeManaCost(initialGrid, steps),
          segmentCount: geo.segmentCount,
          dotCount: geo.dotCount,
        ),
      ),
    );
    if (result != null && mounted) setState(() => _draft = result);
  }

  /// Writes this spell's draft art/sound (picked pre-inscription in
  /// Preview, held only in memory until now) into the real stores under
  /// [asset]'s real spellHashHex, and stamps the pointer fields onto it --
  /// the post-creation counterpart to library_screen.dart's
  /// _setCustomArtOnSpell/_choosePackArtOnSpell, run automatically right
  /// after inscription instead of from a library menu. Returns [asset]
  /// unchanged if no art/sound was picked.
  Future<SpellAsset> _applyDraftMediaTo(SpellAsset asset) async {
    var result = asset;
    if (_draft.artSource == SpellArtSource.builtIn && _draft.artPackId != null) {
      result = result.withPackArt(packId: _draft.artPackId!);
    } else if (_draft.artSource == SpellArtSource.localImport &&
        _draft.artImportBytes != null) {
      final art = _draft.artImportBytes!;
      await SpellArtStore.save(result.spellHashHex, full: art.full, thumb: art.thumb);
      result = result.withArt(hash: art.artHashHex, source: SpellArtSource.localImport);
    }
    if (_draft.soundSource == SpellSoundSource.builtIn && _draft.soundPackId != null) {
      result = result.withPackSound(packId: _draft.soundPackId!);
    } else if (_draft.soundSource == SpellSoundSource.localImport &&
        _draft.soundImportBytes != null) {
      final sound = _draft.soundImportBytes!;
      await SpellSoundStore.save(result.spellHashHex, sound.bytes);
      result = result.withSound(hash: sound.soundHashHex, source: SpellSoundSource.localImport);
    }
    if (!identical(result, asset)) await result.save();
    return result;
  }

  Future<void> _inscribe() async {
    if (!_canInscribe) return;

    // Prompt for the spell name before starting the non-cancellable prove,
    // pre-filled with whatever was typed into Preview (still editable here).
    // Personality (Summon mode) is no longer chosen here -- see
    // library_screen.dart's per-chapter personality picker.
    final details = await showDialog<_InscribeDetails>(
      context: context,
      builder: (_) => _SpellNameDialog(isSummon: _isSummonMode, initialName: _draft.name),
    );
    if (details == null || !mounted) return;
    final spellName = details.name;

    final initialGrid = _initialGrid!;
    final steps = _grid.stepCount;
    final geo = gridGeometry(initialGrid);
    final manaCost = _computeManaCost(initialGrid, steps);

    final status = ValueNotifier<String>('Preparing the loom…');
    setState(() => _inscribing = true);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _InscribingDialog(status: status),
    );

    try {
      final identity = await Identity.loadOrCreate();
      final asset = await inscribeSpell(
        initialGrid: initialGrid,
        steps: steps,
        identity: identity,
        manaCost: manaCost,
        segmentCount: geo.segmentCount,
        dotCount: geo.dotCount,
        name: spellName,
        formula: _formulaTracker.committed.map((z) => z.name).toList(),
        supremeTags: _supremeElements.toList(),
        isSummon: _isSummonMode,
        loadCircuitJson: rootBundle.loadString,
        loadVkBytes: (path) async => (await rootBundle.load(path)).buffer.asUint8List(),
        onProgress: (message) => status.value = message,
      );
      final finalAsset = await _applyDraftMediaTo(asset);
      if (!mounted) return;
      setState(() => _draft = const _SpellDraft());
      Navigator.of(context, rootNavigator: true).pop();
      await showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Spell Inscribed'),
          content: Text(
            '"${finalAsset.name}"\n\n'
            'Tier ${finalAsset.tier} · T=${finalAsset.t} · Mana ${finalAsset.manaCost}\n\n'
            'Bound to your Runekey and saved. '
            'It will now appear in your library.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('OK')),
          ],
        ),
      );
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      await showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Inscription Failed'),
          content: Text('$e'),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('OK')),
          ],
        ),
      );
    } finally {
      // Not disposing `status`: it's a local, transient ValueNotifier (no
      // native resources) that the dialog's ValueListenableBuilder has
      // already stopped listening to by the time we get here (the pop()
      // above removed it) -- avoids racing that listener's own teardown
      // during the route's exit animation.
      if (mounted) setState(() => _inscribing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final supremeZone = isSupreme(_rules, _grid) ? activeZoneFor(_rules) : null;
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Runewright',
          style: TextStyle(color: Color(0xFFF5F0E8), letterSpacing: 3),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          softWrap: false,
        ),
        backgroundColor: const Color(0xFF2C1810),
        iconTheme: const IconThemeData(color: Color(0xFFF5F0E8)),
        actions: [
          IconButton(
            icon: const Icon(Icons.menu_book),
            tooltip: _isSummonMode ? 'Abilities' : 'Recipes',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => RecipesScreen(isSummon: _isSummonMode),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.visibility_outlined),
            tooltip: 'Preview Card',
            onPressed: _inscribing ? null : _openPreview,
          ),
          IconButton(
            icon: const Icon(Icons.undo),
            tooltip: 'Revert',
            onPressed: (_initialGrid != null && !_inscribing) ? _revert : null,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Reset',
            onPressed: _inscribing ? null : _reset,
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: GestureDetector(
              onTapUp: _onTap,
              onPanStart: _onPanStart,
              onPanUpdate: _onPanUpdate,
              onPanEnd: _onPanEnd,
              // Default (DragStartBehavior.start) silently swallows the
              // pointer movement consumed while recognizing the gesture, so
              // the initial cell(s) under a fast swipe's first few pixels
              // never reach onPanStart/onPanUpdate. `.down` reports the true
              // touch-down position instead, closing that gap.
              dragStartBehavior: DragStartBehavior.down,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final size = Size(constraints.maxWidth, constraints.maxHeight);
                  final hexSize = _hexSize(size);
                  // The background (cell fills + grid lines) is static
                  // across a step's growth animation, so it's a separate
                  // painter/RepaintBoundary from the animated ink layer on
                  // top — it skips the ~45 frame repaints the ink layer's
                  // animation drives instead of being redrawn every frame.
                  return Stack(
                    children: [
                      Positioned.fill(
                        child: RepaintBoundary(
                          child: CustomPaint(
                            painter: HexGridBackgroundPainter(
                              grid: _grid,
                              hexSize: hexSize,
                              innerRadius: _innerRadius,
                            ),
                          ),
                        ),
                      ),
                      Positioned.fill(
                        child: RepaintBoundary(
                          child: CustomPaint(
                            key: _paintKey,
                            painter: HexGridPainter(
                              grid: _grid,
                              hexSize: hexSize,
                              innerRadius: _innerRadius,
                              activeZone: activeZoneFor(_rules),
                              activatedBorderCells: _activatedCells,
                              previousGrid: _previousGrid,
                              flicker: _flickerCtrl,
                              growth: _growth,
                            ),
                            child: const SizedBox.expand(),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 400),
            transitionBuilder: (child, animation) => SizeTransition(
              sizeFactor: animation,
              child: FadeTransition(opacity: animation, child: child),
            ),
            child: supremeZone != null
                ? _SupremeDominanceBanner(key: ValueKey(supremeZone), zone: supremeZone)
                : const SizedBox.shrink(key: ValueKey<BorderZone?>(null)),
          ),
          _ZoneCounters(activations: _grid.zoneActivations),
          _ModeBar(
            isSummon: _isSummonMode,
            onSelect: (v) => setState(() => _isSummonMode = v),
          ),
          _isSummonMode
              ? _SummonPreview(sequence: _formulaTracker.committed)
              : FormulaBar(
                  formulas: _formulaTracker.formulas,
                  residuals: _formulaTracker.residuals,
                  pendingZone: _formulaTracker.pendingZone,
                ),
          _RuleBar(
            selected: _rules,
            onSelect: (r) => setState(() => _rules = r),
          ),
          _BottomBar(
            running: _running,
            inscribing: _inscribing,
            onToggleRun: _toggleRun,
            onStepOnce: _stepOnce,
            onInscribe: _canInscribe ? _inscribe : null,
            stepCount: _grid.stepCount,
            manaCost: _manaCost,
          ),
        ],
      ),
    );
  }
}

class _BottomBar extends StatelessWidget {
  final bool running;
  final bool inscribing;
  final VoidCallback onToggleRun;
  final VoidCallback onStepOnce;
  final VoidCallback? onInscribe;
  final int stepCount;
  final int manaCost;

  bool get atMax => stepCount >= kMaxInscribableSteps;

  const _BottomBar({
    required this.running,
    required this.inscribing,
    required this.onToggleRun,
    required this.onStepOnce,
    required this.onInscribe,
    required this.stepCount,
    required this.manaCost,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF2C1810),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(
                atMax ? 'Step $stepCount (max)' : 'Step $stepCount',
                style: const TextStyle(
                  color: Color(0xFFB8A898),
                  fontSize: 13,
                  letterSpacing: 1,
                ),
              ),
              const SizedBox(width: 16),
              Text(
                'Mana Cost: $manaCost',
                style: const TextStyle(
                  color: Color(0xFF9BBFD4),
                  fontSize: 13,
                  letterSpacing: 1,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: (running || inscribing || atMax) ? null : onStepOnce,
                  icon: const Icon(Icons.navigate_next),
                  label: const Text('Step'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF5A3828),
                    foregroundColor: const Color(0xFFF5F0E8),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: (inscribing || (!running && atMax)) ? null : onToggleRun,
                  icon: Icon(running ? Icons.pause : Icons.play_arrow),
                  label: Text(running ? 'Pause' : 'Run'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF8B4513),
                    foregroundColor: const Color(0xFFF5F0E8),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: onInscribe,
                  icon: inscribing
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF2C1810)),
                        )
                      : const Icon(Icons.auto_awesome),
                  label: Text(inscribing ? 'Inscribing…' : 'Inscribe'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: kIlluminationGold,
                    foregroundColor: const Color(0xFF2C1810),
                    disabledBackgroundColor: const Color(0xFF6B5A3A),
                    disabledForegroundColor: const Color(0xFFB8A898),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Non-dismissible while-you-wait dialog shown during proving -- this can
/// take anywhere from a few seconds (tier 12) to ~30s (tier 48), per the M2
/// on-device spike measurements, plus a one-time SRS download on a fresh
/// device. [status] is updated live via [inscribeSpell]'s `onProgress`, so
/// the text here is accurate about which stage (and whether it needs a
/// connection) is currently running rather than a single static message.
class _InscribingDialog extends StatelessWidget {
  const _InscribingDialog({required this.status});

  final ValueListenable<String> status;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      content: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(color: kIlluminationGold),
          const SizedBox(width: 20),
          Expanded(
            child: ValueListenableBuilder<String>(
              valueListenable: status,
              builder: (context, message, _) => Text(message),
            ),
          ),
        ],
      ),
    );
  }
}

/// Result of [_SpellNameDialog]: the chosen name. Personality (Summon mode)
/// is no longer picked at inscribe time -- see library_screen.dart's
/// per-chapter personality picker, which binds it when the summon is added
/// to a Chapter instead.
class _InscribeDetails {
  const _InscribeDetails({required this.name});
  final String name;
}

class _SpellNameDialog extends StatefulWidget {
  const _SpellNameDialog({required this.isSummon, this.initialName = ''});

  final bool isSummon;

  /// Pre-fills the name field with whatever was typed into the Preview
  /// dialog's name field, so a name chosen there "transfers" to the final
  /// inscribed spell without having to be retyped -- still editable here,
  /// since this dialog is the one authoritative point where the name is
  /// actually committed.
  final String initialName;

  @override
  State<_SpellNameDialog> createState() => _SpellNameDialogState();
}

class _SpellNameDialogState extends State<_SpellNameDialog> {
  late final _ctrl = TextEditingController(text: widget.initialName);
  late bool _isEmpty = widget.initialName.trim().isEmpty;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _ctrl.text.trim();
    if (name.isNotEmpty) {
      Navigator.of(context).pop(_InscribeDetails(name: name));
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.isSummon ? 'Name Your Summon' : 'Name Your Spell'),
      content: TextField(
        controller: _ctrl,
        autofocus: true,
        decoration: const InputDecoration(hintText: 'Spell name'),
        textCapitalization: TextCapitalization.words,
        onChanged: (v) => setState(() => _isEmpty = v.trim().isEmpty),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: _isEmpty ? null : _submit,
          child: const Text('Inscribe'),
        ),
      ],
    );
  }
}

// ── Preview: art/sound/name chosen before inscription ───────────────────────
//
// The player can pick a spell's card art, resolution sound, and (a draft of)
// its name from the Preview screen, before ever paying the proving cost of
// Inscribe. None of this is persisted until the spell actually is inscribed
// -- there is no SpellAsset (and so no spellHashHex to key art/sound store
// blobs by) until then. _SpellDraft holds the in-progress picks entirely in
// memory; _GameScreenState._applyDraftMediaTo writes them into the real
// stores only after inscribeSpell() returns a real, saved SpellAsset.

/// In-progress art/sound/name picks for the spell currently being designed,
/// held by _GameScreenState and handed to (then returned from)
/// _SpellPreviewScreen. Deliberately not SpellAsset itself -- most of its
/// fields (commitment, proof, spellHash, owner) don't exist yet.
class _SpellDraft {
  const _SpellDraft({
    this.name = '',
    this.artSource,
    this.artHash,
    this.artPackId,
    this.artImportBytes,
    this.soundSource,
    this.soundHash,
    this.soundPackId,
    this.soundImportBytes,
  });

  final String name;

  final SpellArtSource? artSource;
  final String? artHash;
  final String? artPackId;

  /// Set (and [artHash]/[artSource] set to [SpellArtSource.localImport])
  /// when the player imported their own image rather than picking one from
  /// the built-in pack. Held in memory, not yet in [SpellArtStore] -- there
  /// is no spellHashHex to key it by until inscription.
  final SpellArtBytes? artImportBytes;

  final SpellSoundSource? soundSource;
  final String? soundHash;
  final String? soundPackId;
  final SpellSoundBytes? soundImportBytes;

  _SpellDraft withName(String name) => _SpellDraft(
        name: name,
        artSource: artSource,
        artHash: artHash,
        artPackId: artPackId,
        artImportBytes: artImportBytes,
        soundSource: soundSource,
        soundHash: soundHash,
        soundPackId: soundPackId,
        soundImportBytes: soundImportBytes,
      );

  _SpellDraft withPackArt({required String packId, required String hash}) => _SpellDraft(
        name: name,
        artSource: SpellArtSource.builtIn,
        artHash: hash,
        artPackId: packId,
        soundSource: soundSource,
        soundHash: soundHash,
        soundPackId: soundPackId,
        soundImportBytes: soundImportBytes,
      );

  _SpellDraft withImportedArt(SpellArtBytes art) => _SpellDraft(
        name: name,
        artSource: SpellArtSource.localImport,
        artHash: art.artHashHex,
        artImportBytes: art,
        soundSource: soundSource,
        soundHash: soundHash,
        soundPackId: soundPackId,
        soundImportBytes: soundImportBytes,
      );

  _SpellDraft withoutArt() => _SpellDraft(
        name: name,
        soundSource: soundSource,
        soundHash: soundHash,
        soundPackId: soundPackId,
        soundImportBytes: soundImportBytes,
      );

  _SpellDraft withPackSound({required String packId, required String hash}) => _SpellDraft(
        name: name,
        artSource: artSource,
        artHash: artHash,
        artPackId: artPackId,
        artImportBytes: artImportBytes,
        soundSource: SpellSoundSource.builtIn,
        soundHash: hash,
        soundPackId: packId,
      );

  _SpellDraft withImportedSound(SpellSoundBytes sound) => _SpellDraft(
        name: name,
        artSource: artSource,
        artHash: artHash,
        artPackId: artPackId,
        artImportBytes: artImportBytes,
        soundSource: SpellSoundSource.localImport,
        soundHash: sound.soundHashHex,
        soundImportBytes: sound,
      );

  _SpellDraft withoutSound() => _SpellDraft(
        name: name,
        artSource: artSource,
        artHash: artHash,
        artPackId: artPackId,
        artImportBytes: artImportBytes,
      );
}

/// Reserved key under which imported (not pack) draft art/sound bytes are
/// stashed in [SpellArtStore]/[SpellSoundStore] so the preview card can
/// resolve them through the same code path a real, inscribed spell uses
/// (spell_art_resolver.dart / spell_sound_resolver.dart both key off
/// SpellAsset.spellHashHex). Never a real spellHashHex (those are "0x" + 64
/// hex chars) so it can't collide; overwritten on every new import, and
/// migrated to the real spellHashHex by _applyDraftMediaTo on a successful
/// inscribe -- nothing ever reads it back out after that.
const String _kDraftMediaKey = 'runecraft-preview-draft';

/// Full-screen preview of the spell card the current formula/mana cost/name
/// would generate, with buttons to pick this (not-yet-inscribed) spell's
/// card art and resolution sound. Returns the (possibly updated) draft when
/// popped, via either the Done button or the back arrow.
class _SpellPreviewScreen extends StatefulWidget {
  const _SpellPreviewScreen({
    required this.draft,
    required this.formula,
    required this.supremeTags,
    required this.isSummon,
    required this.steps,
    required this.tier,
    required this.manaCost,
    required this.segmentCount,
    required this.dotCount,
  });

  final _SpellDraft draft;
  final List<String> formula;
  final List<String> supremeTags;
  final bool isSummon;
  final int steps;
  final int tier;
  final int manaCost;
  final int segmentCount;
  final int dotCount;

  @override
  State<_SpellPreviewScreen> createState() => _SpellPreviewScreenState();
}

class _SpellPreviewScreenState extends State<_SpellPreviewScreen> {
  late _SpellDraft _draft = widget.draft;
  late final _nameCtrl = TextEditingController(text: widget.draft.name);
  final _soundPlayer = SpellSoundPlayer(poolSize: 1);
  SpellSoundSettings _soundSettings = const SpellSoundSettings();

  @override
  void initState() {
    super.initState();
    SpellSoundSettings.load().then((s) {
      if (mounted) setState(() => _soundSettings = s);
    });
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _soundPlayer.dispose();
    super.dispose();
  }

  /// A stand-in SpellAsset for rendering only -- id/proof/commitment/owner
  /// are placeholders (see the header comment above _SpellDraft); every
  /// field SpellCardWidget/showSpellCardFullscreen actually read is real.
  SpellAsset get _previewSpell => SpellAsset(
        id: 'draft',
        createdAt: DateTime.now().toUtc(),
        tier: widget.tier,
        t: widget.steps,
        ownerPubkeyHex: '',
        manaCost: widget.manaCost,
        segmentCount: widget.segmentCount,
        dotCount: widget.dotCount,
        initialGrid: const [],
        proofBytes: Uint8List(0),
        name: _draft.name,
        commitmentHex: '',
        spellHashHex: _kDraftMediaKey,
        formula: widget.formula,
        supremeTags: widget.supremeTags,
        isSummon: widget.isSummon,
        artHash: _draft.artHash,
        artSource: _draft.artSource,
        artPackId: _draft.artPackId,
        soundHash: _draft.soundHash,
        soundSource: _draft.soundSource,
        soundPackId: _draft.soundPackId,
      );

  void _close() => Navigator.of(context).pop(_draft);

  Future<void> _chooseArt() async {
    final choice = await showModalBottomSheet<_MediaChoice>(
      context: context,
      backgroundColor: kParchmentColor,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.auto_awesome_outlined, color: kIlluminationGold),
              title: const Text('Choose from Art Pack'),
              onTap: () => Navigator.pop(ctx, _MediaChoice.pack),
            ),
            ListTile(
              leading: const Icon(Icons.image_outlined),
              title: const Text('Import an Image…'),
              onTap: () => Navigator.pop(ctx, _MediaChoice.import),
            ),
          ],
        ),
      ),
    );
    if (!mounted || choice == null) return;
    switch (choice) {
      case _MediaChoice.pack:
        await _choosePackArt();
      case _MediaChoice.import:
        await _importArt();
    }
  }

  Future<void> _choosePackArt() async {
    final packId = await pickSpellArtPackIcon(
      context,
      suggestedElement: suggestedElementFor(widget.formula),
    );
    if (packId == null || !mounted) return;
    final entry = kPainterlyPack.firstWhere((e) => e.id == packId);
    setState(() => _draft = _draft.withPackArt(packId: packId, hash: entry.sha256));
  }

  Future<void> _importArt() async {
    final Uint8List? source;
    try {
      source = await pickSpellArtFile();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not open the file picker: $e')));
      }
      return;
    }
    if (source == null) return; // player cancelled the picker

    if (mounted) {
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => const Center(child: CircularProgressIndicator(color: kIlluminationGold)),
      );
    }
    final SpellArtBytes art;
    try {
      art = await importSpellArt(source);
    } on SpellArtImportException catch (e) {
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
      }
      return;
    }
    await SpellArtStore.save(_kDraftMediaKey, full: art.full, thumb: art.thumb);
    if (mounted) Navigator.of(context, rootNavigator: true).pop();
    setState(() => _draft = _draft.withImportedArt(art));
  }

  Future<void> _chooseSound() async {
    final choice = await showModalBottomSheet<_MediaChoice>(
      context: context,
      backgroundColor: kParchmentColor,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.auto_awesome_outlined, color: kIlluminationGold),
              title: const Text('Choose from Sound Pack'),
              onTap: () => Navigator.pop(ctx, _MediaChoice.pack),
            ),
            ListTile(
              leading: const Icon(Icons.audiotrack_outlined),
              title: const Text('Import a Sound…'),
              onTap: () => Navigator.pop(ctx, _MediaChoice.import),
            ),
          ],
        ),
      ),
    );
    if (!mounted || choice == null) return;
    switch (choice) {
      case _MediaChoice.pack:
        await _choosePackSound();
      case _MediaChoice.import:
        await _importSound();
    }
  }

  Future<void> _choosePackSound() async {
    final packId = await pickSpellSoundPackClip(
      context,
      suggestedElement: suggestedElementFor(widget.formula),
    );
    if (packId == null || !mounted) return;
    final entry = kSpellSoundPack.firstWhere((e) => e.id == packId);
    setState(() => _draft = _draft.withPackSound(packId: packId, hash: entry.sha256));
  }

  Future<void> _importSound() async {
    final Uint8List? source;
    try {
      source = await pickSpellSoundFile();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not open the file picker: $e')));
      }
      return;
    }
    if (source == null) return; // player cancelled the picker

    final SpellSoundBytes sound;
    try {
      sound = await importSpellSound(source);
    } on SpellSoundImportException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
      }
      return;
    }
    await SpellSoundStore.save(_kDraftMediaKey, sound.bytes);
    setState(() => _draft = _draft.withImportedSound(sound));
  }

  Future<void> _playCurrentSound() async {
    final Uint8List? bytes;
    final bool normalized;
    if (_draft.soundSource == SpellSoundSource.builtIn && _draft.soundPackId != null) {
      bytes = await loadPackSound(_draft.soundPackId!);
      normalized = true;
    } else if (_draft.soundImportBytes != null) {
      bytes = _draft.soundImportBytes!.bytes;
      normalized = false;
    } else {
      return;
    }
    if (bytes == null || !mounted) return;
    await _soundPlayer.play(bytes, settings: _soundSettings, normalized: normalized);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope<_SpellDraft>(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) Navigator.of(context).pop(_draft);
      },
      child: Scaffold(
        backgroundColor: kParchmentColor,
        appBar: AppBar(
          backgroundColor: kParchmentColor,
          foregroundColor: kInkColor,
          elevation: 0,
          leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: _close),
          title: Text('Preview', style: manuscriptHeaderStyle(fontSize: 20)),
        ),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Center(
              child: SpellCardWidget(spell: _previewSpell, size: 220),
            ),
            const SizedBox(height: 8),
            Center(
              child: Text(
                'Step ${widget.steps} · Mana ${widget.manaCost} — tap the card to view it full-size',
                style: manuscriptCaptionStyle(color: kInkMutedColor),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _nameCtrl,
              decoration: const InputDecoration(labelText: 'Spell name'),
              textCapitalization: TextCapitalization.words,
              onChanged: (v) => setState(() => _draft = _draft.withName(v)),
            ),
            const SizedBox(height: 12),
            _MediaRow(
              icon: Icons.palette_outlined,
              title: 'Card Art',
              subtitle: switch (_draft.artSource) {
                SpellArtSource.builtIn => 'Art pack icon',
                SpellArtSource.localImport => 'Custom image',
                _ => 'None — uses the generated coat of arms',
              },
              onChoose: _chooseArt,
              onClear: _draft.artHash == null
                  ? null
                  : () => setState(() => _draft = _draft.withoutArt()),
            ),
            _MediaRow(
              icon: Icons.music_note_outlined,
              title: 'Resolution Sound',
              subtitle: switch (_draft.soundSource) {
                SpellSoundSource.builtIn => 'Sound pack clip',
                SpellSoundSource.localImport => 'Custom sound',
                _ => 'None — uses the elemental default',
              },
              onChoose: _chooseSound,
              onPlay: _draft.soundHash == null ? null : _playCurrentSound,
              onClear: _draft.soundHash == null
                  ? null
                  : () => setState(() => _draft = _draft.withoutSound()),
            ),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: _close,
              style: ElevatedButton.styleFrom(
                backgroundColor: kIlluminationGold,
                foregroundColor: kInkColor,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              child: const Text('Done'),
            ),
          ],
        ),
      ),
    );
  }
}

enum _MediaChoice { pack, import }

class _MediaRow extends StatelessWidget {
  const _MediaRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onChoose,
    this.onPlay,
    this.onClear,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onChoose;
  final VoidCallback? onPlay;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, color: kIlluminationGold),
      title: Text(title, style: manuscriptBodyStyle(fontSize: 15)),
      subtitle: Text(subtitle, style: manuscriptCaptionStyle(color: kInkMutedColor)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (onPlay != null)
            IconButton(icon: const Icon(Icons.play_arrow), tooltip: 'Play', onPressed: onPlay),
          if (onClear != null)
            IconButton(icon: const Icon(Icons.close), tooltip: 'Remove', onPressed: onClear),
          TextButton(onPressed: onChoose, child: const Text('Choose')),
        ],
      ),
    );
  }
}

/// Incantation/Summon toggle (design doc "Summons") -- chooses whether
/// _inscribe() reads this grid's element sequence as a 16-cell incantation
/// effect (default) or a summoned creature. Styled like _RuleBar's own
/// hand-rolled toggle row rather than a Material SegmentedButton, to match
/// the rest of this screen.
class _ModeBar extends StatelessWidget {
  final bool isSummon;
  final ValueChanged<bool> onSelect;

  const _ModeBar({required this.isSummon, required this.onSelect});

  Widget _button(String label, bool value) {
    final active = isSummon == value;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: TextButton(
        onPressed: active ? null : () => onSelect(value),
        style: TextButton.styleFrom(
          foregroundColor: active ? const Color(0xFFF5F0E8) : const Color(0xFF9A9488),
          backgroundColor: active ? const Color(0xFF5A3828) : Colors.transparent,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(4),
            side: BorderSide(
              color: active ? const Color(0xFF5A3828) : const Color(0xFF4A3020),
            ),
          ),
        ),
        child: Text(label, style: const TextStyle(fontSize: 12)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF1E0E08),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: [
          _button('Incantation', false),
          _button('Summon', true),
        ],
      ),
    );
  }
}

/// Live "what will this inscribe as" preview for Summon mode -- mirrors
/// FormulaBar's layout/colors so the two feel like the same UI element
/// swapping content, not a different screen. [sequence] is the full flat
/// activation list (FormulaTracker.committed already includes any residual).
class _SummonPreview extends StatelessWidget {
  final List<BorderZone> sequence;

  const _SummonPreview({required this.sequence});

  @override
  Widget build(BuildContext context) {
    final spec = CreatureSpec.fromElements(sequence);
    final zeroHp = spec != null && spec.stats.maxHp == 0;
    return Container(
      color: const Color(0xFF1E0E08),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const Text(
                'Summon',
                style: TextStyle(color: Color(0xFF9A9488), fontSize: 11, letterSpacing: 1),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  spec == null ? '— (void: nothing will be summoned)' : summonSummaryLabel(spec),
                  style: const TextStyle(color: Color(0xFFCCA870), fontSize: 11),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          if (zeroHp)
            const Padding(
              padding: EdgeInsets.only(top: 2),
              child: Text(
                '0 HP — creature will immediately perish upon summoning.',
                style: TextStyle(color: Color(0xFFD46A5A), fontSize: 11),
              ),
            ),
        ],
      ),
    );
  }
}

class _RuleBar extends StatelessWidget {
  final CARules selected;
  final ValueChanged<CARules> onSelect;

  static const _presets = [CARules.neutral, CARules.fire, CARules.earth, CARules.water, CARules.wind];

  const _RuleBar({required this.selected, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF1E0E08),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: _presets.map((r) {
          final active = r.name == selected.name;
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: TextButton(
              onPressed: active ? null : () => onSelect(r),
              style: TextButton.styleFrom(
                foregroundColor: active
                    ? const Color(0xFFF5F0E8)
                    : const Color(0xFF9A9488),
                backgroundColor: active
                    ? const Color(0xFF5A3828)
                    : Colors.transparent,
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(4),
                  side: BorderSide(
                    color: active
                        ? const Color(0xFF5A3828)
                        : const Color(0xFF4A3020),
                  ),
                ),
              ),
              child: Text(r.name, style: const TextStyle(fontSize: 12)),
            ),
          );
        }).toList(),
      ),
    );
  }
}

class _ZoneCounters extends StatelessWidget {
  final Map<BorderZone, int> activations;

  const _ZoneCounters({required this.activations});

  static const _zones = [
    (BorderZone.fire,  'Fire',  Color(0xFFCC3311)),
    (BorderZone.air,   'Air',   Color(0xFF6699BB)),
    (BorderZone.water, 'Water', Color(0xFF2255AA)),
    (BorderZone.earth, 'Earth', Color(0xFF7A5C28)),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF1E0E08),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: _zones.map((entry) {
          final (zone, label, color) = entry;
          final count = activations[zone] ?? 0;
          return Row(
            children: [
              Container(width: 10, height: 10, color: color),
              const SizedBox(width: 6),
              Text(
                '$label: $count',
                style: const TextStyle(
                  color: Color(0xFFB8A898),
                  fontSize: 12,
                ),
              ),
            ],
          );
        }).toList(),
      ),
    );
  }
}

class _SupremeDominanceBanner extends StatefulWidget {
  final BorderZone zone;
  const _SupremeDominanceBanner({super.key, required this.zone});

  @override
  State<_SupremeDominanceBanner> createState() => _SupremeDominanceBannerState();
}

class _SupremeDominanceBannerState extends State<_SupremeDominanceBanner>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _pulse;

  static const _colors = {
    BorderZone.fire:  Color(0xFFCC3311),
    BorderZone.air:   Color(0xFF6699BB),
    BorderZone.water: Color(0xFF2255AA),
    BorderZone.earth: Color(0xFF7A5C28),
  };

  static const _names = {
    BorderZone.fire:  'FIRE',
    BorderZone.air:   'AIR',
    BorderZone.water: 'WATER',
    BorderZone.earth: 'EARTH',
  };

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _pulse = CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = _colors[widget.zone]!;
    final name = _names[widget.zone]!;
    return AnimatedBuilder(
      animation: _pulse,
      builder: (context, _) {
        final t = _pulse.value;
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 6),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.07 + 0.13 * t),
            border: Border.symmetric(
              horizontal: BorderSide(
                color: color.withValues(alpha: 0.35 + 0.65 * t),
                width: 1,
              ),
            ),
            boxShadow: [
              BoxShadow(
                color: color.withValues(alpha: 0.45 * t),
                blurRadius: 14,
                spreadRadius: 0,
              ),
            ],
          ),
          child: Center(
            child: Text(
              '★  $name · SUPREME DOMINANCE  ★',
              style: TextStyle(
                color: Color.lerp(color, const Color(0xFFF5F0E8), 0.35 * t),
                fontSize: 11,
                fontWeight: FontWeight.bold,
                letterSpacing: 2.5,
              ),
            ),
          ),
        );
      },
    );
  }
}
