import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart' hide Element;
import 'engine/element.dart';
import 'engine/hex_grid.dart';
import 'engine/stepper.dart';
import 'ui/hex_grid_painter.dart';
import 'ui/element_visuals.dart';
import 'ui/menu_screen.dart';

void main() => runApp(const RuneDuelApp());

class RuneDuelApp extends StatelessWidget {
  const RuneDuelApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Rune Duel',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF12121E),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF8855CC),
          surface: Color(0xFF12121E),
        ),
      ),
      home: const MenuScreen(),
    );
  }
}

class GameScreen extends StatefulWidget {
  const GameScreen({super.key});

  @override
  State<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends State<GameScreen> {
  static const _innerRadius = 5;
  static const _radius = 9; // inner + 3-cell buffer zone + 1-cell clipped ring

  HexGrid _grid = HexGrid(_radius);
  Element _selectedElement = Element.fire;
  final _paintKey = GlobalKey();
  bool _running = false;
  Timer? _timer;
  HexGrid? _previewSaved;
  HexGrid? _initialGrid;

  // Preferred growth directions in flat-top axial coords.
  // Clockwise from top: 0=top, 1=top-right, 2=bottom-right, 3=bottom, 4=bottom-left, 5=top-left.
  static const Map<Element, int> _directions = {
    Element.fire:  5, // top-left
    Element.air:   1, // top-right
    Element.water: 2, // bottom-right
    Element.earth: 4, // bottom-left
  };

  double _hexSize(Size available) {
    // Flat-top grid bounding box:
    //   width  = hexSize * (3 * radius + 2)
    //   height = hexSize * sqrt(3) * (2 * radius + 1)
    const padding = 16.0;
    final byWidth = (available.width - padding) / (3 * _radius + 2);
    final byHeight = (available.height - padding) / (sqrt(3) * (2 * _radius + 1));
    return min(byWidth, byHeight).clamp(12.0, 40.0);
  }

  static bool _isOuter(HexCoord coord) =>
      [coord.q.abs(), coord.r.abs(), (coord.q + coord.r).abs()].reduce(max) > _innerRadius;

  void _onTap(TapUpDetails details) {
    final box = _paintKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final size = box.size;
    final painter = HexGridPainter(grid: _grid, hexSize: _hexSize(size), innerRadius: _innerRadius);
    final coord = painter.pixelToHex(details.localPosition, size);
    if (coord == null) return;
    if (_isOuter(coord)) return;
    if (_grid.stepCount != 0) return;
    setState(() {
      _grid.cells[coord] = _grid.cells[coord] == Element.empty
          ? _selectedElement
          : Element.empty;
    });
  }

  bool _gridsEqual(HexGrid a, HexGrid b) {
    for (final entry in a.cells.entries) {
      if (b.cells[entry.key] != entry.value) return false;
    }
    return true;
  }

  void _togglePreview() {
    if (_previewSaved == null) {
      final saved = _grid;
      _initialGrid ??= _grid.copy();
      final next = CAStep.step(_grid, _directions);
      setState(() {
        _previewSaved = saved;
        _grid = next;
      });
    } else {
      setState(() {
        _grid = _previewSaved!;
        _previewSaved = null;
      });
    }
  }

  void _toggleRun() {
    if (_running) {
      _timer?.cancel();
      setState(() => _running = false);
    } else {
      _initialGrid ??= _grid.copy();
      setState(() => _running = true);
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        final next = CAStep.step(_grid, _directions);
        if (_gridsEqual(_grid, next)) {
          _timer?.cancel();
          setState(() => _running = false);
          return;
        }
        setState(() => _grid = next);
      });
    }
  }

  void _revert() {
    if (_initialGrid == null) return;
    _timer?.cancel();
    setState(() {
      _grid = _initialGrid!.copy();
      _running = false;
      _previewSaved = null;
    });
  }

  void _reset() {
    _timer?.cancel();
    setState(() {
      _grid = HexGrid(_radius);
      _running = false;
      _previewSaved = null;
      _initialGrid = null;
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Rune Duel'),
        backgroundColor: const Color(0xFF1A0A2E),
        actions: [
          IconButton(
            icon: const Icon(Icons.undo),
            tooltip: 'Revert',
            onPressed: _initialGrid != null ? _revert : null,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Reset',
            onPressed: _reset,
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Row(
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
                          ),
                          child: const SizedBox.expand(),
                        );
                      },
                    ),
                  ),
                ),
                Column(
                  children: [
                    const _ColorKey(),
                    _BorderTally(grid: _grid),
                  ],
                ),
              ],
            ),
          ),
          _BottomBar(
            selected: _selectedElement,
            onSelect: (e) => setState(() => _selectedElement = e),
            running: _running,
            onToggleRun: _toggleRun,
            previewActive: _previewSaved != null,
            onTogglePreview: _togglePreview,
            stepCount: _grid.stepCount,
          ),
        ],
      ),
    );
  }
}

class _BottomBar extends StatelessWidget {
  final Element selected;
  final ValueChanged<Element> onSelect;
  final bool running;
  final VoidCallback onToggleRun;
  final bool previewActive;
  final VoidCallback onTogglePreview;
  final int stepCount;

  const _BottomBar({
    required this.selected,
    required this.onSelect,
    required this.running,
    required this.onToggleRun,
    required this.previewActive,
    required this.onTogglePreview,
    required this.stepCount,
  });

  @override
  Widget build(BuildContext context) {
    const inscribable = [
      Element.fire,
      Element.water,
      Element.earth,
      Element.air,
      Element.fireWater,
      Element.fireEarth,
      Element.fireAir,
      Element.waterEarth,
      Element.waterAir,
      Element.earthAir,
    ];
    return Container(
      color: const Color(0xFF1A0A2E),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          ...inscribable.map(
            (e) => Padding(
              padding: const EdgeInsets.only(right: 8),
              child: _ElementButton(
                element: e,
                selected: e == selected,
                onTap: () => onSelect(e),
              ),
            ),
          ),
          const Spacer(),
          Text(
            'Step $stepCount',
            style: const TextStyle(color: Colors.white54, fontSize: 13),
          ),
          const SizedBox(width: 16),
          ElevatedButton.icon(
            onPressed: running ? null : onTogglePreview,
            icon: Icon(previewActive ? Icons.undo : Icons.skip_next),
            label: Text(previewActive ? 'Revert' : 'Preview'),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF336688),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            ),
          ),
          const SizedBox(width: 8),
          ElevatedButton.icon(
            onPressed: previewActive ? null : onToggleRun,
            icon: Icon(running ? Icons.pause : Icons.play_arrow),
            label: Text(running ? 'Pause' : 'Run'),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF8855CC),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            ),
          ),
        ],
      ),
    );
  }
}

class _ColorKey extends StatelessWidget {
  const _ColorKey();

  static const _entries = [
    Element.fire,
    Element.water,
    Element.earth,
    Element.air,
    Element.fireWater,
    Element.fireEarth,
    Element.fireAir,
    Element.waterEarth,
    Element.waterAir,
    Element.earthAir,
    Element.chaos,
    Element.voidEl,
    Element.empty,
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 120,
      color: const Color(0xFF1A0A2E),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: _entries.map((e) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            children: [
              Container(
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  color: e.color,
                  border: Border.all(color: Colors.black38, width: 1),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  e.displayName,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 10,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        )).toList(),
      ),
    );
  }
}

class _BorderTally extends StatelessWidget {
  final HexGrid grid;

  const _BorderTally({required this.grid});

  static const _tracked = [
    Element.fire,
    Element.water,
    Element.earth,
    Element.air,
    Element.chaos,
    Element.voidEl,
  ];

  @override
  Widget build(BuildContext context) {
    final totals = <Element, int>{};
    for (final bucket in grid.borderTriggers.values) {
      for (final entry in bucket.entries) {
        totals[entry.key] = (totals[entry.key] ?? 0) + entry.value;
      }
    }

    return Container(
      width: 120,
      color: const Color(0xFF1A0A2E),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Border Triggers',
            style: TextStyle(color: Colors.white38, fontSize: 9, letterSpacing: 1),
          ),
          const SizedBox(height: 6),
          ..._tracked.map((e) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              children: [
                Container(
                  width: 14,
                  height: 14,
                  decoration: BoxDecoration(
                    color: e.color,
                    border: Border.all(color: Colors.black38, width: 1),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    e.displayName,
                    style: const TextStyle(color: Colors.white70, fontSize: 10),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  '${totals[e] ?? 0}',
                  style: const TextStyle(color: Colors.white54, fontSize: 10),
                ),
              ],
            ),
          )),
        ],
      ),
    );
  }
}

class _ElementButton extends StatelessWidget {
  final Element element;
  final bool selected;
  final VoidCallback onTap;

  const _ElementButton({
    required this.element,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        width: 54,
        height: 54,
        decoration: BoxDecoration(
          color: element.color,
          border: Border.all(
            color: selected ? Colors.white : Colors.white24,
            width: selected ? 2.5 : 1.0,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Center(
          child: Text(
            element.displayName,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 10,
              fontWeight: FontWeight.bold,
            ),
            textAlign: TextAlign.center,
          ),
        ),
      ),
    );
  }
}
