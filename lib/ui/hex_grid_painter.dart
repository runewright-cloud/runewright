import 'dart:math';
import 'package:flutter/material.dart' hide Element;
import '../engine/element.dart';
import '../engine/hex_grid.dart';
import 'element_visuals.dart';

class HexGridPainter extends CustomPainter {
  final HexGrid grid;
  final double hexSize;
  final int innerRadius;

  HexGridPainter({
    required this.grid,
    required this.hexSize,
    required this.innerRadius,
  });

  double get _borderHexRadius => 15 * hexSize + (hexSize / 2) / (2 * sqrt(3));

  Path _buildBorderPath(Offset center) {
    final radius = _borderHexRadius;
    final path = Path();
    for (int i = 0; i < 6; i++) {
      final angle = pi / 6 + pi / 3 * i;
      final x = center.dx + radius * cos(angle);
      final y = center.dy + radius * sin(angle);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    path.close();
    return path;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    canvas.save();
    canvas.clipPath(_buildBorderPath(center));
    for (final entry in grid.cells.entries) {
      _drawCell(canvas, entry.key, entry.value, center);
    }
    canvas.restore();
    _drawBorderHexagon(canvas, size);
  }

  void _drawBorderHexagon(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    canvas.drawPath(
      _buildBorderPath(center),
      Paint()
        ..color = Colors.white54
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0,
    );
  }

  bool _isOuter(HexCoord coord) =>
      [coord.q.abs(), coord.r.abs(), (coord.q + coord.r).abs()].reduce(max) >
      innerRadius;

  void _drawCell(
    Canvas canvas,
    HexCoord coord,
    Element element,
    Offset center,
  ) {
    final pos = _hexToPixel(coord, center);
    final path = _hexPath(pos);

    final fill = (element == Element.empty && _isOuter(coord))
        ? const Color(0xFF28283C)
        : element.color;
    canvas.drawPath(path, Paint()..color = fill);
    canvas.drawPath(
      path,
      Paint()
        ..color = Colors.black38
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  Path _hexPath(Offset center) {
    final path = Path();
    for (int i = 0; i < 6; i++) {
      final angle = pi / 3 * i; // flat-top: first corner at 0°
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

  // Convert a screen tap position to the nearest valid grid coord.
  // Returns null if the tap is outside the grid.
  HexCoord? pixelToHex(Offset pixel, Size canvasSize) {
    final center = Offset(canvasSize.width / 2, canvasSize.height / 2);
    final dx = pixel.dx - center.dx;
    final dy = pixel.dy - center.dy;

    final fq = (2 / 3 * dx) / hexSize;
    final fr = (-1 / 3 * dx + sqrt(3) / 3 * dy) / hexSize;

    final coord = _roundHex(fq, fr);
    return grid.cells.containsKey(coord) ? coord : null;
  }

  // Cube-coordinate rounding: finds the nearest hex to fractional axial coords.
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
