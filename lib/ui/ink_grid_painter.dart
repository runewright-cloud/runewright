// SPDX-License-Identifier: GPL-3.0-or-later
//
// ink_grid_painter.dart — minimal hex-grid renderer for the ink sandbox
// (lib/ui/ink_sandbox_screen.dart). Deliberately separate from
// hex_grid_painter.dart: that painter draws a full `HexGrid` with
// element/border-zone tinting, which doesn't apply here — ink has no
// element, no dominance, no border-zone sink, just "active or not." The
// hex math (pixel<->axial conversion, hex path) is copied from
// hex_grid_painter.dart to keep the same look and feel.

import 'dart:math';

import 'package:flutter/material.dart';

import '../engine/hex_grid.dart' show HexCoord;
import '../engine/ink_step.dart';
import 'manuscript_theme.dart';

class InkGridPainter extends CustomPainter {
  InkGridPainter({
    required this.radius,
    required this.active,
    required this.hexSize,
  });

  final int radius;
  final Set<HexCoord> active;
  final double hexSize;

  static const _gridLineColor = Color(0xFF9A9488);
  static const _deadFillColor = Color(0xFFFFFDF5);
  static const _borderFillColor = Color(0xFFE0DBCF);

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final cells = InkStep.cellsInRadius(radius);

    for (final coord in cells) {
      _drawCellBackground(canvas, coord, center);
    }

    // Connection lines between active neighbors, drawn before the dots so
    // the dots sit on top at each end.
    for (final coord in cells) {
      if (!active.contains(coord)) continue;
      final pos = _hexToPixel(coord, center);
      for (final dir in InkStep.directions) {
        final neighbor = HexCoord(coord.q + dir.q, coord.r + dir.r);
        if (!active.contains(neighbor)) continue;
        // Canonical dedup: only draw each edge once (lower q first, tie-break r).
        if (coord.q > neighbor.q || (coord.q == neighbor.q && coord.r > neighbor.r)) {
          continue;
        }
        canvas.drawLine(
          pos,
          _hexToPixel(neighbor, center),
          Paint()
            ..color = kInkColor
            ..strokeWidth = hexSize * 0.36
            ..strokeCap = StrokeCap.round,
        );
      }
    }

    for (final coord in cells) {
      if (!active.contains(coord)) continue;
      canvas.drawCircle(_hexToPixel(coord, center), hexSize * 0.22, Paint()..color = kInkColor);
    }
  }

  void _drawCellBackground(Canvas canvas, HexCoord coord, Offset center) {
    final pos = _hexToPixel(coord, center);
    final path = _hexPath(pos);
    final fill = InkStep.isBorder(coord, radius) ? _borderFillColor : _deadFillColor;
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
    return coord.q.abs() <= radius && coord.r.abs() <= radius && (coord.q + coord.r).abs() <= radius
        ? coord
        : null;
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
  bool shouldRepaint(covariant InkGridPainter oldDelegate) =>
      oldDelegate.active != active ||
      oldDelegate.radius != radius ||
      oldDelegate.hexSize != hexSize;
}
