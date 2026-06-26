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
  // When non-null, the painter subscribes to this for repaints and reads
  // its .value each frame — no AnimatedBuilder needed.
  final Animation<double>? _flicker;

  HexGridPainter({
    required this.grid,
    required this.hexSize,
    required this.innerRadius,
    this.activeZone,
    this.activatedBorderCells = const {},
    Animation<double>? flicker,
  })  : _flicker = flicker,
        super(repaint: flicker);

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

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);

    // Pass 1: backgrounds and grid lines
    for (final entry in grid.cells.entries) {
      _drawCellBackground(canvas, entry.key, entry.value, center);
    }

    // Pass 2: connection lines between alive neighbors (dots drawn on top in pass 3)
    for (final entry in grid.cells.entries) {
      if (entry.value != Element.alive) continue;
      final pos = _hexToPixel(entry.key, center);
      final color = _inkColor(entry.key);
      for (final (neighborCoord, neighborElement) in grid.neighbors(entry.key)) {
        if (neighborElement != Element.alive) continue;
        // Canonical dedup: only draw each edge once (lower q first, tie-break r)
        if (entry.key.q > neighborCoord.q ||
            (entry.key.q == neighborCoord.q && entry.key.r > neighborCoord.r)) {
          continue;
        }
        final neighborPos = _hexToPixel(neighborCoord, center);
        canvas.drawLine(
          pos,
          neighborPos,
          Paint()
            ..color = color
            ..strokeWidth = hexSize * 0.36
            ..strokeCap = StrokeCap.round,
        );
      }
    }

    // Pass 3: dots at centers of alive cells
    for (final entry in grid.cells.entries) {
      if (entry.value != Element.alive) continue;
      final pos = _hexToPixel(entry.key, center);
      canvas.drawCircle(pos, hexSize * 0.22, Paint()..color = _inkColor(entry.key));
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
    if (_isBorder(coord)) {
      final zone = BorderZones.forRadius(grid.radius)[coord];
      if (zone != null) return _zoneColor(zone, true);
    }
    if (activeZone != null) return _zoneColor(activeZone!, true);
    return Element.alive.color;
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
