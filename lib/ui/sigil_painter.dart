// SPDX-License-Identifier: GPL-3.0-or-later
//
// sigil_painter.dart — Heraldic hash art for wizard identity and spell default
// art. Deterministic: the same keyBytes always produce the same coat of arms.
//
// Instead of one intricate Celtic knot, this generates a *blazon* — a coat of
// arms assembled from independent heraldic slots, each drawn from a catalogue
// of visually distinct elements:
//
//   • an escutcheon (heater shield) as the container,
//   • a FIELD: a tincture, optionally divided (per pale/fess/bend/chevron,
//     quarterly, per saltire) or varied (barry/paly/checky/lozengy/…),
//   • a line of partition on that division (wavy, engrailed, indented,
//     embattled, …),
//   • an ORDINARY laid over the field (chief, fess, pale, bend, chevron, cross,
//     saltire, pile, bordure),
//   • one or more CHARGES (roundels, mullets, fleurs-de-lis, crescents, roses,
//     escallops, crosses, and figurative beasts: lion rampant, eagle
//     displayed, griffin, martlet).
//
// Tinctures obey the heraldic *rule of tincture* — never colour-on-colour or
// metal-on-metal — so charges stay legible and the result reads as genuine
// heraldry. The number of elements is deliberately *moderate*: a division, an
// ordinary, and a charge, rather than a maximal quartering.
//
// The byte→blazon mapping is a plain deterministic decode of keyBytes (with a
// small non-cryptographic xorshift only as a fallback if more draws are needed
// than the key has bytes). It is cosmetic, NOT a security commitment.
//
// Usage: wrap an Identity's publicKeyBytes in SigilWidget, or paint directly
// with SigilPainter inside a CustomPaint.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'manuscript_theme.dart';

// ---------------------------------------------------------------------------
// Tinctures
// ---------------------------------------------------------------------------

/// The two heraldic classes. The rule of tincture forbids placing a metal on a
/// metal or a colour on a colour; adjacent regions and stacked charges must
/// alternate class.
enum _TClass { metal, colour }

class _Tincture {
  const _Tincture(this.name, this.color, this.cls);
  final String name;
  final Color color;
  final _TClass cls;
}

// Muted-but-authentic tinctures, tuned to sit beside the manuscript palette.
const _or = _Tincture('or', Color(0xFFDDB13A), _TClass.metal);
const _argent = _Tincture('argent', Color(0xFFE9E5DA), _TClass.metal);
const _gules = _Tincture('gules', Color(0xFF9E2A2B), _TClass.colour);
const _azure = _Tincture('azure', Color(0xFF2E5090), _TClass.colour);
const _sable = _Tincture('sable', Color(0xFF201C18), _TClass.colour);
const _vert = _Tincture('vert', Color(0xFF2F6B3C), _TClass.colour);
const _purpure = _Tincture('purpure', Color(0xFF6D3A75), _TClass.colour);

const _metals = <_Tincture>[_or, _argent];
const _colours = <_Tincture>[_gules, _azure, _sable, _vert, _purpure];

// ---------------------------------------------------------------------------
// Deterministic reader
// ---------------------------------------------------------------------------

/// Pulls deterministic values out of the key bytes. Real key bytes are consumed
/// first (so the arms are a pure function of the key); an xorshift32 seeded from
/// the whole key supplies extra draws only if the blazon needs more than the key
/// has bytes. Cosmetic only — never a cryptographic commitment.
class _Bits {
  _Bits(this._bytes) : _state = _seed(_bytes);

  final Uint8List _bytes;
  int _cursor = 0;
  int _state;

  static int _seed(Uint8List b) {
    var s = 0x9E3779B9;
    for (final x in b) {
      s = (s ^ x) & 0xFFFFFFFF;
      s = (s * 0x01000193) & 0xFFFFFFFF;
    }
    return s == 0 ? 1 : s;
  }

  int _next() {
    var x = _state;
    x ^= (x << 13) & 0xFFFFFFFF;
    x ^= x >> 17;
    x ^= (x << 5) & 0xFFFFFFFF;
    _state = x & 0xFFFFFFFF;
    return _state;
  }

  int byte() =>
      _cursor < _bytes.length ? _bytes[_cursor++] : (_next() & 0xFF);

  /// Uniform-ish in [0, n). Bias is negligible at the small n used here.
  int range(int n) => n <= 1 ? 0 : byte() % n;

  bool coin([int truePct = 50]) => range(100) < truePct;

  T pick<T>(List<T> xs) => xs[range(xs.length)];

  /// Weighted pick; [weights] must be the same length as [xs].
  T weighted<T>(List<T> xs, List<int> weights) {
    var total = 0;
    for (final w in weights) {
      total += w;
    }
    var r = range(total);
    for (var i = 0; i < xs.length; i++) {
      if (r < weights[i]) return xs[i];
      r -= weights[i];
    }
    return xs.last;
  }

  _Tincture tincture(_TClass cls) =>
      pick(cls == _TClass.metal ? _metals : _colours);
}

_TClass _opposite(_TClass c) =>
    c == _TClass.metal ? _TClass.colour : _TClass.metal;

Color _saturate(Color color, double factor) {
  if (factor == 1.0) return color;
  final hsl = HSLColor.fromColor(color);
  return hsl.withSaturation((hsl.saturation * factor).clamp(0.0, 1.0)).toColor();
}

// ---------------------------------------------------------------------------
// Blazon — the decoded coat of arms
// ---------------------------------------------------------------------------

enum _Division {
  plain,
  perPale,
  perFess,
  perBend,
  perBendSinister,
  perChevron,
  quarterly,
  perSaltire,
  barry,
  paly,
  bendy,
  checky,
  lozengy,
  chevronny,
}

// Divisions that are drawn as a single partition line (and so can take a line
// style). The rest are either plain or repeating variations.
const _partyDivisions = {
  _Division.perPale,
  _Division.perFess,
  _Division.perBend,
  _Division.perBendSinister,
  _Division.perChevron,
};

enum _Line {
  straight,
  wavy,
  engrailed,
  invected,
  indented,
  dancetty,
  embattled,
}

enum _Ordinary {
  none,
  chief,
  fess,
  pale,
  bend,
  bendSinister,
  chevron,
  cross,
  saltire,
  pile,
  bordure,
}

// Ordinaries whose long edges look good with a line style.
const _linedOrdinaries = {
  _Ordinary.chief,
  _Ordinary.fess,
  _Ordinary.pale,
  _Ordinary.bend,
  _Ordinary.bendSinister,
  _Ordinary.chevron,
};

enum _Charge {
  // geometric / mobile
  roundel,
  annulet,
  mullet,
  mulletOfSix,
  sun,
  lozenge,
  billet,
  crescent,
  fleurDeLis,
  rose,
  escallop,
  crossPattee,
  crossCrosslet,
  trefoil,
  // figurative
  lionRampant,
  eagleDisplayed,
  griffin,
  martlet,
}

// Small charges suitable for strewing (semé) or 2-and-1 groups.
const _smallCharges = {
  _Charge.mullet,
  _Charge.mulletOfSix,
  _Charge.roundel,
  _Charge.fleurDeLis,
  _Charge.crescent,
  _Charge.crossCrosslet,
  _Charge.rose,
  _Charge.billet,
};

enum _Arrangement { single, three, seme }

class _Blazon {
  _Blazon({
    required this.division,
    required this.fieldA,
    required this.fieldB,
    required this.divisionLine,
    required this.variationCount,
    required this.ordinary,
    required this.ordinaryTincture,
    required this.ordinaryLine,
    required this.hasCharge,
    required this.charge,
    required this.chargeTincture,
    required this.arrangement,
    required this.chargeOnOrdinary,
  });

  final _Division division;
  final _Tincture fieldA; // primary field tincture
  final _Tincture fieldB; // second tincture for divisions/variations
  final _Line divisionLine;
  final int variationCount; // stripes/checks per side for variations

  final _Ordinary ordinary;
  final _Tincture ordinaryTincture;
  final _Line ordinaryLine;

  final bool hasCharge;
  final _Charge charge;
  final _Tincture chargeTincture;
  final _Arrangement arrangement;
  final bool chargeOnOrdinary;

  /// Decode a full coat of arms from key bytes. The decode order is fixed so the
  /// mapping is stable across sizes and sessions.
  factory _Blazon.decode(Uint8List keyBytes) {
    final bits = _Bits(keyBytes);

    // Field base class, then the division.
    final classA = bits.coin() ? _TClass.metal : _TClass.colour;
    final classB = _opposite(classA);

    final division = bits.weighted(_Division.values, const [
      26, // plain
      10, // perPale
      10, // perFess
      8, // perBend
      6, // perBendSinister
      7, // perChevron
      6, // quarterly
      5, // perSaltire
      4, // barry
      4, // paly
      3, // bendy
      3, // checky
      2, // lozengy
      2, // chevronny
    ]);

    final fieldA = bits.tincture(classA);
    var fieldB = bits.tincture(classB);
    // Avoid a second tincture identical in hue to the first when both are metals
    // etc. (classes already differ, so this only re-rolls within a class match).
    if (fieldB.color == fieldA.color) fieldB = bits.tincture(classB);

    final divisionLine = _partyDivisions.contains(division)
        ? bits.weighted(_Line.values, const [34, 12, 12, 12, 10, 8, 12])
        : _Line.straight;

    final variationCount = 4 + bits.range(3) * 2; // 4, 6, or 8

    // Ordinary: skip it more often when the field is already busy.
    final busyField = !_partyDivisions.contains(division) &&
        division != _Division.plain;
    final wantOrdinary =
        busyField ? bits.coin(25) : bits.coin(62);
    final ordinary = wantOrdinary
        ? bits.weighted(const [
            _Ordinary.chief,
            _Ordinary.fess,
            _Ordinary.pale,
            _Ordinary.bend,
            _Ordinary.bendSinister,
            _Ordinary.chevron,
            _Ordinary.cross,
            _Ordinary.saltire,
            _Ordinary.pile,
            _Ordinary.bordure,
          ], const [12, 12, 10, 10, 7, 9, 8, 7, 6, 9])
        : _Ordinary.none;

    // Ordinary contrasts with the primary field tincture's class.
    final ordinaryTincture = bits.tincture(classB);
    final ordinaryLine = _linedOrdinaries.contains(ordinary)
        ? bits.weighted(_Line.values, const [46, 12, 12, 10, 8, 6, 10])
        : _Line.straight;

    // Charge. Prefer sitting a charge on a broad central ordinary; else in the
    // field. Semé only on an otherwise plain, ordinary-free field.
    final centralOrdinary = {
      _Ordinary.fess,
      _Ordinary.pale,
      _Ordinary.cross,
      _Ordinary.chevron,
      _Ordinary.pile,
    }.contains(ordinary);

    final wantCharge = bits.coin(88);
    final charge = wantCharge
        ? bits.weighted(_Charge.values, const [
            8, 6, 9, 6, 5, 6, 4, 7, 10, 7, 6, 6, 5, 5, // geometric
            9, 8, 6, 6, // figurative
          ])
        : _Charge.roundel;

    final chargeOnOrdinary = wantCharge && centralOrdinary && bits.coin(70);

    // Background the charge sits on, for the rule of tincture.
    final bgClass = chargeOnOrdinary ? classB : classA;
    final chargeTincture = bits.tincture(_opposite(bgClass));

    _Arrangement arrangement;
    if (!wantCharge) {
      arrangement = _Arrangement.single;
    } else if (chargeOnOrdinary) {
      arrangement = bits.coin(60) ? _Arrangement.single : _Arrangement.three;
    } else if (_smallCharges.contains(charge) &&
        ordinary == _Ordinary.none &&
        division == _Division.plain) {
      arrangement = bits.weighted(_Arrangement.values, const [40, 30, 30]);
    } else if (_smallCharges.contains(charge) && !busyField) {
      arrangement = bits.coin(55) ? _Arrangement.single : _Arrangement.three;
    } else {
      arrangement = _Arrangement.single;
    }

    return _Blazon(
      division: division,
      fieldA: fieldA,
      fieldB: fieldB,
      divisionLine: divisionLine,
      variationCount: variationCount,
      ordinary: ordinary,
      ordinaryTincture: ordinaryTincture,
      ordinaryLine: ordinaryLine,
      hasCharge: wantCharge,
      charge: charge,
      chargeTincture: chargeTincture,
      arrangement: arrangement,
      chargeOnOrdinary: chargeOnOrdinary,
    );
  }
}

// ---------------------------------------------------------------------------
// Painter
// ---------------------------------------------------------------------------

class SigilPainter extends CustomPainter {
  SigilPainter(this.keyBytes, {this.gridN = 7, this.saturation = 1.0})
      : _blazon = _Blazon.decode(keyBytes);

  final Uint8List keyBytes;

  /// Retained for API compatibility with the previous knot painter; the
  /// heraldic generator uses a fixed, moderate complexity and ignores it.
  final int gridN;

  /// Multiplier applied to each tincture's HSL saturation. Values > 1 make the
  /// arms pop at small sizes (e.g. the 36px creator badge); 1.0 is the muted
  /// manuscript-friendly palette.
  final double saturation;

  final _Blazon _blazon;

  Color _t(_Tincture t) => _saturate(t.color, saturation);

  @override
  bool shouldRepaint(SigilPainter old) =>
      old.keyBytes != keyBytes ||
      old.saturation != saturation ||
      old.gridN != gridN;

  @override
  void paint(Canvas canvas, Size size) {
    _drawBackground(canvas, size);

    final dim = math.min(size.width, size.height);
    final margin = dim * 0.14;

    // The shield sits inside the inner frame line.
    final inner = dim - margin * 0.95;
    final shieldH = inner * 0.98;
    final rect = Rect.fromCenter(
        center: Offset(size.width / 2, size.height / 2 - shieldH * 0.02),
        width: inner * 0.9,
        height: shieldH);

    paintShield(canvas, rect);
    _drawBorder(canvas, size, dim, margin);
  }

  /// Paints just the heraldic escutcheon — field, ordinary, charges, and the
  /// gold-and-ink shield edge — for this painter's blazon into [rect]. Draws no
  /// background and no outer frame, so callers (e.g. spell-card art) can place
  /// the shield anywhere.
  void paintShield(Canvas canvas, Rect rect) {
    final shield = _heaterShield(rect);

    canvas.save();
    canvas.clipPath(shield);
    _paintField(canvas, rect);
    _paintOrdinary(canvas, rect);
    _paintCharges(canvas, rect);
    canvas.restore();

    // Shield edge: a gold inner rim under a fine ink outline.
    canvas.drawPath(
        shield,
        Paint()
          ..color = _t(_or)
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(1.0, rect.width * 0.014));
    canvas.drawPath(
        shield,
        Paint()
          ..color = kInkColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(0.8, rect.width * 0.007));
  }

  // -- Shield geometry ------------------------------------------------------

  Path _heaterShield(Rect r) {
    final w = r.width, h = r.height;
    final cx = r.center.dx;
    final shoulder = r.top + h * 0.52;
    return Path()
      ..moveTo(r.left, r.top)
      ..lineTo(r.right, r.top)
      ..lineTo(r.right, shoulder)
      ..cubicTo(r.right, r.top + h * 0.80, cx + w * 0.30, r.bottom - h * 0.03,
          cx, r.bottom)
      ..cubicTo(cx - w * 0.30, r.bottom - h * 0.03, r.left, r.top + h * 0.80,
          r.left, shoulder)
      ..close();
  }

  // -- Field ----------------------------------------------------------------

  void _paintField(Canvas canvas, Rect r) {
    final a = Paint()..color = _t(_blazon.fieldA);
    final b = Paint()..color = _t(_blazon.fieldB);
    final pad = r.width; // overrun; the shield clip trims it.
    final o = Rect.fromLTRB(
        r.left - pad, r.top - pad, r.right + pad, r.bottom + pad);

    // Base fill.
    canvas.drawRect(o, a);

    final line = _blazon.divisionLine;
    final amp = r.width * 0.035;
    final period = r.width * 0.17;

    switch (_blazon.division) {
      case _Division.plain:
        break;

      case _Division.perPale:
        final x = r.center.dx;
        final edge = _styledLine(
            Offset(x, o.top), Offset(x, o.bottom), line, amp, period);
        edge
          ..lineTo(o.right, o.bottom)
          ..lineTo(o.right, o.top)
          ..close();
        canvas.drawPath(edge, b);
        _strokeStyledLine(canvas,
            _styledLine(Offset(x, r.top), Offset(x, r.bottom), line, amp, period));

      case _Division.perFess:
        final y = r.center.dy;
        final edge = _styledLine(
            Offset(o.left, y), Offset(o.right, y), line, amp, period);
        edge
          ..lineTo(o.right, o.bottom)
          ..lineTo(o.left, o.bottom)
          ..close();
        canvas.drawPath(edge, b);
        _strokeStyledLine(canvas,
            _styledLine(Offset(r.left, y), Offset(r.right, y), line, amp, period));

      case _Division.perBend:
        final edge = _styledLine(
            Offset(o.left, o.top), Offset(o.right, o.bottom), line, amp, period);
        edge
          ..lineTo(o.left, o.bottom)
          ..close();
        canvas.drawPath(edge, b);
        _strokeStyledLine(
            canvas,
            _styledLine(Offset(r.left, r.top), Offset(r.right, r.bottom), line,
                amp, period));

      case _Division.perBendSinister:
        final edge = _styledLine(
            Offset(o.right, o.top), Offset(o.left, o.bottom), line, amp, period);
        edge
          ..lineTo(o.right, o.bottom)
          ..close();
        canvas.drawPath(edge, b);
        _strokeStyledLine(
            canvas,
            _styledLine(Offset(r.right, r.top), Offset(r.left, r.bottom), line,
                amp, period));

      case _Division.perChevron:
        final apex = Offset(r.center.dx, r.center.dy - r.height * 0.02);
        final left = Offset(o.left, o.bottom);
        final right = Offset(o.right, o.bottom);
        final edge = _styledLine(left, apex, line, amp, period);
        _appendStyledLine(edge, apex, right, line, amp, period);
        edge
          ..lineTo(o.right, o.bottom)
          ..lineTo(o.left, o.bottom)
          ..close();
        canvas.drawPath(edge, b);
        final apexR = Offset(r.center.dx, r.center.dy - r.height * 0.02);
        final stroke =
            _styledLine(Offset(r.left, r.bottom), apexR, line, amp, period);
        _appendStyledLine(
            stroke, apexR, Offset(r.right, r.bottom), line, amp, period);
        _strokeStyledLine(canvas, stroke);

      case _Division.quarterly:
        final cx = r.center.dx, cy = r.center.dy;
        canvas.drawRect(Rect.fromLTRB(cx, o.top, o.right, cy), b); // Q2
        canvas.drawRect(Rect.fromLTRB(o.left, cy, cx, o.bottom), b); // Q3
        _strokeLine(canvas, Offset(cx, r.top), Offset(cx, r.bottom));
        _strokeLine(canvas, Offset(r.left, cy), Offset(r.right, cy));

      case _Division.perSaltire:
        final c = r.center;
        // top and bottom triangles get tincture B.
        canvas.drawPath(
            Path()
              ..moveTo(c.dx, c.dy)
              ..lineTo(o.left, o.top)
              ..lineTo(o.right, o.top)
              ..close(),
            b);
        canvas.drawPath(
            Path()
              ..moveTo(c.dx, c.dy)
              ..lineTo(o.left, o.bottom)
              ..lineTo(o.right, o.bottom)
              ..close(),
            b);
        _strokeLine(canvas, Offset(r.left, r.top), Offset(r.right, r.bottom));
        _strokeLine(canvas, Offset(r.right, r.top), Offset(r.left, r.bottom));

      case _Division.barry:
        _stripes(canvas, o, b, _blazon.variationCount, horizontal: true);
      case _Division.paly:
        _stripes(canvas, o, b, _blazon.variationCount, horizontal: false);
      case _Division.bendy:
        _bendy(canvas, o, b, _blazon.variationCount);
      case _Division.checky:
        _checky(canvas, o, b, _blazon.variationCount);
      case _Division.lozengy:
        _lozengy(canvas, o, b, _blazon.variationCount);
      case _Division.chevronny:
        _chevronny(canvas, r, o, b, _blazon.variationCount);
    }
  }

  void _stripes(Canvas canvas, Rect o, Paint b, int count,
      {required bool horizontal}) {
    final span = (horizontal ? o.height : o.width) / (count * 2);
    for (var i = 0; i < count * 2; i++) {
      if (i.isOdd) continue;
      if (horizontal) {
        canvas.drawRect(
            Rect.fromLTWH(o.left, o.top + i * span, o.width, span), b);
      } else {
        canvas.drawRect(
            Rect.fromLTWH(o.left + i * span, o.top, span, o.height), b);
      }
    }
  }

  void _bendy(Canvas canvas, Rect o, Paint b, int count) {
    final w = o.width + o.height;
    final span = w / (count * 2);
    for (var i = -count; i < count * 2; i++) {
      if (i.isOdd) continue;
      final x0 = o.left + i * span;
      canvas.drawPath(
          Path()
            ..moveTo(x0, o.top)
            ..lineTo(x0 + span, o.top)
            ..lineTo(x0 + span - o.height, o.bottom)
            ..lineTo(x0 - o.height, o.bottom)
            ..close(),
          b);
    }
  }

  void _checky(Canvas canvas, Rect o, Paint b, int count) {
    final s = o.width / count;
    for (var row = 0; row * s < o.height; row++) {
      for (var col = 0; col < count; col++) {
        if ((row + col).isEven) continue;
        canvas.drawRect(
            Rect.fromLTWH(o.left + col * s, o.top + row * s, s, s), b);
      }
    }
  }

  void _lozengy(Canvas canvas, Rect o, Paint b, int count) {
    final s = o.width / count;
    final h = s * 1.4;
    for (var row = -1; o.top + row * h < o.bottom; row++) {
      for (var col = -1; o.left + col * s < o.right; col++) {
        if ((row + col).isEven) continue;
        final cx = o.left + col * s + s / 2;
        final cy = o.top + row * h + h / 2;
        canvas.drawPath(
            Path()
              ..moveTo(cx, cy - h / 2)
              ..lineTo(cx + s / 2, cy)
              ..lineTo(cx, cy + h / 2)
              ..lineTo(cx - s / 2, cy)
              ..close(),
            b);
      }
    }
  }

  void _chevronny(Canvas canvas, Rect r, Rect o, Paint b, int count) {
    final span = o.height / count;
    for (var i = -1; o.top + i * span < o.bottom; i++) {
      if (i.isOdd) continue;
      final y = o.top + i * span;
      canvas.drawPath(
          Path()
            ..moveTo(o.left, y + span)
            ..lineTo(r.center.dx, y)
            ..lineTo(o.right, y + span)
            ..lineTo(o.right, y + span * 2)
            ..lineTo(r.center.dx, y + span)
            ..lineTo(o.left, y + span * 2)
            ..close(),
          b);
    }
  }

  // -- Ordinary -------------------------------------------------------------

  void _paintOrdinary(Canvas canvas, Rect r) {
    if (_blazon.ordinary == _Ordinary.none) return;
    final fill = Paint()..color = _t(_blazon.ordinaryTincture);
    final line = _blazon.ordinaryLine;
    final w = r.width, h = r.height;
    final amp = w * 0.03;
    final period = w * 0.16;
    final pad = w;
    final o = Rect.fromLTRB(
        r.left - pad, r.top - pad, r.right + pad, r.bottom + pad);

    Path? outline;

    switch (_blazon.ordinary) {
      case _Ordinary.none:
        return;
      case _Ordinary.chief:
        final y = r.top + h * 0.26;
        final p = _styledLine(Offset(o.left, y), Offset(o.right, y), line, amp,
            period)
          ..lineTo(o.right, o.top)
          ..lineTo(o.left, o.top)
          ..close();
        outline = _styledLine(Offset(r.left, y), Offset(r.right, y), line, amp,
            period);
        canvas.drawPath(p, fill);

      case _Ordinary.fess:
        final band = h * 0.24;
        final top = r.center.dy - band / 2, bot = r.center.dy + band / 2;
        final p = _styledLine(
            Offset(o.left, top), Offset(o.right, top), line, amp, period);
        _appendStyledLineReverse(
            p, Offset(o.left, bot), Offset(o.right, bot), line, amp, period);
        p.close();
        canvas.drawPath(p, fill);

      case _Ordinary.pale:
        final band = w * 0.24;
        final l = r.center.dx - band / 2, rr = r.center.dx + band / 2;
        final p = _styledLine(
            Offset(l, o.top), Offset(l, o.bottom), line, amp, period);
        _appendStyledLineReverse(
            p, Offset(rr, o.top), Offset(rr, o.bottom), line, amp, period);
        p.close();
        canvas.drawPath(p, fill);

      case _Ordinary.bend:
        _drawBendBand(canvas, r, o, fill, line, amp, period, sinister: false);
        return;
      case _Ordinary.bendSinister:
        _drawBendBand(canvas, r, o, fill, line, amp, period, sinister: true);
        return;

      case _Ordinary.chevron:
        final band = h * 0.20;
        final apex = Offset(r.center.dx, r.top + h * 0.30);
        final lb = Offset(o.left, o.bottom);
        final rb = Offset(o.right, o.bottom);
        final upper = _styledLine(lb, apex, line, amp, period);
        _appendStyledLine(upper, apex, rb, line, amp, period);
        // lower edge, offset down by band.
        _appendStyledLineReverse(
            upper,
            Offset(o.left, o.bottom + band),
            Offset(r.center.dx, r.top + h * 0.30 + band),
            line,
            amp,
            period);
        _appendStyledLine(
            upper,
            Offset(r.center.dx, r.top + h * 0.30 + band),
            Offset(o.right, o.bottom + band),
            line,
            amp,
            period);
        upper.close();
        canvas.drawPath(upper, fill);

      case _Ordinary.cross:
        final band = w * 0.20;
        canvas.drawRect(
            Rect.fromLTRB(r.center.dx - band / 2, o.top,
                r.center.dx + band / 2, o.bottom),
            fill);
        canvas.drawRect(
            Rect.fromLTRB(o.left, r.center.dy - band / 2, o.right,
                r.center.dy + band / 2),
            fill);

      case _Ordinary.saltire:
        final band = w * 0.16;
        _thickLine(canvas, Offset(o.left, o.top), Offset(o.right, o.bottom),
            band, fill);
        _thickLine(canvas, Offset(o.right, o.top), Offset(o.left, o.bottom),
            band, fill);

      case _Ordinary.pile:
        final p = Path()
          ..moveTo(r.left + w * 0.18, r.top)
          ..lineTo(r.right - w * 0.18, r.top)
          ..lineTo(r.center.dx, r.top + h * 0.72)
          ..close();
        outline = p;
        canvas.drawPath(p, fill);

      case _Ordinary.bordure:
        final band = w * 0.11;
        canvas.save();
        canvas.drawPath(
            Path()
              ..addRect(o)
              ..addRect(o.deflate(band))
              ..fillType = PathFillType.evenOdd,
            fill);
        canvas.restore();
        // Bordure hugs the shield edge; the shield clip already shapes it.
        _strokeInsetShield(canvas, r, band);
        return;
    }

    if (outline != null) {
      canvas.drawPath(
          outline,
          Paint()
            ..color = kInkColor
            ..style = PaintingStyle.stroke
            ..strokeWidth = math.max(0.6, w * 0.006));
    }
  }

  void _drawBendBand(Canvas canvas, Rect r, Rect o, Paint fill, _Line line,
      double amp, double period,
      {required bool sinister}) {
    final band = r.width * 0.22;
    final a = sinister ? Offset(o.right, o.top) : Offset(o.left, o.top);
    final b = sinister ? Offset(o.left, o.bottom) : Offset(o.right, o.bottom);
    final dir = (b - a);
    final len = dir.distance;
    final n = Offset(-dir.dy / len, dir.dx / len) * (band / 2);
    final p = _styledLine(a + n, b + n, line, amp, period);
    _appendStyledLineReverse(p, a - n, b - n, line, amp, period);
    p.close();
    canvas.drawPath(p, fill);
  }

  void _thickLine(Canvas canvas, Offset a, Offset b, double width, Paint fill) {
    canvas.drawLine(
        a,
        b,
        Paint()
          ..color = fill.color
          ..style = PaintingStyle.stroke
          ..strokeWidth = width);
  }

  void _strokeInsetShield(Canvas canvas, Rect r, double band) {
    // no-op stroke hook; bordure edge is defined by fills + shield outline.
  }

  // -- Charges --------------------------------------------------------------

  void _paintCharges(Canvas canvas, Rect r) {
    if (!_blazon.hasCharge) return;
    final fill = Paint()..color = _t(_blazon.chargeTincture);
    final outline = Paint()
      ..color = kInkColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(0.5, r.width * 0.005)
      ..strokeJoin = StrokeJoin.round;

    // Where does the charge group sit?
    late Offset center;
    late double unit; // half-size of one charge
    if (_blazon.chargeOnOrdinary) {
      switch (_blazon.ordinary) {
        case _Ordinary.pale:
        case _Ordinary.cross:
        case _Ordinary.pile:
          center = Offset(r.center.dx, r.center.dy - r.height * 0.02);
        case _Ordinary.fess:
          center = r.center;
        case _Ordinary.chevron:
          center = Offset(r.center.dx, r.top + r.height * 0.40);
        default:
          center = r.center;
      }
      unit = r.width * 0.11;
    } else {
      center = Offset(r.center.dx, r.center.dy - r.height * 0.03);
      unit = r.width * 0.20;
    }

    switch (_blazon.arrangement) {
      case _Arrangement.single:
        _drawCharge(canvas, center, unit, _blazon.charge, fill, outline);
      case _Arrangement.three:
        final s = unit * 0.62;
        final dx = r.width * 0.20;
        final dy = r.height * 0.17;
        _drawCharge(canvas, center + Offset(-dx, -dy), s, _blazon.charge, fill,
            outline);
        _drawCharge(canvas, center + Offset(dx, -dy), s, _blazon.charge, fill,
            outline);
        _drawCharge(canvas, center + Offset(0, dy * 1.15), s, _blazon.charge,
            fill, outline);
      case _Arrangement.seme:
        _drawSeme(canvas, r, _blazon.charge, fill, outline);
    }
  }

  void _drawSeme(
      Canvas canvas, Rect r, _Charge charge, Paint fill, Paint outline) {
    final cols = 4;
    final s = r.width / (cols + 1) * 0.34;
    final stepX = r.width / cols;
    final stepY = stepX;
    for (var row = 0; r.top + row * stepY < r.bottom + stepY; row++) {
      final offset = row.isOdd ? stepX / 2 : 0.0;
      for (var col = -1; col <= cols; col++) {
        final c = Offset(
            r.left + offset + col * stepX + stepX * 0.25, r.top + row * stepY);
        _drawCharge(canvas, c, s, charge, fill, outline);
      }
    }
  }

  void _drawCharge(Canvas canvas, Offset center, double unit, _Charge charge,
      Paint fill, Paint outline) {
    final path = _chargePath(charge, unit);
    if (path == null) return;
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.drawPath(path, fill);
    canvas.drawPath(path, outline);
    canvas.restore();
  }

  /// Charge geometry, centered at the origin, roughly spanning [-unit, unit].
  Path? _chargePath(_Charge charge, double u) {
    switch (charge) {
      case _Charge.roundel:
        return Path()..addOval(Rect.fromCircle(center: Offset.zero, radius: u * 0.86));
      case _Charge.annulet:
        return Path()
          ..addOval(Rect.fromCircle(center: Offset.zero, radius: u * 0.86))
          ..addOval(Rect.fromCircle(center: Offset.zero, radius: u * 0.5))
          ..fillType = PathFillType.evenOdd;
      case _Charge.mullet:
        return _star(5, u * 0.95, u * 0.40, -math.pi / 2);
      case _Charge.mulletOfSix:
        return _star(6, u * 0.95, u * 0.45, -math.pi / 2);
      case _Charge.sun:
        return _sun(u);
      case _Charge.lozenge:
        return Path()
          ..moveTo(0, -u)
          ..lineTo(u * 0.62, 0)
          ..lineTo(0, u)
          ..lineTo(-u * 0.62, 0)
          ..close();
      case _Charge.billet:
        return Path()
          ..addRect(Rect.fromCenter(
              center: Offset.zero, width: u * 1.1, height: u * 1.7));
      case _Charge.crescent:
        return _crescent(u);
      case _Charge.fleurDeLis:
        return _fleurDeLis(u);
      case _Charge.rose:
        return _rose(u);
      case _Charge.escallop:
        return _escallop(u);
      case _Charge.crossPattee:
        return _crossPattee(u);
      case _Charge.crossCrosslet:
        return _crossCrosslet(u);
      case _Charge.trefoil:
        return _trefoil(u);
      case _Charge.lionRampant:
        return _lionRampant(u);
      case _Charge.eagleDisplayed:
        return _eagleDisplayed(u);
      case _Charge.griffin:
        return _griffin(u);
      case _Charge.martlet:
        return _martlet(u);
    }
  }

  Path _star(int points, double outer, double inner, double startAngle) {
    final p = Path();
    for (var i = 0; i < points * 2; i++) {
      final rad = i.isEven ? outer : inner;
      final a = startAngle + i * math.pi / points;
      final o = Offset(math.cos(a) * rad, math.sin(a) * rad);
      i == 0 ? p.moveTo(o.dx, o.dy) : p.lineTo(o.dx, o.dy);
    }
    return p..close();
  }

  Path _sun(double u) {
    final rays = 16;
    final p = Path();
    for (var i = 0; i < rays * 2; i++) {
      final rad = i.isEven ? u : u * 0.72;
      final a = i * math.pi / rays;
      final o = Offset(math.cos(a) * rad, math.sin(a) * rad);
      i == 0 ? p.moveTo(o.dx, o.dy) : p.lineTo(o.dx, o.dy);
    }
    p.close();
    p.addOval(Rect.fromCircle(center: Offset.zero, radius: u * 0.55));
    return p;
  }

  Path _crescent(double u) {
    return Path()
      ..addOval(Rect.fromCircle(center: Offset.zero, radius: u * 0.9))
      ..addOval(Rect.fromCircle(
          center: Offset(0, -u * 0.42), radius: u * 0.78))
      ..fillType = PathFillType.evenOdd;
  }

  Path _fleurDeLis(double u) {
    // Stylised three-part lily, symmetric about x = 0.
    final p = Path();
    // central petal
    p.moveTo(0, -u);
    p.cubicTo(u * 0.28, -u * 0.5, u * 0.22, u * 0.1, 0, u * 0.35);
    p.cubicTo(-u * 0.22, u * 0.1, -u * 0.28, -u * 0.5, 0, -u);
    p.close();
    // right petal curling out and down
    p.moveTo(u * 0.06, -u * 0.15);
    p.cubicTo(u * 0.65, -u * 0.35, u * 0.78, u * 0.28, u * 0.30, u * 0.42);
    p.cubicTo(u * 0.52, u * 0.05, u * 0.34, -u * 0.05, u * 0.06, u * 0.02);
    p.close();
    // left petal (mirror)
    p.moveTo(-u * 0.06, -u * 0.15);
    p.cubicTo(-u * 0.65, -u * 0.35, -u * 0.78, u * 0.28, -u * 0.30, u * 0.42);
    p.cubicTo(-u * 0.52, u * 0.05, -u * 0.34, -u * 0.05, -u * 0.06, u * 0.02);
    p.close();
    // binding band
    p.addRect(Rect.fromCenter(
        center: Offset(0, u * 0.30), width: u * 0.9, height: u * 0.22));
    // lower stem
    p.moveTo(-u * 0.14, u * 0.42);
    p.lineTo(u * 0.14, u * 0.42);
    p.lineTo(0, u);
    p.close();
    return p;
  }

  Path _rose(double u) {
    // Five broad petals with a small seeded centre.
    final p = Path();
    for (var i = 0; i < 5; i++) {
      final a = -math.pi / 2 + i * 2 * math.pi / 5;
      final tip = Offset(math.cos(a) * u, math.sin(a) * u);
      final la = a - math.pi / 5;
      final ra = a + math.pi / 5;
      final l = Offset(math.cos(la) * u * 0.34, math.sin(la) * u * 0.34);
      final r = Offset(math.cos(ra) * u * 0.34, math.sin(ra) * u * 0.34);
      p.moveTo(0, 0);
      p.quadraticBezierTo(l.dx, l.dy, tip.dx, tip.dy);
      p.quadraticBezierTo(r.dx, r.dy, 0, 0);
      p.close();
    }
    p.addOval(Rect.fromCircle(center: Offset.zero, radius: u * 0.26));
    return p;
  }

  Path _escallop(double u) {
    // Scallop shell: fan of ridges with two ears at the top.
    final p = Path();
    p.moveTo(-u, u * 0.35);
    p.quadraticBezierTo(-u * 0.5, -u, 0, -u * 0.85);
    p.quadraticBezierTo(u * 0.5, -u, u, u * 0.35);
    // scalloped bottom edge
    final lobes = 5;
    for (var i = lobes; i >= 0; i--) {
      final x = -u + (2 * u) * i / lobes;
      p.lineTo(x, u * 0.35 + u * 0.28);
      if (i > 0) {
        final xm = -u + (2 * u) * (i - 0.5) / lobes;
        p.quadraticBezierTo(xm, u * 0.35 + u * 0.7, xm, u * 0.35 + u * 0.28);
      }
    }
    p.close();
    return p;
  }

  Path _crossPattee(double u) {
    // Cross with arms flaring toward the ends.
    final n = u * 0.16; // half-width at centre
    final e = u; // reach
    final f = u * 0.5; // half-width at the flared end
    Path arm(double angle) {
      final p = Path();
      final ca = math.cos(angle), sa = math.sin(angle);
      // local axes
      Offset rot(double x, double y) => Offset(x * ca - y * sa, x * sa + y * ca);
      final a = rot(n, -n);
      final b = rot(e, -f);
      final c = rot(e, f);
      final d = rot(n, n);
      p.moveTo(a.dx, a.dy);
      p.lineTo(b.dx, b.dy);
      p.lineTo(c.dx, c.dy);
      p.lineTo(d.dx, d.dy);
      p.close();
      return p;
    }

    final combined = Path();
    for (var i = 0; i < 4; i++) {
      combined.addPath(arm(i * math.pi / 2), Offset.zero);
    }
    combined.addRect(Rect.fromCenter(
        center: Offset.zero, width: n * 2, height: n * 2));
    return combined;
  }

  Path _crossCrosslet(double u) {
    final t = u * 0.16; // arm half-thickness
    final p = Path();
    void bar(Rect r) => p.addRect(r);
    bar(Rect.fromLTRB(-t, -u, t, u)); // vertical
    bar(Rect.fromLTRB(-u, -t, u, t)); // horizontal
    // crosslets at each tip
    bar(Rect.fromLTRB(-u * 0.45, -u, u * 0.45, -u + t * 1.4));
    bar(Rect.fromLTRB(-u * 0.45, u - t * 1.4, u * 0.45, u));
    bar(Rect.fromLTRB(-u, -u * 0.45, -u + t * 1.4, u * 0.45));
    bar(Rect.fromLTRB(u - t * 1.4, -u * 0.45, u, u * 0.45));
    return p;
  }

  Path _trefoil(double u) {
    final p = Path();
    final r = u * 0.44;
    for (final a in [-math.pi / 2, math.pi / 6, math.pi * 5 / 6]) {
      final c = Offset(math.cos(a) * u * 0.5, math.sin(a) * u * 0.5);
      p.addOval(Rect.fromCircle(center: c, radius: r));
    }
    // stalk
    p.addRect(Rect.fromLTWH(-u * 0.08, u * 0.35, u * 0.16, u * 0.65));
    return p;
  }

  // -- Figurative charges ---------------------------------------------------
  //
  // Each beast is composed from simple primitives (ovals, polygons) merged with
  // Path.combine(union) into ONE clean silhouette — this avoids the
  // self-intersecting-perimeter "blob" problem and gives a single outer
  // outline. Coordinates are authored in a [-100, 100] box, then scaled by u.
  // All beasts face dexter (the viewer's left), per heraldic convention.

  Path _union(List<Path> parts) {
    var acc = parts.first;
    for (var i = 1; i < parts.length; i++) {
      acc = Path.combine(PathOperation.union, acc, parts[i]);
    }
    return acc;
  }

  Path _lionRampant(double u) {
    final s = u / 100.0;
    Offset p(double x, double y) => Offset(x * s, y * s);
    Path oval(double x, double y, double w, double h) =>
        Path()..addOval(Rect.fromCenter(center: p(x, y), width: w * s, height: h * s));
    Path poly(List<List<double>> pts) {
      final path = Path()..moveTo(p(pts[0][0], pts[0][1]).dx, p(pts[0][0], pts[0][1]).dy);
      for (final o in pts.skip(1)) {
        path.lineTo(p(o[0], o[1]).dx, p(o[0], o[1]).dy);
      }
      return path..close();
    }

    return _union([
      // planted hind leg + paw on the base line (dexter side lifted, rearing)
      poly([[2, 32], [26, 22], [30, 96], [2, 96]]),
      oval(18, 32, 46, 50), // haunch
      // body reared up on the diagonal, hip (right) to shoulder (upper-left)
      poly([[34, 28], [6, 44], [-34, -6], [-42, -30], [-20, -42], [8, -8], [32, 12]]),
      oval(-32, -28, 38, 42), // chest / shoulder
      oval(-48, -52, 28, 26), // head
      poly([[-58, -54], [-80, -52], [-58, -44]]), // muzzle
      poly([[-58, -46], [-74, -40], [-56, -36]]), // lower jaw
      poly([[-42, -64], [-34, -74], [-30, -62]]), // ear
      // forelegs clawing up and forward
      poly([[-34, -32], [-62, -60], [-52, -66], [-22, -42]]),
      poly([[-24, -18], [-54, -30], [-50, -40], [-20, -30]]),
      // tail rising from the rump, thickening, and curling to a tuft
      poly([[32, 24], [52, 6], [56, -30], [46, -56], [34, -62], [40, -46],
            [44, -26], [40, -2], [26, 18]]),
      poly([[46, -56], [58, -66], [50, -48], [40, -46]]), // tuft
    ]);
  }

  Path _eagleDisplayed(double u) {
    final s = u / 100.0;
    Offset p(double x, double y) => Offset(x * s, y * s);
    Path oval(double x, double y, double w, double h) =>
        Path()..addOval(Rect.fromCenter(center: p(x, y), width: w * s, height: h * s));
    Path poly(List<List<double>> pts) {
      final path = Path()..moveTo(p(pts[0][0], pts[0][1]).dx, p(pts[0][0], pts[0][1]).dy);
      for (final o in pts.skip(1)) {
        path.lineTo(p(o[0], o[1]).dx, p(o[0], o[1]).dy);
      }
      return path..close();
    }

    // Left half is authored; the right half is its mirror.
    Path wing(int sign) => poly([
          [6.0 * sign, -46], [40.0 * sign, -64], [70.0 * sign, -54],
          [92.0 * sign, -20], [62.0 * sign, -28], [82.0 * sign, 6],
          [48.0 * sign, -4], [30.0 * sign, -18], [8.0 * sign, -28],
        ]);
    Path leg(int sign) => poly([
          [8.0 * sign, 28], [22.0 * sign, 30], [26.0 * sign, 62],
          [16.0 * sign, 60], [14.0 * sign, 40],
        ]);

    return _union([
      oval(0, -6, 30, 66), // body
      wing(1), wing(-1),
      oval(-4, -72, 30, 28), // head
      poly([[-18, -76], [-38, -72], [-18, -62]]), // beak to dexter
      // feathered tail
      poly([[-12, 26], [12, 26], [18, 74], [6, 62], [0, 78], [-6, 62], [-18, 74]]),
      leg(1), leg(-1),
    ]);
  }

  Path _griffin(double u) {
    // Lion's rampant body with an eagle's head, beak and a raised wing.
    final s = u / 100.0;
    Offset p(double x, double y) => Offset(x * s, y * s);
    Path oval(double x, double y, double w, double h) =>
        Path()..addOval(Rect.fromCenter(center: p(x, y), width: w * s, height: h * s));
    Path poly(List<List<double>> pts) {
      final path = Path()..moveTo(p(pts[0][0], pts[0][1]).dx, p(pts[0][0], pts[0][1]).dy);
      for (final o in pts.skip(1)) {
        path.lineTo(p(o[0], o[1]).dx, p(o[0], o[1]).dy);
      }
      return path..close();
    }

    return _union([
      // same rearing lion body as _lionRampant
      poly([[2, 32], [26, 22], [30, 96], [2, 96]]),
      oval(18, 32, 46, 50),
      poly([[34, 28], [6, 44], [-34, -6], [-42, -30], [-20, -42], [8, -8], [32, 12]]),
      oval(-32, -28, 38, 42),
      // large raised wing with a feathered lower edge (distinguishes from lion)
      poly([[-28, -28], [-14, -60], [12, -80], [40, -80], [56, -60],
            [42, -56], [52, -42], [36, -40], [44, -24], [26, -24],
            [30, -8], [8, -18], [-8, -18]]),
      oval(-50, -52, 26, 24), // eagle head
      poly([[-60, -54], [-84, -50], [-62, -46]]), // hooked beak
      poly([[-78, -50], [-72, -42], [-64, -48]]), // beak hook
      poly([[-42, -64], [-34, -74], [-30, -62]]), // head tuft
      // eagle forelegs / talons clawing forward
      poly([[-34, -32], [-62, -58], [-52, -64], [-22, -42]]),
      poly([[-24, -18], [-54, -30], [-50, -40], [-20, -30]]),
      // lion tail curling up
      poly([[34, 22], [50, -2], [52, -42], [40, -66], [48, -60], [48, -28],
            [42, 0], [28, 18]]),
      oval(42, -66, 20, 20),
    ]);
  }

  // Martlet: a footless swallow in profile, facing dexter.
  Path _martlet(double u) {
    final s = u / 100.0;
    Offset p(double x, double y) => Offset(x * s, y * s);
    Path oval(double x, double y, double w, double h) =>
        Path()..addOval(Rect.fromCenter(center: p(x, y), width: w * s, height: h * s));
    Path poly(List<List<double>> pts) {
      final path = Path()..moveTo(p(pts[0][0], pts[0][1]).dx, p(pts[0][0], pts[0][1]).dy);
      for (final o in pts.skip(1)) {
        path.lineTo(p(o[0], o[1]).dx, p(o[0], o[1]).dy);
      }
      return path..close();
    }

    return _union([
      oval(6, -2, 78, 46), // body
      oval(-42, -26, 30, 30), // head
      poly([[-56, -26], [-82, -20], [-56, -12]]), // beak to dexter
      poly([[-6, -22], [34, -26], [26, 12], [-12, 8]]), // folded wing
      poly([[38, -6], [92, -8], [92, 22], [46, 16]]), // long swallow tail
      poly([[-26, 18], [-14, 18], [-20, 40]]), // feathered tuft (no feet)
      poly([[-2, 20], [10, 20], [4, 40]]),
    ]);
  }

  // -- Styled partition / edge lines ----------------------------------------

  /// A path from [a] to [b] whose edge is treated per [style]. Perpendicular
  /// displacement is [amp]; one motif spans roughly [period] along the line.
  Path _styledLine(Offset a, Offset b, _Line style, double amp, double period) {
    final path = Path()..moveTo(a.dx, a.dy);
    _appendStyledLine(path, a, b, style, amp, period);
    return path;
  }

  void _appendStyledLine(
      Path path, Offset a, Offset b, _Line style, double amp, double period) {
    final d = b - a;
    final len = d.distance;
    if (len < 1e-3) return;
    final dir = d / len;
    final nrm = Offset(-dir.dy, dir.dx);
    final units = math.max(1, (len / period).round());

    switch (style) {
      case _Line.straight:
        path.lineTo(b.dx, b.dy);

      case _Line.wavy:
        final steps = units * 6;
        for (var i = 1; i <= steps; i++) {
          final t = i / steps;
          final off = math.sin(t * units * 2 * math.pi) * amp;
          final pt = a + dir * (len * t) + nrm * off;
          path.lineTo(pt.dx, pt.dy);
        }

      case _Line.engrailed:
      case _Line.invected:
        final cw = style == _Line.engrailed;
        for (var i = 1; i <= units; i++) {
          final pt = a + dir * (len * i / units);
          path.arcToPoint(pt,
              radius: Radius.circular(len / units / 2), clockwise: cw);
        }

      case _Line.indented:
        final teeth = units * 2;
        for (var i = 1; i <= teeth; i++) {
          final t = i / teeth;
          final off = (i.isOdd ? amp : 0.0);
          final pt = a + dir * (len * t) + nrm * off;
          path.lineTo(pt.dx, pt.dy);
        }

      case _Line.dancetty:
        final teeth = math.max(2, units);
        for (var i = 1; i <= teeth * 2; i++) {
          final t = i / (teeth * 2);
          final off = (i.isOdd ? amp * 1.8 : 0.0);
          final pt = a + dir * (len * t) + nrm * off;
          path.lineTo(pt.dx, pt.dy);
        }

      case _Line.embattled:
        // Square crenellations toward the +normal side.
        for (var i = 0; i < units; i++) {
          final t0 = i / units, t1 = (i + 0.5) / units, t2 = (i + 1) / units;
          final up = (i.isEven ? amp : 0.0);
          final upNext = (i.isEven ? amp : 0.0);
          final p1 = a + dir * (len * t0) + nrm * up;
          final p2 = a + dir * (len * t1) + nrm * up;
          final downOff = (i.isEven ? 0.0 : amp);
          path.lineTo(p1.dx, p1.dy);
          path.lineTo(p2.dx, p2.dy);
          final p3 = a + dir * (len * t1) + nrm * (i.isEven ? 0.0 : amp);
          path.lineTo(p3.dx, p3.dy);
          final p4 = a + dir * (len * t2) + nrm * downOff;
          path.lineTo(p4.dx, p4.dy);
          // touch upNext to appease analyzer without altering shape
          assert(upNext >= 0);
        }
        path.lineTo(b.dx, b.dy);
    }
  }

  void _appendStyledLineReverse(
      Path path, Offset a, Offset b, _Line style, double amp, double period) {
    // Build the styled edge a→b, then splice its points in reverse so an
    // enclosing region can be closed. Simpler: draw b→a with flipped normal.
    _appendStyledLine(path, b, a, style, amp, period);
  }

  void _strokeStyledLine(Canvas canvas, Path p) {
    canvas.drawPath(
        p,
        Paint()
          ..color = kInkColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(0.7, p.getBounds().longestSide * 0.004));
  }

  void _strokeLine(Canvas canvas, Offset a, Offset b) {
    canvas.drawLine(
        a,
        b,
        Paint()
          ..color = kInkColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(0.7, (b - a).distance * 0.006));
  }

  // -- Frame + background ---------------------------------------------------

  void _drawBackground(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = kParchmentPanelColor);
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = RadialGradient(
          colors: [kParchmentColor, kParchmentPanelColor],
          radius: 0.72,
        ).createShader(Offset.zero & size),
    );
  }

  void _drawBorder(Canvas canvas, Size size, double dim, double margin) {
    final center = Offset(size.width / 2, size.height / 2);
    canvas.drawRect(
      Rect.fromCenter(
          center: center, width: dim - margin * 0.3, height: dim - margin * 0.3),
      Paint()
        ..color = kIlluminationGold
        ..style = PaintingStyle.stroke
        ..strokeWidth = margin * 0.13,
    );
    canvas.drawRect(
      Rect.fromCenter(
          center: center,
          width: dim - margin * 0.85,
          height: dim - margin * 0.85),
      Paint()
        ..color = kInkColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = margin * 0.05,
    );

    final outerRect = Rect.fromCenter(
        center: center, width: dim - margin * 0.3, height: dim - margin * 0.3);
    final r = margin * 0.36;
    for (final corner in [
      outerRect.topLeft,
      outerRect.topRight,
      outerRect.bottomRight,
      outerRect.bottomLeft,
    ]) {
      _drawRosette(canvas, corner, r);
    }
  }

  void _drawRosette(Canvas canvas, Offset center, double r) {
    final c1 = _t(_azure);
    final c2 = _t(_gules);
    for (var i = 0; i < 4; i++) {
      final angle = i * math.pi / 2 + math.pi / 4;
      final pc = center + Offset(math.cos(angle), math.sin(angle)) * (r * 0.44);
      canvas.drawCircle(pc, r * 0.40, Paint()..color = kInkColor);
      canvas.drawCircle(pc, r * 0.27, Paint()..color = c1);
    }
    canvas.drawCircle(center, r * 0.22, Paint()..color = kInkColor);
    canvas.drawCircle(center, r * 0.13, Paint()..color = c2);
  }
}

// ---------------------------------------------------------------------------
// Widget
// ---------------------------------------------------------------------------

void _showSigilFullscreen(
    BuildContext context, Uint8List keyBytes, int gridN, double saturation) {
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
                child: CustomPaint(
                  painter: SigilPainter(keyBytes,
                      gridN: gridN, saturation: saturation),
                ),
              );
            },
          ),
        ),
      ),
    ),
  );
}

/// A square widget that renders a deterministic heraldic coat of arms from raw
/// Ed25519 public key bytes. Pass `Identity.publicKeyBytes` directly.
///
/// Tapping always opens a full-screen overlay that dismisses on any tap.
class SigilWidget extends StatelessWidget {
  const SigilWidget({
    super.key,
    required this.keyBytes,
    this.size = 200,
    this.gridN = 7,
    this.saturation = 1.0,
  });

  final Uint8List keyBytes;
  final double size;

  /// Retained for API compatibility; the heraldic generator ignores it.
  final int gridN;
  final double saturation;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => _showSigilFullscreen(context, keyBytes, gridN, saturation),
      child: SizedBox(
        width: size,
        height: size,
        child: CustomPaint(
          painter:
              SigilPainter(keyBytes, gridN: gridN, saturation: saturation),
        ),
      ),
    );
  }
}
