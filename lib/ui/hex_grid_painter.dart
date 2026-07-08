import 'dart:math';
import 'package:flutter/material.dart' hide Element;
import '../engine/border_zone.dart';
import '../engine/border_zones.dart';
import '../engine/element.dart';
import '../engine/hex_grid.dart';
import 'element_visuals.dart';

class HexGridPainter extends CustomPainter {
  final HexGrid grid;
  final double hexSize;
  final int innerRadius;
  final BorderZone? activeZone;
  final Set<HexCoord> activatedBorderCells;
  // The grid state from just before the most recent step, used to animate
  // ink lines/dots growing or shrinking into `grid` rather than snapping.
  // Null means "draw `grid` statically" (manual edits, revert, reset, spell
  // fast-forward on load — none of those are step animations).
  final HexGrid? previousGrid;
  // When non-null, the painter subscribes to these for repaints and reads
  // their .value each frame — no AnimatedBuilder needed.
  final Animation<double>? _flicker;
  final Animation<double>? _growth;

  HexGridPainter({
    required this.grid,
    required this.hexSize,
    required this.innerRadius,
    this.activeZone,
    this.activatedBorderCells = const {},
    this.previousGrid,
    Animation<double>? flicker,
    Animation<double>? growth,
  })  : _flicker = flicker,
        _growth = growth,
        super(repaint: Listenable.merge([flicker, growth]));

  // Two-beat flicker: rapid flash → dip → bounce → fade.
  // Not a Curve subclass — Flutter's CurveTween asserts transform(1.0)==1.0,
  // which this intentionally violates (it returns 0.0 at t=1 to fade out).
  static double _flickerCurve(double t) {
    if (t < 0.08) return t / 0.08;                           // 0→1: flash
    if (t < 0.22) return 1.0 - (t - 0.08) / 0.14 * 0.70;  // 1→0.3: first dip
    if (t < 0.35) return 0.3 + (t - 0.22) / 0.13 * 0.55;  // 0.3→0.85: bounce
    if (t < 0.48) return 0.85 - (t - 0.35) / 0.13 * 0.45; // 0.85→0.4: second dip
    return 0.4 * (1.0 - t) / 0.52;                         // 0.4→0: fade out
  }

  double get _activationPulse => _flickerCurve(_flicker?.value ?? 0.0);

  static const _gridLineColor  = Color(0xFF9A9488); // warm gray
  static const _outerFillColor = Color(0xFFE0DBCF); // uninscribable — 5% darker than base parchment

  // "Metaball" filter: blurring shapes together and then snapping alpha
  // back to sharp with a steep threshold melts whatever junction they form —
  // convex or concave — into one smooth rounded seam. A' = 18*A - 1785
  // (0-255 scale) clamped to [0,255], so anything below ~40% post-blur
  // alpha vanishes and anything above goes fully opaque.
  static const _gooFilter = ColorFilter.matrix(<double>[
    1, 0, 0, 0, 0,
    0, 1, 0, 0, 0,
    0, 0, 1, 0, 0,
    0, 0, 0, 18, -1785,
  ]);

  double get _gooBlurSigma => hexSize * 0.16;

  Paint _gooPaint(Color color) =>
      Paint()..color = color..maskFilter = MaskFilter.blur(BlurStyle.normal, _gooBlurSigma);

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);

    // Pass 1: backgrounds and grid lines
    for (final entry in grid.cells.entries) {
      _drawCellBackground(canvas, entry.key, entry.value, center);
    }

    // t=1 (no previous state to animate from) draws exactly like the old
    // snap-to-state code; t<1 lerps edges/dots/triangles that appeared or
    // vanished since `previousGrid` in from/out of their shared midpoint
    // (edges/dots) or centroid (triangles).
    final prev = previousGrid;
    final t = prev == null ? 1.0 : (_growth?.value ?? 1.0);

    // Solid fill for the small triangular gap between any three
    // mutually-adjacent alive cells.
    final currentTriangles = _liveTriangles(grid);
    final triangles = t >= 1.0 ? currentTriangles : currentTriangles.union(_liveTriangles(prev!));
    final triangleRenders = <(Offset, Offset, Offset, Color)>[];
    for (final tri in triangles) {
      final (a, b, c) = tri;
      final grown = t >= 1.0 ? 1.0 : currentTriangles.contains(tri) ? t : 1.0 - t;
      if (grown <= 0.0) continue;
      final posA = _hexToPixel(a, center);
      final posB = _hexToPixel(b, center);
      final posC = _hexToPixel(c, center);
      final centroid = Offset(
        (posA.dx + posB.dx + posC.dx) / 3,
        (posA.dy + posB.dy + posC.dy) / 3,
      );
      triangleRenders.add((
        Offset.lerp(centroid, posA, grown)!,
        Offset.lerp(centroid, posB, grown)!,
        Offset.lerp(centroid, posC, grown)!,
        _inkColor(a),
      ));
    }

    // Connecting lines between alive neighbors.
    final currentEdges = _liveEdges(grid);
    final edges = t >= 1.0 ? currentEdges : currentEdges.union(_liveEdges(prev!));
    final edgeRenders = <(Offset, Offset, Color, BorderZone?, int)>[];
    for (final edge in edges) {
      final (a, b) = edge;
      final grown = t >= 1.0 ? 1.0 : currentEdges.contains(edge) ? t : 1.0 - t;
      if (grown <= 0.0) continue;
      final posA = _hexToPixel(a, center);
      final posB = _hexToPixel(b, center);
      final mid = Offset.lerp(posA, posB, 0.5)!;
      edgeRenders.add((
        Offset.lerp(mid, posA, grown)!,
        Offset.lerp(mid, posB, grown)!,
        _inkColor(a),
        _zoneForColoring(a),
        _edgeSeed(a, b),
      ));
    }

    // Dots at centers of alive cells. A dot with no live edge at all has
    // nothing to goo-merge with, and a small circle blurred by _gooBlurSigma
    // then re-thresholded comes back noticeably smaller than it went in
    // (the blur eats into its whole interior, not just its rim) — so
    // isolated dots skip the goo layer entirely and are drawn at full size
    // afterward instead of shrinking for no visual benefit.
    final connectedCoords = <HexCoord>{};
    for (final (a, b) in edges) {
      connectedCoords.add(a);
      connectedCoords.add(b);
    }
    final currentAlive = grid.cells.entries
        .where((e) => e.value == Element.alive)
        .map((e) => e.key)
        .toSet();
    final aliveCoords = t >= 1.0
        ? currentAlive
        : currentAlive.union(prev!.cells.entries
            .where((e) => e.value == Element.alive)
            .map((e) => e.key)
            .toSet());
    final dotRenders = <(Offset, double, Color, bool)>[];
    for (final coord in aliveCoords) {
      final grown = t >= 1.0 ? 1.0 : currentAlive.contains(coord) ? t : 1.0 - t;
      if (grown <= 0.0) continue;
      dotRenders.add((
        _hexToPixel(coord, center),
        hexSize * 0.22 * grown,
        _inkColor(coord),
        connectedCoords.contains(coord),
      ));
    }

    // Goo layer: triangle fills, base line strokes, and dots are all drawn
    // blurred into this offscreen layer, then composited back with a steep
    // alpha threshold (a "metaball" filter) — every junction between them,
    // convex points and concave notches around gaps alike, melts into one
    // smooth rounded ink blob instead of sharp seams. Air's dashed stroke
    // and every zone's small decorative texture marks are drawn afterward,
    // outside the layer, so the blur doesn't wash them out.
    canvas.saveLayer(Offset.zero & size, Paint()..colorFilter = _gooFilter);
    for (final (pa, pb, pc, color) in triangleRenders) {
      canvas.drawPath(_roundedTrianglePath(pa, pb, pc), _gooPaint(color));
    }
    for (final (start, end, color, zone, seed) in edgeRenders) {
      final path = _edgeBasePath(start, end, zone, seed);
      if (path == null) continue; // air's stroke is drawn outside the layer
      canvas.drawPath(
        path,
        _gooPaint(color)
          ..strokeWidth = hexSize * 0.36
          ..strokeCap = StrokeCap.round
          ..style = PaintingStyle.stroke,
      );
    }
    for (final (pos, radius, color, connected) in dotRenders) {
      if (!connected) continue;
      canvas.drawCircle(pos, radius, _gooPaint(color));
    }
    canvas.restore();

    // Zone texture overlays, crisp and on top of the goo result.
    for (final (start, end, color, zone, seed) in edgeRenders) {
      _drawEdgeTexture(canvas, start, end, color, zone, seed);
    }

    // Isolated dots (no live edge to goo-merge with) at full, un-blurred size.
    for (final (pos, radius, color, connected) in dotRenders) {
      if (connected) continue;
      canvas.drawCircle(pos, radius, Paint()..color = color);
    }

    // Pass 4: flicker + glow on activated border cells
    final pulse = _activationPulse;
    if (pulse > 0.0 && activatedBorderCells.isNotEmpty) {
      for (final coord in activatedBorderCells) {
        final zone = BorderZones.forRadius(grid.radius)[coord];
        if (zone == null) continue;
        final pos = _hexToPixel(coord, center);
        final color = _zoneColor(zone, true);

        // Soft outer halo — blurred circle larger than the hex
        canvas.drawCircle(
          pos,
          hexSize * 1.9,
          Paint()
            ..color = color.withValues(alpha: 0.40 * pulse)
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, hexSize * 0.85),
        );

        // Bright fill flash — fills the hex cell with the zone color
        canvas.drawPath(
          _hexPath(pos),
          Paint()..color = color.withValues(alpha: 0.82 * pulse),
        );

        // Crisp glow ring on the hex edge
        canvas.drawPath(
          _hexPath(pos),
          Paint()
            ..color = color.withValues(alpha: pulse)
            ..style = PaintingStyle.stroke
            ..strokeWidth = hexSize * 0.18,
        );

        // White-hot center dot — hottest point of the flash
        canvas.drawCircle(
          pos,
          hexSize * 0.40,
          Paint()..color = const Color(0xFFFFFFFF).withValues(alpha: 0.88 * pulse),
        );
      }
    }
  }

  bool _isOuter(HexCoord coord) =>
      [coord.q.abs(), coord.r.abs(), (coord.q + coord.r).abs()].reduce(max) >
      innerRadius;

  bool _isBorder(HexCoord coord) =>
      [coord.q.abs(), coord.r.abs(), (coord.q + coord.r).abs()].reduce(max) ==
      grid.radius;

  static Color _zoneColor(BorderZone zone, bool alive) {
    if (alive) {
      return switch (zone) {
        BorderZone.fire  => const Color(0xFFCC3311),
        BorderZone.air   => const Color(0xFF6699BB),
        BorderZone.water => const Color(0xFF2255AA),
        BorderZone.earth => const Color(0xFF7A5C28),
      };
    }
    return switch (zone) {
      BorderZone.fire  => const Color(0xFFD4907A),
      BorderZone.air   => const Color(0xFF90B8D0),
      BorderZone.water => const Color(0xFF7898C8),
      BorderZone.earth => const Color(0xFFB09460),
    };
  }

  Color _inkColor(HexCoord coord) {
    final zone = _zoneForColoring(coord);
    return zone != null ? _zoneColor(zone, true) : Element.alive.color;
  }

  // The zone whose color/texture a cell's ink should carry: its own border
  // ring zone if it's a border cell, else the globally dominant zone (if
  // any elemental rule is currently active), else neither (plain ink).
  BorderZone? _zoneForColoring(HexCoord coord) {
    if (_isBorder(coord)) {
      final zone = BorderZones.forRadius(grid.radius)[coord];
      if (zone != null) return zone;
    }
    return activeZone;
  }

  // Every edge (as a canonically-ordered coord pair, lower q first, tie-break
  // r) between two currently-alive neighboring cells in [g].
  Set<(HexCoord, HexCoord)> _liveEdges(HexGrid g) {
    final edges = <(HexCoord, HexCoord)>{};
    for (final entry in g.cells.entries) {
      if (entry.value != Element.alive) continue;
      for (final (neighborCoord, neighborElement) in g.neighbors(entry.key)) {
        if (neighborElement != Element.alive) continue;
        if (entry.key.q > neighborCoord.q ||
            (entry.key.q == neighborCoord.q && entry.key.r > neighborCoord.r)) {
          continue;
        }
        edges.add((entry.key, neighborCoord));
      }
    }
    return edges;
  }

  // Stable per-edge seed so textures (wave phase, fleck placement, grain
  // scatter) stay put across repaints instead of sparkling every frame.
  int _edgeSeed(HexCoord a, HexCoord b) => Object.hash(a, b);

  // Every triangle of three mutually-adjacent alive cells in [g], as a
  // coord triple sorted (q then r) so each triangle appears once regardless
  // of which of its three vertices found it. HexGrid.directions is ordered
  // so consecutive entries (wrapping) are themselves adjacent — e.g.
  // direction[0]=(1,0) and direction[1]=(1,-1) differ by (0,-1), also a
  // listed direction — so a cell plus two consecutive-direction neighbors
  // are always the three corners of one small triangular gap.
  Set<(HexCoord, HexCoord, HexCoord)> _liveTriangles(HexGrid g) {
    final dirs = HexGrid.directions;
    final triangles = <(HexCoord, HexCoord, HexCoord)>{};
    for (final entry in g.cells.entries) {
      if (entry.value != Element.alive) continue;
      final c = entry.key;
      for (int i = 0; i < dirs.length; i++) {
        final d1 = dirs[i];
        final d2 = dirs[(i + 1) % dirs.length];
        final n1 = HexCoord(c.q + d1.q, c.r + d1.r);
        final n2 = HexCoord(c.q + d2.q, c.r + d2.r);
        if (g.cells[n1] != Element.alive) continue;
        if (g.cells[n2] != Element.alive) continue;
        final tri = [c, n1, n2]
          ..sort((x, y) => x.q != y.q ? x.q.compareTo(y.q) : x.r.compareTo(y.r));
        triangles.add((tri[0], tri[1], tri[2]));
      }
    }
    return triangles;
  }

  Offset _dirUnit(Offset a, Offset b) {
    final d = b - a;
    final len = d.distance;
    return len == 0 ? const Offset(1, 0) : d / len;
  }

  // Subtle wobble every ink stroke gets by default, so long straight
  // stretches read as hand-inked rather than ruler-drawn.
  static const _defaultWobble = 0.035;

  // The base ink-stroke path drawn inside the goo layer, for every zone
  // except air — air's stroke is dashed and must stay outside the goo layer
  // (see _drawEdgeTexture) so the blur doesn't bridge its intentional gaps.
  // A little organic waviness by default; water leans into it much harder
  // (a full flowing wave).
  Path? _edgeBasePath(Offset a, Offset b, BorderZone? zone, int seed) {
    if (zone == BorderZone.air) return null;
    final amp = zone == BorderZone.water ? hexSize * 0.09 : hexSize * _defaultWobble;
    return _organicPath(a, b, seed, amp);
  }

  // Draws the small zone-specific texture layered on top of the goo'd base
  // stroke — plain ink and water have none; air's dashed stroke lives here
  // too, drawn fresh (not goo'd) so its gaps stay crisp.
  void _drawEdgeTexture(
    Canvas canvas,
    Offset a,
    Offset b,
    Color color,
    BorderZone? zone,
    int seed,
  ) {
    switch (zone) {
      case null:
      case BorderZone.water:
        return;
      case BorderZone.air:
        final basePaint = Paint()
          ..color = color
          ..strokeWidth = hexSize * 0.36
          ..strokeCap = StrokeCap.round
          ..style = PaintingStyle.stroke;
        _drawDashedPath(canvas, _organicPath(a, b, seed, hexSize * _defaultWobble), basePaint);
        _drawWisp(canvas, a, b, color, seed);
      case BorderZone.fire:
        _drawFlameFlecks(canvas, a, b, color, seed);
      case BorderZone.earth:
        _drawGrain(canvas, a, b, color, seed);
    }
  }

  // Gentle sine wobble, tapering to zero at both ends so the line still
  // meets the cell-center dots exactly, then smoothed into curves rather
  // than a faceted polyline.
  Path _organicPath(Offset a, Offset b, int seed, double amp) {
    final dir = _dirUnit(a, b);
    final perp = Offset(-dir.dy, dir.dx);
    final phase = (seed % 628) / 100.0;
    const steps = 6;
    final points = <Offset>[a];
    for (int i = 1; i < steps; i++) {
      final t = i / steps;
      final wobble = sin(t * pi * 2 + phase) * amp * sin(t * pi);
      points.add(Offset.lerp(a, b, t)! + perp * wobble);
    }
    points.add(b);
    return _smoothPath(points);
  }

  // Threads a smooth curve through [points]: each interior point becomes a
  // quadratic control point, with the curve itself passing through the
  // midpoints between consecutive points — softens what would otherwise be
  // sharp joints between straight segments.
  Path _smoothPath(List<Offset> points) {
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (int i = 1; i < points.length - 1; i++) {
      final mid = Offset.lerp(points[i], points[i + 1], 0.5)!;
      path.quadraticBezierTo(points[i].dx, points[i].dy, mid.dx, mid.dy);
    }
    path.lineTo(points.last.dx, points.last.dy);
    return path;
  }

  // Rounds a triangle's three corners — pulls each corner in along its two
  // adjacent edges and curves through, so the fill reads as a soft ink blot
  // rather than a crisp geometric wedge.
  Path _roundedTrianglePath(Offset p0, Offset p1, Offset p2) {
    const cornerFrac = 0.5;
    final a0 = Offset.lerp(p0, p1, cornerFrac)!;
    final a1 = Offset.lerp(p0, p2, cornerFrac)!;
    final b0 = Offset.lerp(p1, p2, cornerFrac)!;
    final b1 = Offset.lerp(p1, p0, cornerFrac)!;
    final c0 = Offset.lerp(p2, p0, cornerFrac)!;
    final c1 = Offset.lerp(p2, p1, cornerFrac)!;
    return Path()
      ..moveTo(a0.dx, a0.dy)
      ..lineTo(b1.dx, b1.dy)
      ..quadraticBezierTo(p1.dx, p1.dy, b0.dx, b0.dy)
      ..lineTo(c1.dx, c1.dy)
      ..quadraticBezierTo(p2.dx, p2.dy, c0.dx, c0.dy)
      ..lineTo(a1.dx, a1.dy)
      ..quadraticBezierTo(p0.dx, p0.dy, a0.dx, a0.dy)
      ..close();
  }

  // Broken/breezy stroke instead of a solid line, following [path]'s wobble.
  void _drawDashedPath(Canvas canvas, Path path, Paint paint) {
    final metric = path.computeMetrics().first;
    final total = metric.length;
    const dashFrac = 0.16;
    const gapFrac = 0.10;
    var t = 0.0;
    var drawing = true;
    while (t < 1.0) {
      final next = (t + (drawing ? dashFrac : gapFrac)).clamp(0.0, 1.0);
      if (drawing) {
        canvas.drawPath(metric.extractPath(t * total, next * total), paint);
      }
      t = next;
      drawing = !drawing;
    }
  }

  // A single small drifting wisp off to one side — a breath of wind.
  void _drawWisp(Canvas canvas, Offset a, Offset b, Color color, int seed) {
    final rand = Random(seed + 1);
    final dir = _dirUnit(a, b);
    final perp = Offset(-dir.dy, dir.dx);
    final t = 0.3 + rand.nextDouble() * 0.4;
    final side = rand.nextBool() ? 1 : -1;
    final pos = Offset.lerp(a, b, t)! + perp * (side * hexSize * 0.20);
    canvas.drawCircle(pos, hexSize * 0.045, Paint()..color = color.withValues(alpha: 0.35));
  }

  // Short bright ticks jutting off the line — guttering flame.
  void _drawFlameFlecks(Canvas canvas, Offset a, Offset b, Color color, int seed) {
    final rand = Random(seed + 2);
    final dir = _dirUnit(a, b);
    final perp = Offset(-dir.dy, dir.dx);
    final flickPaint = Paint()
      ..color = Color.lerp(color, const Color(0xFFFFCC66), 0.6)!.withValues(alpha: 0.55)
      ..strokeWidth = hexSize * 0.08
      ..strokeCap = StrokeCap.round;
    final count = 2 + rand.nextInt(2);
    for (int i = 0; i < count; i++) {
      final t = ((i + 1) / (count + 1) + (rand.nextDouble() - 0.5) * 0.12).clamp(0.05, 0.95);
      final base = Offset.lerp(a, b, t)!;
      final side = rand.nextBool() ? 1 : -1;
      final len = hexSize * (0.14 + rand.nextDouble() * 0.08);
      final tip = base + perp * (side * len) + dir * (len * 0.3);
      canvas.drawLine(base, tip, flickPaint);
    }
  }

  // Scattered grains along the line — dry, granular earth.
  void _drawGrain(Canvas canvas, Offset a, Offset b, Color color, int seed) {
    final rand = Random(seed + 3);
    final dir = _dirUnit(a, b);
    final perp = Offset(-dir.dy, dir.dx);
    final grainPaint = Paint()..color = Color.lerp(color, Colors.black, 0.3)!.withValues(alpha: 0.5);
    final count = 4 + rand.nextInt(3);
    for (int i = 0; i < count; i++) {
      final t = rand.nextDouble();
      final off = (rand.nextDouble() - 0.5) * hexSize * 0.22;
      final pos = Offset.lerp(a, b, t)! + perp * off;
      canvas.drawCircle(pos, hexSize * 0.03, grainPaint);
    }
  }

  void _drawCellBackground(
    Canvas canvas,
    HexCoord coord,
    Element element,
    Offset center,
  ) {
    final pos = _hexToPixel(coord, center);
    final path = _hexPath(pos);

    Color fill;
    if (_isBorder(coord)) {
      final zone = BorderZones.forRadius(grid.radius)[coord];
      // Border cells always show their dead zone tint as background
      fill = zone != null ? _zoneColor(zone, false) : Element.dead.color;
    } else if (_isOuter(coord)) {
      fill = _outerFillColor;
    } else {
      fill = Element.dead.color;
    }
    canvas.drawPath(path, Paint()..color = fill);
    canvas.drawPath(
      path,
      Paint()
        ..color = _gridLineColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0,
    );
  }

  Path _hexPath(Offset center) {
    final path = Path();
    for (int i = 0; i < 6; i++) {
      final angle = pi / 3 * i;
      final x = center.dx + hexSize * cos(angle);
      final y = center.dy + hexSize * sin(angle);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    path.close();
    return path;
  }

  Offset _hexToPixel(HexCoord coord, Offset center) {
    return Offset(
      center.dx + hexSize * (3 / 2 * coord.q),
      center.dy + hexSize * (sqrt(3) / 2 * coord.q + sqrt(3) * coord.r),
    );
  }

  HexCoord? pixelToHex(Offset pixel, Size canvasSize) {
    final center = Offset(canvasSize.width / 2, canvasSize.height / 2);
    final dx = pixel.dx - center.dx;
    final dy = pixel.dy - center.dy;

    final fq = (2 / 3 * dx) / hexSize;
    final fr = (-1 / 3 * dx + sqrt(3) / 3 * dy) / hexSize;

    final coord = _roundHex(fq, fr);
    return grid.cells.containsKey(coord) ? coord : null;
  }

  HexCoord _roundHex(double fq, double fr) {
    final fs = -fq - fr;
    var q = fq.round();
    var r = fr.round();
    var s = fs.round();

    final dq = (q - fq).abs();
    final dr = (r - fr).abs();
    final ds = (s - fs).abs();

    if (dq > dr && dq > ds) {
      q = -r - s;
    } else if (dr > ds) {
      r = -q - s;
    }

    return HexCoord(q, r);
  }

  @override
  bool shouldRepaint(HexGridPainter oldDelegate) => true;
}
