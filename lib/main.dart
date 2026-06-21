import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart' hide Element;
import 'package:flutter/services.dart' show rootBundle;
import 'engine/border_zone.dart';
import 'engine/ca_rules.dart';
import 'engine/element.dart';
import 'engine/formula.dart';
import 'engine/hex_grid.dart';
import 'engine/stepper.dart';
import 'identity/identity.dart';
import 'spells/inscribe.dart';
import 'ui/formula_bar.dart';
import 'ui/hex_grid_painter.dart';
import 'ui/app_root.dart';
import 'ui/manuscript_theme.dart' show kIlluminationGold;
import 'src/rust/frb_generated.dart';

// M2 spike: async main to init the Rust FFI bridge.
// Revert to: void main() => runApp(const RuneDuelApp());
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  runApp(const RuneDuelApp());
}

class RuneDuelApp extends StatelessWidget {
  const RuneDuelApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Rune Wright',
      debugShowCheckedModeBanner: false,
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
  const GameScreen({super.key});

  @override
  State<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends State<GameScreen> {
  static const _innerRadius = 8;
  static const _radius = 12; // inscribable 0-8, buffer 9-11, border 12

  HexGrid _grid = HexGrid(_radius);
  CARules _rules = CARules.neutral;
  final _paintKey = GlobalKey();
  bool _running = false;
  bool _inscribing = false;
  Timer? _timer;
  HexGrid? _initialGrid;
  final _formulaTracker = FormulaTracker();

  double _hexSize(Size available) {
    const padding = 16.0;
    final byWidth = (available.width - padding) / (3 * _radius + 2);
    final byHeight = (available.height - padding) / (sqrt(3) * (2 * _radius + 1));
    return min(byWidth, byHeight).clamp(6.0, 40.0);
  }

  static bool _isOuter(HexCoord coord) =>
      [coord.q.abs(), coord.r.abs(), (coord.q + coord.r).abs()].reduce(max) >
      _innerRadius;

  static const _zoneRules = {
    BorderZone.fire:  CARules.fire,
    BorderZone.air:   CARules.wind,
    BorderZone.water: CARules.water,
    BorderZone.earth: CARules.earth,
  };

  // Resolves the next active rule given the current rule and updated grid:
  //   - all counts zero  → neutral
  //   - one clear leader → that zone's rule
  //   - tied             → keep current
  static CARules _nextRules(CARules current, HexGrid grid) {
    final a = grid.zoneActivations;
    if (a.isEmpty || a.values.every((v) => v == 0)) return CARules.neutral;
    final maxCount = a.values.reduce(max);
    final leaders = a.entries.where((e) => e.value == maxCount).toList();
    if (leaders.length != 1) return current;
    return _zoneRules[leaders.first.key] ?? current;
  }

  // Returns the zone that has strictly more activations than all others combined,
  // or null if no such zone exists.
  static BorderZone? _supremeDominantZone(Map<BorderZone, int> activations) {
    if (activations.isEmpty) return null;
    final total = activations.values.fold(0, (a, b) => a + b);
    for (final entry in activations.entries) {
      if (entry.value * 2 > total) return entry.key;
    }
    return null;
  }

  // Returns the zone whose rules are currently active, or null for neutral.
  static BorderZone? _activeZone(CARules rules) {
    for (final entry in _zoneRules.entries) {
      if (entry.value.name == rules.name) return entry.key;
    }
    return null;
  }

  // Reduces the active zone's activation count by the current step count.
  static void _decayActiveZone(HexGrid grid, CARules rules) {
    final zone = _activeZone(rules);
    if (zone == null) return;
    final count = grid.zoneActivations[zone] ?? 0;
    grid.zoneActivations[zone] = max(0, count - grid.stepCount ~/ 2);
  }

  void _onTap(TapUpDetails details) {
    final box = _paintKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final size = box.size;
    final painter = HexGridPainter(
      grid: _grid,
      hexSize: _hexSize(size),
      innerRadius: _innerRadius,
    );
    final coord = painter.pixelToHex(details.localPosition, size); // activeZone not needed for hit-testing
    if (coord == null) return;
    if (_isOuter(coord)) return;
    if (_grid.stepCount != 0) return;
    setState(() {
      _grid.cells[coord] = _grid.cells[coord] == Element.dead
          ? Element.alive
          : Element.dead;
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
    _decayActiveZone(next, _rules);
    final newRules = _nextRules(_rules, next);
    final supremeZone = _supremeDominantZone(next.zoneActivations);
    setState(() {
      _grid = next;
      _rules = newRules;
      _formulaTracker.step(
        FormulaTracker.zoneFor(newRules),
        supremeDominant: supremeZone != null,
      );
    });
  }

  void _toggleRun() {
    if (_running) {
      _timer?.cancel();
      setState(() => _running = false);
    } else {
      _initialGrid ??= _grid.copy();
      setState(() => _running = true);
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        final next = CAStep.step(_grid, _rules);
        _decayActiveZone(next, _rules);
        if (_gridsEqual(_grid, next)) {
          _timer?.cancel();
          setState(() => _running = false);
          return;
        }
        final newRules = _nextRules(_rules, next);
        final supremeZone = _supremeDominantZone(next.zoneActivations);
        setState(() {
          _grid = next;
          _rules = newRules;
          _formulaTracker.step(
            FormulaTracker.zoneFor(newRules),
            supremeDominant: supremeZone != null,
          );
        });
      });
    }
  }

  void _revert() {
    if (_initialGrid == null) return;
    _timer?.cancel();
    setState(() {
      _grid = _initialGrid!.copy();
      _running = false;
      _formulaTracker.reset();
    });
  }

  void _reset() {
    _timer?.cancel();
    setState(() {
      _grid = HexGrid(_radius);
      _rules = CARules.neutral;
      _running = false;
      _initialGrid = null;
      _formulaTracker.reset();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  int get _manaCost {
    final base = _initialGrid != null
        ? _initialGrid!.cells.values.where((e) => e == Element.alive).length
        : _grid.cells.values.where((e) => e == Element.alive).length;
    return (base * pow(1.25, _grid.stepCount)).round();
  }

  bool get _canInscribe =>
      !_running &&
      !_inscribing &&
      _initialGrid != null &&
      _grid.stepCount >= 1 &&
      _grid.stepCount <= kMaxInscribableSteps;

  Future<void> _inscribe() async {
    if (!_canInscribe) return;
    final initialGrid = _initialGrid!;
    final steps = _grid.stepCount;
    final manaCost = _manaCost;

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
            'Tier ${asset.tier} · T=${asset.t} · Mana ${asset.manaCost}\n\n'
            'Bound to your Runekey and saved (${asset.proofBytes.length} bytes). '
            'It will appear in your library once that\'s built.',
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
    final supremeZone = _supremeDominantZone(_grid.zoneActivations);
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
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final size = Size(constraints.maxWidth, constraints.maxHeight);
                  return CustomPaint(
                    key: _paintKey,
                    painter: HexGridPainter(
                      grid: _grid,
                      hexSize: _hexSize(size),
                      innerRadius: _innerRadius,
                      activeZone: _activeZone(_rules),
                    ),
                    child: const SizedBox.expand(),
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
          FormulaBar(
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
