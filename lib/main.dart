import 'dart:async';
import 'dart:math';
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
import 'identity/identity.dart';
import 'spells/inscribe.dart';
import 'spells/recipe_book.dart';
import 'spells/spell_asset.dart';
import 'ui/formula_bar.dart';
import 'ui/hex_grid_painter.dart';
import 'ui/app_root.dart';
import 'ui/recipes_screen.dart';
import 'ui/manuscript_theme.dart' show kIlluminationGold;
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
      title: 'Rune Wright',
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
      _initialGrid ??= _grid.copy();
      setState(() => _running = true);
      _timer = Timer.periodic(_stepInterval, (_) {
        final next = CAStep.step(_grid, _rules);
        if (_gridsEqual(_grid, next)) {
          _timer?.cancel();
          setState(() => _running = false);
          return;
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

  int get _manaCost {
    final geo = gridGeometry(_initialGrid ?? _grid);
    // Base cost: 5 mana per line segment, 1 mana per isolated dot.
    // Segments are maximal runs of ≥2 contiguous inscribable active cells
    // per axis (3 axes). Dots are inscribable active cells with no active
    // inscribable neighbours. Both are pure functions of the T=0 grid.
    final base = 5 * geo.segmentCount + geo.dotCount;
    // Each step multiplies cost by 1.05 (unchanged growth rate).
    // Each new formula effect (entries 4, 7, 10, …) multiplies cost by 1.5.
    final effectCount = max(0, (_formulaTracker.committed.length - 1) ~/ 3);
    return (base * pow(1.05, _grid.stepCount) * pow(1.5, effectCount)).round();
  }

  bool get _canInscribe =>
      !_running &&
      !_inscribing &&
      _initialGrid != null &&
      _grid.stepCount >= 1 &&
      _grid.stepCount <= kMaxInscribableSteps;

  Future<void> _inscribe() async {
    if (!_canInscribe) return;

    // Prompt for the spell name before starting the non-cancellable prove.
    // Personality (Summon mode) is no longer chosen here -- see
    // library_screen.dart's per-chapter personality picker.
    final details = await showDialog<_InscribeDetails>(
      context: context,
      builder: (_) => _SpellNameDialog(isSummon: _isSummonMode),
    );
    if (details == null || !mounted) return;
    final spellName = details.name;

    final initialGrid = _initialGrid!;
    final steps = _grid.stepCount;
    final geo = gridGeometry(initialGrid);
    final effectCount = max(0, (_formulaTracker.committed.length - 1) ~/ 3);
    final manaCost = ((5 * geo.segmentCount + geo.dotCount) *
            pow(1.05, steps) *
            pow(1.5, effectCount))
        .round();

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
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      await showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Spell Inscribed'),
          content: Text(
            '"${asset.name}"\n\n'
            'Tier ${asset.tier} · T=${asset.t} · Mana ${asset.manaCost}\n\n'
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
          'Rune Wright',
          style: TextStyle(color: Color(0xFFF5F0E8), letterSpacing: 3),
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
                'Step $stepCount',
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
                  onPressed: (running || inscribing) ? null : onStepOnce,
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
                  onPressed: inscribing ? null : onToggleRun,
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
  const _SpellNameDialog({required this.isSummon});

  final bool isSummon;

  @override
  State<_SpellNameDialog> createState() => _SpellNameDialogState();
}

class _SpellNameDialogState extends State<_SpellNameDialog> {
  final _ctrl = TextEditingController();
  bool _isEmpty = true;

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
