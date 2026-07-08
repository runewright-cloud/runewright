// SPDX-License-Identifier: GPL-3.0-or-later
//
// spell_card_painter.dart — default art for a spell card in the library.
//
// Layout: a square parchment card holding, at its center, the spell's heraldic
// coat of arms (the same generative-heraldry escutcheon as the identity sigil,
// keyed here to the spell's grid commitment), surrounded by a ring of elemental
// symbols.
//
//   • Central shield  — SigilPainter.paintShield, keyed to commitmentHex, so
//     "Kin" spells (same grid) share the same arms.
//   • Symbol ring     — one symbol per CA step the spell ran for (spell.t).
//     Symbols are drawn from the spell's effect affinities: a flame (fire), a
//     water drop (water), a whirlwind (air), a rock (earth). A spell of a
//     single affinity shows all-identical symbols; mixed affinities split the
//     count by the effect ratio (see [elementSymbolsFor]).

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../spells/spell_asset.dart';
import 'manuscript_theme.dart';
import 'sigil_painter.dart';

// ── Elemental palette (illuminated folio tones) ───────────────────────────────

const _kFireColor = Color(0xFFB84040); // cinnabar / vermillion
const _kAirColor = Color(0xFF6E93B8); // cerulean sky (deepened for contrast)
const _kWaterColor = Color(0xFF2B4D8C); // ultramarine
const _kEarthColor = Color(0xFF8B6228); // raw umber

Color _elementColor(String element) => switch (element) {
      'fire' => _kFireColor,
      'air' => _kAirColor,
      'water' => _kWaterColor,
      'earth' => _kEarthColor,
      _ => kIlluminationGold,
    };

/// Canonical element order (matches BorderZone) — used as a deterministic
/// tiebreak when distributing symbols and ordering them around the ring.
const List<String> _elementOrder = ['fire', 'air', 'water', 'earth'];

// ── Symbol allocation ─────────────────────────────────────────────────────────

/// Computes the ring of elemental symbols for a spell that ran [steps] CA steps
/// with the given flat [formula] (committed activations; each complete triplet
/// is one *effect* whose FIRST entry is its elemental affinity).
///
/// Returns exactly [steps] symbols, each a list of element names: length 1 is a
/// plain symbol, length 2 is a *split* symbol (half one element, half another).
/// The symbol counts follow the ratio of effect affinities, allocated by the
/// largest-remainder method; when the leftover units fall on a tie between
/// equal fractional remainders, those tied elements are paired into split
/// symbols rather than rounded arbitrarily.
///
///   • 2 water + 1 fire effects over 12 steps → 8 water, 4 fire.
///   • 2 water + 1 fire + 1 air effects over 14 steps → 7 water, 3 fire,
///     3 air, and 1 fire/air split.
List<List<String>> elementSymbolsFor(List<String> formula, int steps) {
  if (steps <= 0) return const [];

  // Count effect affinities: the first entry of each complete triplet.
  final counts = <String, int>{};
  var effects = 0;
  for (var i = 0; i + 3 <= formula.length; i += 3) {
    final a = formula[i].toLowerCase();
    if (_elementOrder.contains(a)) {
      counts[a] = (counts[a] ?? 0) + 1;
      effects++;
    }
  }
  // Fallback for spells with no complete effect (e.g. legacy or very short
  // castings): count the raw activations instead so the ring isn't empty.
  if (effects == 0) {
    for (final z in formula) {
      final a = z.toLowerCase();
      if (_elementOrder.contains(a)) counts[a] = (counts[a] ?? 0) + 1;
    }
  }

  final total = counts.values.fold<int>(0, (s, v) => s + v);
  if (total == 0) return const [];

  final elems = _elementOrder.where(counts.containsKey).toList();

  // Real-valued share → integer base + fractional remainder.
  final base = <String, int>{};
  final frac = <String, double>{};
  for (final e in elems) {
    final exact = steps * counts[e]! / total;
    base[e] = exact.floor();
    frac[e] = exact - base[e]!;
  }
  var remaining = steps - base.values.fold<int>(0, (s, v) => s + v);

  // Leftover units go to the largest fractional remainders; ties become splits.
  final extraFull = <String>[];
  final splits = <List<String>>[];
  final byFrac = [...elems]..sort((a, b) {
      final c = frac[b]!.compareTo(frac[a]!);
      if (c != 0) return c;
      return _elementOrder.indexOf(a).compareTo(_elementOrder.indexOf(b));
    });

  var i = 0;
  while (remaining > 0 && i < byFrac.length) {
    var j = i;
    while (j < byFrac.length &&
        (frac[byFrac[j]]! - frac[byFrac[i]]!).abs() < 1e-9) {
      j++;
    }
    final group = byFrac.sublist(i, j);
    if (remaining >= group.length) {
      extraFull.addAll(group);
      remaining -= group.length;
      i = j;
    } else {
      // Fewer leftover units than tied elements: pair them into split symbols.
      var g = 0;
      while (remaining > 0 && g < group.length) {
        if (g + 1 < group.length) {
          splits.add([group[g], group[g + 1]]);
          g += 2;
        } else {
          extraFull.add(group[g]);
          g += 1;
        }
        remaining--;
      }
    }
  }

  // Assemble: full symbols grouped by element (canonical order), then splits.
  final symbols = <List<String>>[];
  for (final e in elems) {
    final n = base[e]! + extraFull.where((x) => x == e).length;
    for (var k = 0; k < n; k++) {
      symbols.add([e]);
    }
  }
  symbols.addAll(splits);
  return symbols;
}

// ── SpellCardPainter ──────────────────────────────────────────────────────────

class SpellCardPainter extends CustomPainter {
  SpellCardPainter({
    required this.shieldBytes,
    required this.symbols,
    this.saturation = 1.35,
  });

  /// Key bytes driving the central heraldic shield (the spell's commitment).
  final Uint8List shieldBytes;

  /// One entry per surrounding symbol; length 1 = plain, length 2 = split.
  final List<List<String>> symbols;

  final double saturation;

  @override
  bool shouldRepaint(SpellCardPainter o) =>
      o.shieldBytes != shieldBytes ||
      o.saturation != saturation ||
      !_sameSymbols(o.symbols, symbols);

  static bool _sameSymbols(List<List<String>> a, List<List<String>> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].length != b[i].length) return false;
      for (var j = 0; j < a[i].length; j++) {
        if (a[i][j] != b[i][j]) return false;
      }
    }
    return true;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final s = math.min(size.width, size.height);
    final c = Offset(size.width / 2, size.height / 2);

    _paintBackground(canvas, size);

    // Symbol ring geometry. Symbols shrink as their number grows, and the ring
    // radius pulls in just enough to keep the outermost symbol inside the card.
    final n = symbols.length;
    double symR = 0.075 * s;
    if (n > 0) {
      symR = math.min(symR, math.pi * (0.40 * s) / n * 0.92);
      symR = math.max(symR, 0.018 * s);
    }
    final ringR = math.min(0.40 * s, 0.485 * s - symR);

    // Central shield, sized to sit inside the ring.
    final shieldW = 0.50 * s;
    final shieldH = 0.55 * s;
    final shieldRect = Rect.fromCenter(
        center: Offset(c.dx, c.dy + shieldH * 0.08),
        width: shieldW,
        height: shieldH);
    SigilPainter(shieldBytes, saturation: saturation)
        .paintShield(canvas, shieldRect);

    // Ring of elemental symbols, starting at 12 o'clock and going clockwise.
    for (var i = 0; i < n; i++) {
      final angle = -math.pi / 2 + 2 * math.pi * i / n;
      final center = c + Offset(math.cos(angle), math.sin(angle)) * ringR;
      _drawSymbol(canvas, center, symR, symbols[i]);
    }

    _paintFrame(canvas, size, s);
  }

  void _paintBackground(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = kParchmentPanelColor);
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = RadialGradient(
          colors: [kParchmentColor, kParchmentPanelColor],
          radius: 0.75,
        ).createShader(Offset.zero & size),
    );
  }

  void _paintFrame(Canvas canvas, Size size, double s) {
    final c = Offset(size.width / 2, size.height / 2);
    final inset = s * 0.03;
    final rect = Rect.fromCenter(
        center: c, width: s - inset * 2, height: s - inset * 2);
    canvas.drawRect(
      rect,
      Paint()
        ..color = kIlluminationGold
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1.0, s * 0.012),
    );
    canvas.drawRect(
      rect.deflate(s * 0.018),
      Paint()
        ..color = kInkColor.withValues(alpha: 0.6)
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(0.6, s * 0.004),
    );
  }

  // ── Symbols ──────────────────────────────────────────────────────────────

  void _drawSymbol(Canvas canvas, Offset center, double r, List<String> parts) {
    if (parts.length == 1) {
      _drawElementIcon(canvas, center, r, parts[0]);
      return;
    }
    // Split symbol: left half of element A, right half of element B.
    final bounds = Rect.fromCircle(center: center, radius: r * 1.2);
    canvas.save();
    canvas.clipRect(Rect.fromLTRB(bounds.left, bounds.top, center.dx, bounds.bottom));
    _drawElementIcon(canvas, center, r, parts[0]);
    canvas.restore();
    canvas.save();
    canvas.clipRect(Rect.fromLTRB(center.dx, bounds.top, bounds.right, bounds.bottom));
    _drawElementIcon(canvas, center, r, parts[1]);
    canvas.restore();
    // Dividing line.
    canvas.drawLine(
      Offset(center.dx, center.dy - r),
      Offset(center.dx, center.dy + r),
      Paint()
        ..color = kInkColor
        ..strokeWidth = math.max(0.5, r * 0.09),
    );
  }

  void _drawElementIcon(Canvas canvas, Offset center, double r, String element) {
    final path = _elementIconPath(element, r);
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.drawPath(path, Paint()..color = _elementColor(element));
    canvas.drawPath(
        path,
        Paint()
          ..color = kInkColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(0.5, r * 0.11)
          ..strokeJoin = StrokeJoin.round);
    canvas.restore();
  }

  /// Element glyph centered at the origin, sized to roughly fill radius [r].
  Path _elementIconPath(String element, double r) {
    final u = r * 0.92;
    switch (element) {
      case 'fire':
        return _flame(u);
      case 'water':
        return _drop(u);
      case 'air':
        return _whirlwind(u);
      case 'earth':
        return _rock(u);
      default:
        return Path()..addOval(Rect.fromCircle(center: Offset.zero, radius: u * 0.7));
    }
  }

  // A flame: a bulbous base rising to a tall curling tip, with a side lick —
  // deliberately asymmetric so it never reads as the water drop.
  Path _flame(double u) {
    final p = Path();
    p.moveTo(0.0, u); // bottom center
    // right side rising
    p.cubicTo(0.62 * u, 0.78 * u, 0.66 * u, 0.15 * u, 0.40 * u, -0.18 * u);
    // main tongue curling up, leaning left over the top
    p.cubicTo(0.26 * u, -0.42 * u, 0.10 * u, -0.52 * u, 0.16 * u, -0.82 * u);
    p.cubicTo(0.19 * u, -1.02 * u, -0.02 * u, -1.04 * u, -0.08 * u, -0.80 * u);
    // dip between main tongue and the side lick
    p.cubicTo(-0.13 * u, -0.56 * u, -0.22 * u, -0.5 * u, -0.36 * u, -0.52 * u);
    // side lick flicking out to the left
    p.cubicTo(-0.24 * u, -0.36 * u, -0.44 * u, -0.28 * u, -0.52 * u, -0.30 * u);
    p.cubicTo(-0.44 * u, -0.04 * u, -0.62 * u, 0.22 * u, -0.50 * u, 0.52 * u);
    p.cubicTo(-0.42 * u, 0.80 * u, -0.22 * u, 0.90 * u, 0.0, u);
    p.close();
    return p;
  }

  // A water drop: a symmetric teardrop, round bottom, pointed top.
  Path _drop(double u) {
    final p = Path();
    p.moveTo(0, -u);
    p.cubicTo(0.62 * u, -0.15 * u, 0.66 * u, 0.5 * u, 0.30 * u, 0.8 * u);
    p.cubicTo(0.12 * u, 0.96 * u, -0.12 * u, 0.96 * u, -0.30 * u, 0.8 * u);
    p.cubicTo(-0.66 * u, 0.5 * u, -0.62 * u, -0.15 * u, 0, -u);
    p.close();
    // highlight glint
    p.moveTo(-0.12 * u, 0.28 * u);
    p.cubicTo(-0.34 * u, 0.28 * u, -0.34 * u, 0.6 * u, -0.12 * u, 0.62 * u);
    p.cubicTo(-0.02 * u, 0.5 * u, -0.02 * u, 0.36 * u, -0.12 * u, 0.28 * u);
    p.close();
    p.fillType = PathFillType.evenOdd;
    return p;
  }

  // A whirlwind: a funnel (wide top, narrow foot) with swept swirl lines.
  Path _whirlwind(double u) {
    final p = Path();
    // funnel outline
    p.moveTo(-0.9 * u, -0.85 * u);
    p.cubicTo(0.1 * u, -1.05 * u, 0.95 * u, -0.7 * u, 0.78 * u, -0.5 * u);
    p.cubicTo(0.55 * u, -0.28 * u, -0.35 * u, -0.42 * u, 0.28 * u, -0.15 * u);
    p.cubicTo(0.6 * u, 0.02 * u, -0.1 * u, 0.05 * u, 0.32 * u, 0.28 * u);
    p.cubicTo(0.55 * u, 0.42 * u, 0.05 * u, 0.5 * u, 0.16 * u, 0.72 * u);
    p.cubicTo(0.24 * u, 0.9 * u, -0.05 * u, u, -0.12 * u, u);
    p.cubicTo(-0.35 * u, 0.9 * u, -0.2 * u, 0.62 * u, -0.5 * u, 0.42 * u);
    p.cubicTo(-0.85 * u, 0.18 * u, -0.2 * u, 0.12 * u, -0.7 * u, -0.12 * u);
    p.cubicTo(-1.0 * u, -0.32 * u, -0.35 * u, -0.4 * u, -0.9 * u, -0.62 * u);
    p.close();
    return p;
  }

  // A rock: an irregular faceted boulder with an internal facet crease.
  Path _rock(double u) {
    final p = Path();
    p.moveTo(-0.85 * u, 0.15 * u);
    p.lineTo(-0.5 * u, -0.55 * u);
    p.lineTo(0.15 * u, -0.8 * u);
    p.lineTo(0.7 * u, -0.4 * u);
    p.lineTo(0.9 * u, 0.25 * u);
    p.lineTo(0.5 * u, 0.8 * u);
    p.lineTo(-0.35 * u, 0.82 * u);
    p.lineTo(-0.8 * u, 0.45 * u);
    p.close();
    // facet creases (drawn as thin sub-paths; even-odd keeps them as cuts)
    p.moveTo(0.15 * u, -0.8 * u);
    p.lineTo(0.02 * u, 0.0 * u);
    p.lineTo(0.5 * u, 0.8 * u);
    p.lineTo(0.42 * u, 0.02 * u);
    p.close();
    p.moveTo(0.02 * u, 0.0 * u);
    p.lineTo(-0.8 * u, 0.45 * u);
    p.lineTo(-0.34 * u, 0.06 * u);
    p.close();
    p.fillType = PathFillType.evenOdd;
    return p;
  }
}

// ── SpellCardWidget ───────────────────────────────────────────────────────────

Uint8List _hexToBytes(String hex) {
  if (hex.isEmpty) return Uint8List(32);
  final clean = hex.replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
  final n = clean.length ~/ 2;
  final result = Uint8List(n);
  for (var i = 0; i < n; i++) {
    result[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return result;
}

SpellCardPainter _painterFor(SpellAsset spell) => SpellCardPainter(
      shieldBytes: _hexToBytes(spell.commitmentHex),
      symbols: elementSymbolsFor(spell.formula, spell.t),
    );

void _showSpellCardFullscreen(BuildContext context, SpellCardPainter painter) {
  showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.92),
    barrierDismissible: true,
    builder: (ctx) => GestureDetector(
      onTap: () => Navigator.of(ctx).pop(),
      behavior: HitTestBehavior.opaque,
      child: Dialog.fullscreen(
        backgroundColor: Colors.transparent,
        child: Center(
          child: Builder(
            builder: (innerCtx) {
              final side = MediaQuery.of(innerCtx).size.shortestSide * 0.88;
              return SizedBox(
                width: side,
                height: side,
                child: CustomPaint(painter: painter),
              );
            },
          ),
        ),
      ),
    ),
  );
}

/// Default card art for a [SpellAsset].
///
/// A heraldic coat of arms (keyed to [SpellAsset.commitmentHex], so Kin spells
/// share it) ringed by one elemental symbol per CA step the spell ran for
/// ([SpellAsset.t]), split across elements by the spell's effect affinities.
/// Tapping opens a full-screen overlay that dismisses on any tap.
class SpellCardWidget extends StatelessWidget {
  const SpellCardWidget({
    super.key,
    required this.spell,
    this.size = 88,
  });

  final SpellAsset spell;
  final double size;

  @override
  Widget build(BuildContext context) {
    final painter = _painterFor(spell);
    return GestureDetector(
      onTap: () => _showSpellCardFullscreen(context, painter),
      child: SizedBox(
        width: size,
        height: size,
        child: CustomPaint(painter: painter),
      ),
    );
  }
}
