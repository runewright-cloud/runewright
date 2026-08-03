// SPDX-License-Identifier: GPL-3.0-or-later
//
// spell_view_screen.dart — read-only replay of an inscribed spell's CA
// simulation. The initial grid is reconstructed from SpellAsset.initialGrid,
// which is stored locally and never shared with opponents in battle. Only the
// proof bytes, commitment, T, and owner pubkey cross the wire during a duel.
// The player can step/run the CA and revert to the inscribed initial state.

import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart' hide Element;

import '../engine/border_zone.dart';
import '../engine/ca_rules.dart';
import '../engine/ca_run.dart' show activeZoneFor, advanceDominance, isSupreme;
import '../engine/element.dart';
import '../engine/formula.dart';
import '../engine/hex_grid.dart';
import '../engine/stepper.dart';
import '../spells/spell_asset.dart';
import 'formula_bar.dart';
import 'hex_grid_painter.dart';

class SpellViewScreen extends StatefulWidget {
  const SpellViewScreen({super.key, required this.spell});

  final SpellAsset spell;

  @override
  State<SpellViewScreen> createState() => _SpellViewScreenState();
}

class _SpellViewScreenState extends State<SpellViewScreen>
    with SingleTickerProviderStateMixin {
  static const _innerRadius = 8;
  static const _radius = 12;

  // Single source of truth for auto-run pacing: the ink growth/shrink
  // animation is pinned to half a step, so changing this alone keeps them
  // in sync.
  static const _stepMillis = 1000;
  static const _stepInterval = Duration(milliseconds: _stepMillis);
  static const _growthDuration = Duration(milliseconds: _stepMillis ~/ 2);

  late final HexGrid _initialGrid;
  late HexGrid _grid;
  // Grid state from just before the most recent step, retained only so the
  // painter can animate lines/dots growing or shrinking into `_grid`.
  HexGrid? _previousGrid;
  CARules _rules = CARules.neutral;
  bool _running = false;
  Timer? _timer;
  final _formulaTracker = FormulaTracker();
  final _paintKey = GlobalKey();

  late AnimationController _growthCtrl;
  late Animation<double> _growth;

  @override
  void initState() {
    super.initState();
    _initialGrid = HexGrid.fromPackedState(widget.spell.initialGrid, _radius);
    _grid = _initialGrid.copy();
    _growthCtrl = AnimationController(
      vsync: this,
      duration: _growthDuration,
    );
    _growth = CurvedAnimation(parent: _growthCtrl, curve: Curves.easeOutCubic);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _growthCtrl.dispose();
    super.dispose();
  }

  double _hexSize(Size available) {
    const padding = 16.0;
    final byWidth = (available.width - padding) / (3 * _radius + 2);
    final byHeight = (available.height - padding) / (sqrt(3) * (2 * _radius + 1));
    return min(byWidth, byHeight).clamp(6.0, 40.0);
  }

  bool _gridsEqual(HexGrid a, HexGrid b) {
    for (final entry in a.cells.entries) {
      if (b.cells[entry.key] != entry.value) return false;
    }
    return true;
  }

  void _stepOnce() {
    final next = CAStep.step(_grid, _rules);
    final dominance = advanceDominance(_rules, next);
    final previous = _grid;
    setState(() {
      _previousGrid = previous;
      _grid = next;
      _rules = dominance.rule;
      _formulaTracker.step(
        FormulaTracker.zoneFor(dominance.dominant),
        supremeDominant: dominance.isSupreme,
      );
    });
    _growthCtrl.forward(from: 0.0);
  }

  void _toggleRun() {
    if (_running) {
      _timer?.cancel();
      setState(() => _running = false);
    } else {
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
          _formulaTracker.step(
            FormulaTracker.zoneFor(dominance.dominant),
            supremeDominant: dominance.isSupreme,
          );
        });
        _growthCtrl.forward(from: 0.0);
      });
    }
  }

  void _revert() {
    _timer?.cancel();
    _growthCtrl.stop();
    setState(() {
      _grid = _initialGrid.copy();
      _previousGrid = null;
      _rules = CARules.neutral;
      _running = false;
      _formulaTracker.reset();
    });
  }

  int get _manaCost {
    final base =
        _initialGrid.cells.values.where((e) => e == Element.alive).length;
    final effectCount = max(0, (_formulaTracker.committed.length - 1) ~/ 3);
    return (base * pow(1.05, _grid.stepCount) * pow(1.5, effectCount)).round();
  }

  @override
  Widget build(BuildContext context) {
    final supremeZone = isSupreme(_rules, _grid) ? activeZoneFor(_rules) : null;
    final title =
        widget.spell.name.isNotEmpty ? widget.spell.name : 'Unnamed Spell';
    return Scaffold(
      appBar: AppBar(
        title: Text(
          title,
          style: const TextStyle(color: Color(0xFFF5F0E8), letterSpacing: 2),
        ),
        backgroundColor: const Color(0xFF2C1810),
        iconTheme: const IconThemeData(color: Color(0xFFF5F0E8)),
        actions: [
          IconButton(
            icon: const Icon(Icons.undo),
            tooltip: 'Revert to initial state',
            onPressed: _grid.stepCount > 0 ? _revert : null,
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final size = Size(constraints.maxWidth, constraints.maxHeight);
                return CustomPaint(
                  key: _paintKey,
                  painter: HexGridPainter(
                    grid: _grid,
                    hexSize: _hexSize(size),
                    innerRadius: _innerRadius,
                    activeZone: activeZoneFor(_rules),
                    previousGrid: _previousGrid,
                    growth: _growth,
                  ),
                  child: const SizedBox.expand(),
                );
              },
            ),
          ),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 400),
            transitionBuilder: (child, animation) => SizeTransition(
              sizeFactor: animation,
              child: FadeTransition(opacity: animation, child: child),
            ),
            child: supremeZone != null
                ? _SupremeDominanceBanner(
                    key: ValueKey(supremeZone), zone: supremeZone)
                : const SizedBox.shrink(key: ValueKey<BorderZone?>(null)),
          ),
          _ZoneCounters(activations: _grid.zoneActivations),
          FormulaBar(
            formulas: _formulaTracker.formulas,
            residuals: _formulaTracker.residuals,
            pendingZone: _formulaTracker.pendingZone,
          ),
          _ViewBottomBar(
            running: _running,
            onToggleRun: _toggleRun,
            onStepOnce: _stepOnce,
            stepCount: _grid.stepCount,
            manaCost: _manaCost,
          ),
        ],
      ),
    );
  }
}

// ── Bottom bar (Step + Run/Pause only, no Inscribe) ──────────────────────────

class _ViewBottomBar extends StatelessWidget {
  const _ViewBottomBar({
    required this.running,
    required this.onToggleRun,
    required this.onStepOnce,
    required this.stepCount,
    required this.manaCost,
  });

  final bool running;
  final VoidCallback onToggleRun;
  final VoidCallback onStepOnce;
  final int stepCount;
  final int manaCost;

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
                  onPressed: running ? null : onStepOnce,
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
                  onPressed: onToggleRun,
                  icon: Icon(running ? Icons.pause : Icons.play_arrow),
                  label: Text(running ? 'Pause' : 'Run'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF8B4513),
                    foregroundColor: const Color(0xFFF5F0E8),
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

// ── Zone counters (mirrors the widget in main.dart) ───────────────────────────

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

// ── Supreme dominance banner (mirrors the widget in main.dart) ────────────────

class _SupremeDominanceBanner extends StatefulWidget {
  final BorderZone zone;
  const _SupremeDominanceBanner({super.key, required this.zone});

  @override
  State<_SupremeDominanceBanner> createState() =>
      _SupremeDominanceBannerState();
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
