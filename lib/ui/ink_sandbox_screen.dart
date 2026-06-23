// SPDX-License-Identifier: GPL-3.0-or-later
//
// ink_sandbox_screen.dart — standalone playtest sandbox for the neutral
// "magic ink" CA rules (InkStep). Throwaway feel-test tool: no ZK circuit,
// no FFI, no dominance/border-sink semantics, no commitment — see
// lib/engine/ink_step.dart. Deploy-and-patch; not part of the inscribe
// pipeline (lib/spells/inscribe.dart) at all.

import 'dart:async';

import 'package:flutter/material.dart' hide Element;

import '../engine/hex_grid.dart' show HexCoord;
import '../engine/ink_step.dart';
import 'ink_grid_painter.dart';
import 'manuscript_theme.dart';

class InkSandboxScreen extends StatefulWidget {
  const InkSandboxScreen({super.key});

  @override
  State<InkSandboxScreen> createState() => _InkSandboxScreenState();
}

class _InkSandboxScreenState extends State<InkSandboxScreen> {
  static const int _defaultRadius = 8;
  static const Duration _tickInterval = Duration(milliseconds: 400);

  int _radius = _defaultRadius;
  InkRules _rules = const InkRules();

  /// history[0] is the seed (generation 0); history[g] is generation g.
  List<Set<HexCoord>> _history = [<HexCoord>{}];
  int _currentGen = 0;
  bool _playing = false;
  Timer? _timer;

  Set<HexCoord> get _currentActive => _history[_currentGen];

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _pause() {
    _timer?.cancel();
    _timer = null;
    if (_playing) setState(() => _playing = false);
  }

  void _play() {
    if (_playing) return;
    setState(() => _playing = true);
    _timer = Timer.periodic(_tickInterval, (_) => _advance());
  }

  void _stepOnce() {
    _pause();
    _advance();
  }

  void _advance() {
    setState(() {
      if (_currentGen < _history.length - 1) {
        // Scrubbed back, then pressed play/step: just move forward through
        // already-computed history rather than recomputing.
        _currentGen++;
        return;
      }
      final next = InkStep.step(
        active: _history.last,
        radius: _radius,
        generation: _history.length,
        rules: _rules,
      );
      _history.add(next);
      _currentGen = _history.length - 1;
    });
  }

  void _reset() {
    _pause();
    setState(() {
      _history = [<HexCoord>{}];
      _currentGen = 0;
    });
  }

  void _setSeed(Set<HexCoord> seed) {
    _pause();
    setState(() {
      _history = [seed];
      _currentGen = 0;
    });
  }

  void _toggleCell(HexCoord coord) {
    _pause();
    setState(() {
      final seed = Set<HexCoord>.from(_history[0]);
      if (!seed.add(coord)) seed.remove(coord);
      _history = [seed];
      _currentGen = 0;
    });
  }

  void _setRadius(int radius) {
    if (radius == _radius) return;
    _pause();
    setState(() {
      _radius = radius;
      _history = [<HexCoord>{}];
      _currentGen = 0;
    });
  }

  int? get _borderContactGeneration =>
      InkStep.borderContactGeneration(_history, _radius);

  @override
  Widget build(BuildContext context) {
    final activeCount = _currentActive.length;
    final borderContact = _borderContactGeneration;

    return ParchmentScaffold(
      scrollable: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const ManuscriptBackButton(),
              const Spacer(),
              Text('INK SANDBOX', style: manuscriptHeaderStyle(fontSize: 20)),
              const Spacer(),
              const SizedBox(width: 48), // balances the back button
            ],
          ),
          const SizedBox(height: 8),
          _PresetBar(radius: _radius, onSelect: _setSeed),
          const SizedBox(height: 8),
          _RuleToggles(
            rules: _rules,
            onChanged: (r) => setState(() => _rules = r),
            radius: _radius,
            onRadiusChanged: _setRadius,
          ),
          const SizedBox(height: 8),
          Expanded(
            child: Center(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final hexSize =
                      (constraints.biggest.shortestSide / (2 * _radius + 2)) / 1.5;
                  final canvasSize = Size(constraints.maxWidth, constraints.maxHeight);
                  final painter = InkGridPainter(
                    radius: _radius,
                    active: _currentActive,
                    hexSize: hexSize,
                  );
                  return GestureDetector(
                    onTapUp: (details) {
                      final coord = painter.pixelToHex(details.localPosition, canvasSize);
                      if (coord != null) _toggleCell(coord);
                    },
                    child: CustomPaint(size: canvasSize, painter: painter),
                  );
                },
              ),
            ),
          ),
          const SizedBox(height: 8),
          _Readouts(
            generation: _currentGen,
            activeCount: activeCount,
            borderContact: borderContact,
          ),
          const SizedBox(height: 4),
          _Sparkline(counts: _history.map((s) => s.length).toList()),
          const SizedBox(height: 8),
          Slider(
            value: _currentGen.toDouble(),
            min: 0,
            max: (_history.length - 1).toDouble(),
            divisions: _history.length > 1 ? _history.length - 1 : null,
            label: 'Gen $_currentGen',
            activeColor: kIlluminationGold,
            onChanged: (v) {
              _pause();
              setState(() => _currentGen = v.round());
            },
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              OutlinedButton(onPressed: _reset, child: const Text('Reset')),
              OutlinedButton(onPressed: _stepOnce, child: const Text('Step')),
              OutlinedButton(
                onPressed: _playing ? _pause : _play,
                child: Text(_playing ? 'Pause' : 'Play'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Readouts extends StatelessWidget {
  const _Readouts({
    required this.generation,
    required this.activeCount,
    required this.borderContact,
  });

  final int generation;
  final int activeCount;
  final int? borderContact;

  @override
  Widget build(BuildContext context) {
    final style = manuscriptCaptionStyle().copyWith(fontStyle: FontStyle.normal);
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        Text('Generation: $generation', style: style),
        Text('Active cells: $activeCount', style: style),
        Text('Border contact: ${borderContact?.toString() ?? '—'}', style: style),
      ],
    );
  }
}

class _RuleToggles extends StatelessWidget {
  const _RuleToggles({
    required this.rules,
    required this.onChanged,
    required this.radius,
    required this.onRadiusChanged,
  });

  final InkRules rules;
  final ValueChanged<InkRules> onChanged;
  final int radius;
  final ValueChanged<int> onRadiusChanged;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 4,
      children: [
        _RuleChip(label: 'A: Gap-fill', value: rules.ruleA, onChanged: (v) => onChanged(rules.copyWith(ruleA: v))),
        _RuleChip(label: 'B: Tip ext.', value: rules.ruleB, onChanged: (v) => onChanged(rules.copyWith(ruleB: v))),
        _RuleChip(label: 'E: Serif', value: rules.ruleE, onChanged: (v) => onChanged(rules.copyWith(ruleE: v))),
        if (rules.ruleE)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('N=${rules.cadence}', style: manuscriptCaptionStyle()),
              IconButton(
                iconSize: 16,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(maxWidth: 24, maxHeight: 24),
                icon: const Icon(Icons.remove),
                onPressed: rules.cadence > 1
                    ? () => onChanged(rules.copyWith(cadence: rules.cadence - 1))
                    : null,
              ),
              IconButton(
                iconSize: 16,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(maxWidth: 24, maxHeight: 24),
                icon: const Icon(Icons.add),
                onPressed: () => onChanged(rules.copyWith(cadence: rules.cadence + 1)),
              ),
            ],
          ),
        const SizedBox(width: 12),
        Text('Radius:', style: manuscriptCaptionStyle()),
        IconButton(
          iconSize: 16,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(maxWidth: 24, maxHeight: 24),
          icon: const Icon(Icons.remove),
          onPressed: radius > 2 ? () => onRadiusChanged(radius - 1) : null,
        ),
        Text('$radius', style: manuscriptCaptionStyle()),
        IconButton(
          iconSize: 16,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(maxWidth: 24, maxHeight: 24),
          icon: const Icon(Icons.add),
          onPressed: radius < 16 ? () => onRadiusChanged(radius + 1) : null,
        ),
      ],
    );
  }
}

class _RuleChip extends StatelessWidget {
  const _RuleChip({required this.label, required this.value, required this.onChanged});

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return FilterChip(
      label: Text(label, style: const TextStyle(fontFamily: 'serif', fontSize: 12)),
      selected: value,
      selectedColor: kIlluminationGold.withValues(alpha: 0.3),
      checkmarkColor: kInkColor,
      onSelected: onChanged,
    );
  }
}

/// Presets seed `Set<HexCoord>`s, centered on the grid origin. Coordinates
/// outside the current [radius] are filtered out (a preset sized for a
/// larger grid degrades gracefully rather than leaking out-of-grid actives
/// into InkStep's neighbor checks).
class _PresetBar extends StatelessWidget {
  const _PresetBar({required this.radius, required this.onSelect});

  final int radius;
  final ValueChanged<Set<HexCoord>> onSelect;

  static Set<HexCoord> _valid(int radius, List<HexCoord> coords) {
    final cellSet = InkStep.cellsInRadius(radius).toSet();
    return coords.where(cellSet.contains).toSet();
  }

  // Straight 4-cell run along axis A.
  static Set<HexCoord> straightStroke(int radius) => _valid(radius, const [
        HexCoord(-2, 0),
        HexCoord(-1, 0),
        HexCoord(0, 0),
        HexCoord(1, 0),
      ]);

  // A run along axis A that bends onto axis C at the origin.
  static Set<HexCoord> bentStroke(int radius) => _valid(radius, const [
        HexCoord(-2, 0),
        HexCoord(-1, 0),
        HexCoord(0, 0),
        HexCoord(1, -1),
        HexCoord(2, -2),
      ]);

  // Two runs (axis A and axis C) crossing at the origin.
  static Set<HexCoord> crossingStrokes(int radius) => _valid(radius, const [
        HexCoord(-2, 0), HexCoord(-1, 0), HexCoord(0, 0), HexCoord(1, 0), HexCoord(2, 0),
        HexCoord(-2, 2), HexCoord(-1, 1), HexCoord(1, -1), HexCoord(2, -2),
      ]);

  // Two axis-A runs approaching head-on with a 1-cell gap at the origin.
  static Set<HexCoord> headOnStrokes(int radius) => _valid(radius, const [
        HexCoord(-3, 0),
        HexCoord(-2, 0),
        HexCoord(0, 0),
        HexCoord(1, 0),
      ]);

  // A short multi-direction path that bends twice, for a curved look.
  static Set<HexCoord> curve(int radius) => _valid(radius, const [
        HexCoord(-2, 1),
        HexCoord(-1, 1),
        HexCoord(-1, 0),
        HexCoord(0, 0),
        HexCoord(1, -1),
      ]);

  // Isolated single-cell dots, none adjacent to each other.
  static Set<HexCoord> scatteredDots(int radius) => _valid(radius, const [
        HexCoord(3, -3),
        HexCoord(-3, 3),
        HexCoord(3, 0),
        HexCoord(-3, 0),
        HexCoord(0, 3),
        HexCoord(0, -3),
      ]);

  @override
  Widget build(BuildContext context) {
    final presets = <String, Set<HexCoord> Function(int)>{
      'Straight': straightStroke,
      'Bent': bentStroke,
      'X-cross': crossingStrokes,
      'Head-on': headOnStrokes,
      'Curve': curve,
      'Dots': scatteredDots,
    };
    return SizedBox(
      height: 36,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: presets.entries
            .map(
              (e) => Padding(
                padding: const EdgeInsets.symmetric(horizontal: 3),
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: () => onSelect(e.value(radius)),
                  child: Text(e.key, style: const TextStyle(fontFamily: 'serif', fontSize: 12)),
                ),
              ),
            )
            .toList(),
      ),
    );
  }
}

class _Sparkline extends StatelessWidget {
  const _Sparkline({required this.counts});

  final List<int> counts;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 28,
      child: CustomPaint(
        size: const Size(double.infinity, 28),
        painter: _SparklinePainter(counts: counts),
      ),
    );
  }
}

class _SparklinePainter extends CustomPainter {
  _SparklinePainter({required this.counts});

  final List<int> counts;

  @override
  void paint(Canvas canvas, Size size) {
    if (counts.length < 2) return;
    final maxCount = counts.reduce((a, b) => a > b ? a : b).clamp(1, 1 << 30);
    final dx = size.width / (counts.length - 1);
    final path = Path();
    for (int i = 0; i < counts.length; i++) {
      final x = dx * i;
      final y = size.height - (counts[i] / maxCount) * size.height;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = kIlluminationGold
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(covariant _SparklinePainter oldDelegate) => oldDelegate.counts != counts;
}
